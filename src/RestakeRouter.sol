// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IRestakeRouter} from "./interfaces/IRestakeRouter.sol";
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {IAToken} from "./interfaces/IAToken.sol";
import {ITokenMessengerV2, IMessageTransmitterV2} from "./interfaces/ICctpV2.sol";
import {FeeLib} from "./libraries/FeeLib.sol";

/// @title RestakeRouter
/// @notice Immutable, ownerless, non-custodial router that deposits USDC into a fixed set of ERC-4626 vaults
///         and Aave V3 (taking a tiered deposit fee), and withdraws from them (no fee). Optionally receives
///         deposits from, and bridges withdrawals to, other chains through Circle CCTP V2.
/// @dev Pool list and fee tiers are written once in the constructor; no code path writes them again.
///      The only mutable state is the guardian's one-way deposit kill switches.
contract RestakeRouter is IRestakeRouter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = FeeLib.MAX_FEE_BPS;
    uint256 public constant MAX_TIERS = FeeLib.MAX_TIERS;

    // CCTP V2 MessageV2 / BurnMessageV2 byte offsets, absolute within the message (body starts at 148).
    // Slither does not count calldata slice bounds as uses, so it flags these as unused.
    // slither-disable-start unused-state
    uint256 private constant MSG_SOURCE_DOMAIN = 4;
    uint256 private constant MSG_NONCE = 12;
    uint256 private constant MSG_RECIPIENT = 76;
    uint256 private constant MSG_MINT_RECIPIENT = 148 + 36;
    uint256 private constant MSG_MESSAGE_SENDER = 148 + 100;
    // slither-disable-end unused-state
    uint256 private constant MSG_HOOK_DATA = 148 + 228;
    uint256 private constant HOOK_LENGTH = 5 * 32;

    address public immutable FEE_RECIPIENT;
    address public immutable GUARDIAN;
    address public immutable USDC;
    address public immutable AAVE_POOL;
    address public immutable CCTP_TOKEN_MESSENGER;
    address public immutable CCTP_MESSAGE_TRANSMITTER;
    uint32 public immutable CCTP_LOCAL_DOMAIN;

    mapping(address pool => PoolType) public poolType;
    mapping(address pool => bool) public depositsDisabled;
    bool public allDepositsDisabled;

    address[] private _pools;
    FeeTier[] private _feeTiers;

    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        _;
    }

    /// @dev Must not read msg.sender: under CREATE3 it is the CreateX proxy, not the deployer.
    ///      `cctpTokenMessenger_` is Circle's TokenMessengerV2, or zero to deploy without CCTP support.
    constructor(
        address feeRecipient_,
        address guardian_,
        address usdc_,
        address aavePool_,
        address cctpTokenMessenger_,
        FeeTier[] memory feeTiers_,
        PoolInit[] memory pools_
    ) {
        if (feeRecipient_ == address(0) || guardian_ == address(0) || usdc_ == address(0)) {
            revert ZeroAddress();
        }
        FEE_RECIPIENT = feeRecipient_;
        GUARDIAN = guardian_;
        USDC = usdc_;
        // slither-disable-next-line missing-zero-check zero when the chain has no AAVE_V3 pools (checked per pool)
        AAVE_POOL = aavePool_;

        // slither-disable-next-line missing-zero-check zero deploys without CCTP support
        CCTP_TOKEN_MESSENGER = cctpTokenMessenger_;
        address transmitter = address(0);
        uint32 localDomain = 0;
        if (cctpTokenMessenger_ != address(0)) {
            transmitter = ITokenMessengerV2(cctpTokenMessenger_).localMessageTransmitter();
            if (transmitter == address(0)) revert ZeroAddress();
            localDomain = IMessageTransmitterV2(transmitter).localDomain();
        }
        CCTP_MESSAGE_TRANSMITTER = transmitter;
        CCTP_LOCAL_DOMAIN = localDomain;

        FeeLib.validate(feeTiers_);
        for (uint256 i; i < feeTiers_.length; ++i) {
            _feeTiers.push(feeTiers_[i]);
        }
        emit FeeTiersSet(feeTiers_);

        for (uint256 i; i < pools_.length; ++i) {
            PoolInit memory p = pools_[i];
            if (poolType[p.pool] != PoolType.NONE) revert DuplicatePool(p.pool);
            _validatePool(p, usdc_, aavePool_);
            poolType[p.pool] = p.poolType;
            _pools.push(p.pool);
            emit PoolAdded(p.pool, p.poolType);
        }
    }

    // ───────────── User actions ─────────────

    /// @inheritdoc IRestakeRouter
    function deposit(
        address pool,
        uint256 assets,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        bytes32 referralCode
    ) external nonReentrant returns (uint256 shares, uint256 fee) {
        return _deposit(pool, assets, minShares, receiver, deadline, referralCode);
    }

    /// @inheritdoc IRestakeRouter
    function depositWithPermit(
        address pool,
        uint256 assets,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        bytes32 referralCode,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 shares, uint256 fee) {
        // A front-run permit (same signature submitted first) reverts on the used nonce but has already set
        // the allowance, so failures are ignored; `_pullExact` reverts if the allowance isn't there.
        try IERC20Permit(USDC).permit(msg.sender, address(this), assets, deadline, v, r, s) {} catch {}
        return _deposit(pool, assets, minShares, receiver, deadline, referralCode);
    }

    /// @inheritdoc IRestakeRouter
    function withdraw(address pool, uint256 shares, uint256 minAssets, address receiver, uint256 deadline)
        external
        nonReentrant
        returns (uint256 assets)
    {
        PoolType pType = _checkAction(pool, receiver, deadline);
        (shares, assets) = _withdrawTo(pType, pool, shares, minAssets, receiver);
        emit Withdraw(msg.sender, receiver, pool, USDC, shares, assets);
    }

    // ───────────── CCTP ─────────────

    /// @inheritdoc IRestakeRouter
    function receiveAndDeposit(bytes calldata message, bytes calldata attestation)
        external
        nonReentrant
        returns (uint256 shares, uint256 fee)
    {
        (uint256 assets,, bytes calldata hookData) = _receiveCctp(message, attestation);
        (CctpDepositHook memory hook, bool valid) = _decodeHook(hookData);
        if (!valid) revert InvalidHookData();

        PoolType pType = _checkAction(hook.pool, hook.receiver, hook.deadline);
        _checkDepositsOpen(hook.pool);
        (shares, fee) = _depositHeld(pType, hook.pool, assets, hook.minShares, hook.receiver, hook.referralCode);
    }

    /// @inheritdoc IRestakeRouter
    function receiveAndRefund(bytes calldata message, bytes calldata attestation)
        external
        nonReentrant
        returns (uint256 amount)
    {
        bytes32 messageSender;
        bytes calldata hookData;
        (amount, messageSender, hookData) = _receiveCctp(message, attestation);
        (CctpDepositHook memory hook, bool valid) = _decodeHook(hookData);

        address to;
        if (valid) {
            // slither-disable-next-line timestamp user-supplied deadline
            if (msg.sender != hook.receiver && block.timestamp <= hook.deadline) revert RefundNotAllowed();
            to = hook.receiver;
        } else {
            // Malformed hook: return the funds to the burner's address on this chain (EVM sources only).
            if (uint256(messageSender) > type(uint160).max) revert InvalidHookData();
            to = address(uint160(uint256(messageSender)));
            if (to == address(this)) revert InvalidHookData();
        }
        IERC20(USDC).safeTransfer(to, amount);
        emit CctpRefunded(to, amount);
    }

    /// @inheritdoc IRestakeRouter
    function withdrawAndBridge(
        address pool,
        uint256 shares,
        uint256 minAssets,
        uint256 deadline,
        CctpBridge calldata bridge
    ) external nonReentrant returns (uint256 assets) {
        address tokenMessenger = CCTP_TOKEN_MESSENGER;
        if (tokenMessenger == address(0)) revert CctpNotSupported();
        // The router has the same address on every chain (CREATE3): USDC minted to it there would be swept.
        if (
            bridge.mintRecipient == bytes32(0) || bridge.mintRecipient == _toBytes32(address(this))
                || bridge.destinationDomain == CCTP_LOCAL_DOMAIN
        ) {
            revert InvalidBridgeDestination();
        }
        // slither-disable-next-line timestamp user-supplied deadline
        if (block.timestamp > deadline) revert DeadlineExpired();
        PoolType pType = _registeredType(pool);

        (shares, assets) = _withdrawTo(pType, pool, shares, minAssets, address(this));

        IERC20 usdc = IERC20(USDC);
        usdc.forceApprove(tokenMessenger, assets);
        ITokenMessengerV2(tokenMessenger)
            .depositForBurn(
                assets,
                bridge.destinationDomain,
                bridge.mintRecipient,
                address(usdc),
                bytes32(0),
                bridge.maxFee,
                bridge.minFinalityThreshold
            );
        usdc.forceApprove(tokenMessenger, 0);

        emit Withdraw(msg.sender, address(this), pool, USDC, shares, assets);
        emit CctpBridged(
            msg.sender,
            bridge.destinationDomain,
            bridge.mintRecipient,
            assets,
            bridge.maxFee,
            bridge.minFinalityThreshold
        );
    }

    /// @inheritdoc IRestakeRouter
    /// @dev nonReentrant so it can never touch funds in flight during a deposit or withdraw.
    function sweep(address token) external nonReentrant {
        uint256 amount = IERC20(token).balanceOf(address(this));
        // slither-disable-next-line incorrect-equality zero-amount guard
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(FEE_RECIPIENT, amount);
        emit Swept(token, amount);
    }

    // ───────────── Guardian (one-way) ─────────────

    /// @inheritdoc IRestakeRouter
    function disablePoolDeposits(address pool) external onlyGuardian {
        if (poolType[pool] == PoolType.NONE) revert PoolNotRegistered(pool);
        depositsDisabled[pool] = true;
        emit PoolDepositsDisabled(pool);
    }

    /// @inheritdoc IRestakeRouter
    function disableAllDeposits() external onlyGuardian {
        allDepositsDisabled = true;
        emit AllDepositsDisabled();
    }

    // ───────────── Views ─────────────

    function getPools() external view returns (address[] memory) {
        return _pools;
    }

    function getFeeTiers() external view returns (FeeTier[] memory) {
        return _feeTiers;
    }

    /// @inheritdoc IRestakeRouter
    function previewDeposit(address pool, uint256 assets)
        external
        view
        returns (uint256 fee, uint8 tierIndex, uint256 netAssets, uint256 expectedShares)
    {
        PoolType pType = _registeredType(pool);
        uint16 feeBps;
        (tierIndex, feeBps) = FeeLib.tierFor(_feeTiers, assets);
        fee = FeeLib.feeFor(assets, feeBps);
        netAssets = assets - fee;
        expectedShares = pType == PoolType.ERC4626 ? IERC4626(pool).previewDeposit(netAssets) : netAssets;
    }

    /// @inheritdoc IRestakeRouter
    function previewWithdraw(address pool, uint256 shares) external view returns (uint256 expectedAssets) {
        PoolType pType = _registeredType(pool);
        expectedAssets = pType == PoolType.ERC4626 ? IERC4626(pool).previewRedeem(shares) : shares;
    }

    // ───────────── Internal ─────────────

    /// @dev Constructor-only, over the deploy-time pool list.
    function _validatePool(PoolInit memory p, address usdc_, address aavePool_) private view {
        // slither-disable-start calls-loop
        if (p.poolType == PoolType.ERC4626) {
            if (IERC4626(p.pool).asset() != usdc_) revert AssetMismatch(p.pool);
        } else if (p.poolType == PoolType.AAVE_V3) {
            if (aavePool_ == address(0)) revert ZeroAddress();
            if (IAToken(p.pool).UNDERLYING_ASSET_ADDRESS() != usdc_) revert AssetMismatch(p.pool);
            if (IAaveV3Pool(aavePool_).getReserveData(usdc_).aTokenAddress != p.pool) revert AaveReserveMismatch();
        } else {
            revert InvalidPoolType();
        }
        // slither-disable-end calls-loop
    }

    /// @dev Checks shared by deposit and withdraw. Returns the pool's type.
    function _checkAction(address pool, address receiver, uint256 deadline) private view returns (PoolType) {
        // slither-disable-next-line timestamp user-supplied deadline
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (receiver == address(0) || receiver == address(this) || receiver == pool) revert InvalidReceiver(receiver);
        return _registeredType(pool);
    }

    function _registeredType(address pool) private view returns (PoolType pType) {
        pType = poolType[pool];
        if (pType == PoolType.NONE) revert PoolNotRegistered(pool);
    }

    /// @dev Shared by `deposit` and `depositWithPermit`: pulls `assets` USDC from msg.sender and deposits it.
    function _deposit(
        address pool,
        uint256 assets,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        bytes32 referralCode
    ) private returns (uint256 shares, uint256 fee) {
        PoolType pType = _checkAction(pool, receiver, deadline);
        if (assets == 0) revert ZeroAmount();
        _checkDepositsOpen(pool);

        _pullExact(IERC20(USDC), assets);
        (shares, fee) = _depositHeld(pType, pool, assets, minShares, receiver, referralCode);
    }

    function _checkDepositsOpen(address pool) private view {
        if (allDepositsDisabled) revert AllDepositsAreDisabled();
        if (depositsDisabled[pool]) revert DepositsDisabled(pool);
    }

    /// @dev Takes the fee from, and deposits the rest of, `assets` USDC the router already holds.
    function _depositHeld(
        PoolType pType,
        address pool,
        uint256 assets,
        uint256 minShares,
        address receiver,
        bytes32 referralCode
    ) private returns (uint256 shares, uint256 fee) {
        uint8 tierIndex;
        uint16 feeBps;
        (fee, tierIndex, feeBps) = _chargeFee(assets);

        shares = _supply(pType, pool, assets - fee, receiver);
        if (shares < minShares) revert SlippageExceeded(shares, minShares);

        _emitDeposit(receiver, pool, assets, fee, shares, tierIndex, feeBps, referralCode);
    }

    /// @dev Redeems msg.sender's `shares` (max = full balance) and sends the USDC to `receiver`.
    ///      Returns the shares spent and the receiver's USDC delta.
    function _withdrawTo(PoolType pType, address pool, uint256 shares, uint256 minAssets, address receiver)
        private
        returns (uint256 spent, uint256 assets)
    {
        if (minAssets == 0) revert ZeroAmount();
        if (shares == type(uint256).max) shares = IERC20(pool).balanceOf(msg.sender);
        // slither-disable-next-line incorrect-equality zero-amount guard
        if (shares == 0) revert ZeroAmount();

        // Balance delta across the redeem is intended (§9); entry points are nonReentrant.
        // slither-disable-start reentrancy-balance
        IERC20 usdc = IERC20(USDC);
        uint256 receiverBefore = usdc.balanceOf(receiver);
        spent = pType == PoolType.ERC4626 ? _redeem4626(pool, shares, receiver) : _redeemAave(pool, shares, receiver);
        assets = usdc.balanceOf(receiver) - receiverBefore;
        if (assets < minAssets) revert SlippageExceeded(assets, minAssets);
        // slither-disable-end reentrancy-balance
    }

    /// @dev Relays a CCTP V2 burn message minting USDC to this router. Returns the USDC actually minted
    ///      (balance delta, so the fast-transfer fee is already taken out), the source-chain burner and the
    ///      hook data.
    function _receiveCctp(bytes calldata message, bytes calldata attestation)
        private
        returns (uint256 amount, bytes32 messageSender, bytes calldata hookData)
    {
        address transmitter = CCTP_MESSAGE_TRANSMITTER;
        if (transmitter == address(0)) revert CctpNotSupported();
        // The transmitter hands the message to `recipient`: only the local TokenMessenger mints USDC, so any
        // other recipient would let a forged body pose as a burn.
        if (
            message.length < MSG_HOOK_DATA
                || bytes32(message[MSG_RECIPIENT:MSG_RECIPIENT + 32]) != _toBytes32(CCTP_TOKEN_MESSENGER)
                || bytes32(message[MSG_MINT_RECIPIENT:MSG_MINT_RECIPIENT + 32]) != _toBytes32(address(this))
        ) {
            revert InvalidCctpMessage();
        }

        // slither-disable-start reentrancy-balance
        IERC20 usdc = IERC20(USDC);
        uint256 before = usdc.balanceOf(address(this));
        if (!IMessageTransmitterV2(transmitter).receiveMessage(message, attestation)) revert InvalidCctpMessage();
        amount = usdc.balanceOf(address(this)) - before;
        // slither-disable-end reentrancy-balance
        // slither-disable-next-line incorrect-equality burn of a token other than USDC
        if (amount == 0) revert ZeroAmount();

        messageSender = bytes32(message[MSG_MESSAGE_SENDER:MSG_MESSAGE_SENDER + 32]);
        hookData = message[MSG_HOOK_DATA:];
        emit CctpReceived(
            bytes32(message[MSG_NONCE:MSG_NONCE + 32]),
            uint32(bytes4(message[MSG_SOURCE_DOMAIN:MSG_SOURCE_DOMAIN + 4])),
            messageSender,
            amount
        );
    }

    /// @dev `valid` is false unless `hookData` is exactly `abi.encode(CctpDepositHook)` with clean address
    ///      words and a receiver `_checkAction` would accept, so a refund can always pick a destination.
    function _decodeHook(bytes calldata hookData) private view returns (CctpDepositHook memory hook, bool valid) {
        if (hookData.length != HOOK_LENGTH) return (hook, valid);
        (uint256 pool, uint256 minShares, uint256 receiver, uint256 deadline, bytes32 referralCode) =
            abi.decode(hookData, (uint256, uint256, uint256, uint256, bytes32));
        if (pool > type(uint160).max || receiver > type(uint160).max) return (hook, valid);
        hook = CctpDepositHook({
            // forge-lint: disable-next-line(unsafe-typecast) range-checked above
            pool: address(uint160(pool)),
            minShares: minShares,
            // forge-lint: disable-next-line(unsafe-typecast) range-checked above
            receiver: address(uint160(receiver)),
            deadline: deadline,
            referralCode: referralCode
        });
        valid = hook.receiver != address(0) && hook.receiver != address(this) && hook.receiver != hook.pool;
    }

    function _toBytes32(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev Pulls exactly `amount` of `token` from msg.sender (rejects fee-on-transfer behavior).
    /// @return before The router's balance before the pull.
    function _pullExact(IERC20 token, uint256 amount) private returns (uint256 before) {
        before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert UnexpectedTransferAmount(amount, received);
    }

    /// @dev Split out of `deposit` to keep its stack shallow (the event has 11 fields).
    function _emitDeposit(
        address receiver,
        address pool,
        uint256 assets,
        uint256 fee,
        uint256 shares,
        uint8 tierIndex,
        uint16 feeBps,
        bytes32 referralCode
    ) private {
        emit Deposit(
            msg.sender, receiver, pool, USDC, assets, fee, assets - fee, shares, tierIndex, feeBps, referralCode
        );
    }

    /// @dev Sizes the fee from the tier schedule (gross amount of this single deposit) and pays FEE_RECIPIENT.
    function _chargeFee(uint256 assets) private returns (uint256 fee, uint8 tierIndex, uint16 feeBps) {
        (tierIndex, feeBps) = FeeLib.tierFor(_feeTiers, assets);
        fee = FeeLib.feeFor(assets, feeBps);
        if (fee != 0) IERC20(USDC).safeTransfer(FEE_RECIPIENT, fee);
    }

    /// @dev Deposits `netAssets` USDC into the pool for `receiver`. Returns the receiver's share / aToken delta.
    ///      The pool must take exactly `netAssets`, so nothing is left behind in the router.
    function _supply(PoolType pType, address pool, uint256 netAssets, address receiver)
        private
        returns (uint256 shares)
    {
        // Balance deltas across the pool call are intended (§9); entry points are nonReentrant.
        // slither-disable-start reentrancy-balance,unused-return
        IERC20 usdc = IERC20(USDC);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 sharesBefore = IERC20(pool).balanceOf(receiver);
        if (pType == PoolType.ERC4626) {
            usdc.forceApprove(pool, netAssets);
            // forge-lint: disable-next-line(unused-return) shares are measured as a balance delta instead
            IERC4626(pool).deposit(netAssets, receiver);
            usdc.forceApprove(pool, 0);
        } else {
            address aavePool = AAVE_POOL;
            usdc.forceApprove(aavePool, netAssets);
            IAaveV3Pool(aavePool).supply(address(usdc), netAssets, receiver, 0);
            usdc.forceApprove(aavePool, 0);
        }
        shares = IERC20(pool).balanceOf(receiver) - sharesBefore;
        uint256 spent = usdcBefore - usdc.balanceOf(address(this));
        if (spent != netAssets) revert UnexpectedTransferAmount(netAssets, spent);
        // slither-disable-end reentrancy-balance,unused-return
    }

    /// @dev Pulls `shares` from msg.sender and redeems them as owner. Returns the shares spent.
    function _redeem4626(address vault, uint256 shares, address receiver) private returns (uint256) {
        // slither-disable-start reentrancy-balance,unused-return
        uint256 before = _pullExact(IERC20(vault), shares);
        // forge-lint: disable-next-line(unused-return) assets are measured as a balance delta by the caller
        IERC4626(vault).redeem(shares, receiver, address(this));
        uint256 remaining = IERC20(vault).balanceOf(address(this)) - before;
        if (remaining != 0) revert UnexpectedTransferAmount(shares, shares - remaining);
        // slither-disable-end reentrancy-balance,unused-return
        return shares;
    }

    /// @dev Pulls aTokens from msg.sender (balance delta: aToken transfers can be off by 1 wei due to
    ///      scaled-balance rounding) and withdraws them. Returns the aTokens actually received.
    function _redeemAave(address aToken, uint256 amount, address receiver) private returns (uint256 received) {
        uint256 before = IERC20(aToken).balanceOf(address(this));
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(aToken).balanceOf(address(this)) - before;
        // With no prior (donated) balance, withdraw the router's whole position so no scaled dust stays behind.
        // slither-disable-start incorrect-equality,unused-return
        // forge-lint: disable-next-line(unused-return) assets are measured as a balance delta by the caller
        IAaveV3Pool(AAVE_POOL).withdraw(USDC, before == 0 ? type(uint256).max : received, receiver);
        // slither-disable-end incorrect-equality,unused-return
    }
}
