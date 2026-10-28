// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IRestakeRouter} from "./interfaces/IRestakeRouter.sol";
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {IAToken} from "./interfaces/IAToken.sol";
import {FeeLib} from "./libraries/FeeLib.sol";

/// @title RestakeRouter
/// @notice Immutable, ownerless, non-custodial router that deposits USDC into a fixed set of ERC-4626 vaults
///         and Aave V3 (taking a tiered deposit fee), and withdraws from them (no fee).
/// @dev Pool list and fee tiers are written once in the constructor; no code path writes them again.
///      The only mutable state is the guardian's one-way deposit kill switches.
contract RestakeRouter is IRestakeRouter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = FeeLib.MAX_FEE_BPS;
    uint256 public constant MAX_TIERS = FeeLib.MAX_TIERS;

    address public immutable FEE_RECIPIENT;
    address public immutable GUARDIAN;
    address public immutable USDC;
    address public immutable AAVE_POOL;

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
    constructor(
        address feeRecipient_,
        address guardian_,
        address usdc_,
        address aavePool_,
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
        PoolType pType = _checkAction(pool, receiver, deadline);
        if (assets == 0) revert ZeroAmount();
        if (allDepositsDisabled) revert AllDepositsAreDisabled();
        if (depositsDisabled[pool]) revert DepositsDisabled(pool);

        _pullExact(IERC20(USDC), assets);
        uint8 tierIndex;
        uint16 feeBps;
        (fee, tierIndex, feeBps) = _chargeFee(assets);

        shares = _supply(pType, pool, assets - fee, receiver);
        if (shares < minShares) revert SlippageExceeded(shares, minShares);

        _emitDeposit(receiver, pool, assets, fee, shares, tierIndex, feeBps, referralCode);
    }

    /// @inheritdoc IRestakeRouter
    function withdraw(address pool, uint256 shares, uint256 minAssets, address receiver, uint256 deadline)
        external
        nonReentrant
        returns (uint256 assets)
    {
        PoolType pType = _checkAction(pool, receiver, deadline);
        if (minAssets == 0) revert ZeroAmount();
        if (shares == type(uint256).max) shares = IERC20(pool).balanceOf(msg.sender);
        // slither-disable-next-line incorrect-equality zero-amount guard
        if (shares == 0) revert ZeroAmount();

        // Balance delta across the redeem is intended (§9); entry points are nonReentrant.
        // slither-disable-start reentrancy-balance
        IERC20 usdc = IERC20(USDC);
        uint256 receiverBefore = usdc.balanceOf(receiver);
        shares = pType == PoolType.ERC4626 ? _redeem4626(pool, shares, receiver) : _redeemAave(pool, shares, receiver);
        assets = usdc.balanceOf(receiver) - receiverBefore;
        if (assets < minAssets) revert SlippageExceeded(assets, minAssets);
        // slither-disable-end reentrancy-balance

        emit Withdraw(msg.sender, receiver, pool, USDC, shares, assets);
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
