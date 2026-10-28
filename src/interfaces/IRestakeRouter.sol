// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IRestakeRouter
/// @notice Immutable, non-custodial USDC router into a fixed set of ERC-4626 vaults and Aave V3.
///         See docs/architecture-v1.0.md.
interface IRestakeRouter {
    // ───────────── Types ─────────────

    enum PoolType {
        NONE,
        ERC4626,
        AAVE_V3
    }

    struct FeeTier {
        uint256 minAmount; // inclusive lower bound, in USDC base units
        uint16 feeBps; // fee in basis points (1 bps = 0.01%)
    }

    struct PoolInit {
        address pool; // ERC-4626 vault, or Aave aToken
        PoolType poolType;
    }

    /// @dev CCTP `hookData` for `receiveAndDeposit`, encoded as `abi.encode(hook)` (exactly 160 bytes).
    ///      Same meaning as the `deposit` arguments; the amount is whatever CCTP mints to the router.
    struct CctpDepositHook {
        address pool;
        uint256 minShares;
        address receiver;
        uint256 deadline;
        bytes32 referralCode;
    }

    /// @dev Destination of `withdrawAndBridge`. `maxFee` and `minFinalityThreshold` are passed to
    ///      `TokenMessengerV2.depositForBurn` as is (1000 = fast, 2000 = standard).
    struct CctpBridge {
        uint32 destinationDomain;
        bytes32 mintRecipient;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }

    // ───────────── Events ─────────────

    event Deposit(
        address indexed sender,
        address indexed receiver,
        address indexed pool,
        address asset,
        uint256 grossAssets,
        uint256 fee,
        uint256 netAssets,
        uint256 shares,
        uint8 tierIndex,
        uint16 feeBps,
        bytes32 referralCode
    );

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed pool,
        address asset,
        uint256 shares,
        uint256 assets
    );

    /// @dev Config events, emitted from the constructor only.
    event PoolAdded(address indexed pool, PoolType poolType);
    event FeeTiersSet(FeeTier[] tiers);

    event PoolDepositsDisabled(address indexed pool);
    event AllDepositsDisabled();

    event Swept(address indexed token, uint256 amount);

    /// @dev Emitted before the `Deposit` (or `CctpRefunded`) of the same call. `amount` is the USDC minted to
    ///      the router, after any CCTP fast-transfer fee. `messageSender` is the burner on the source chain.
    event CctpReceived(bytes32 indexed nonce, uint32 indexed sourceDomain, bytes32 messageSender, uint256 amount);
    event CctpRefunded(address indexed to, uint256 amount);
    /// @dev Emitted after the `Withdraw` (receiver = router) of the same call.
    event CctpBridged(
        address indexed sender,
        uint32 indexed destinationDomain,
        bytes32 indexed mintRecipient,
        uint256 amount,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    // ───────────── Errors ─────────────

    error ZeroAddress();
    error ZeroAmount();
    error DeadlineExpired();
    error InvalidReceiver(address receiver);
    error PoolNotRegistered(address pool);
    error DuplicatePool(address pool);
    error DepositsDisabled(address pool);
    /// @dev Named differently from the `AllDepositsDisabled` event: Solidity forbids an error and an event
    ///      sharing an identifier.
    error AllDepositsAreDisabled();
    error AssetMismatch(address pool);
    error InvalidFeeTiers();
    error FeeTooHigh(uint16 feeBps);
    error SlippageExceeded(uint256 actual, uint256 min);
    error UnexpectedTransferAmount(uint256 expected, uint256 received);
    error InvalidPoolType();
    error AaveReserveMismatch();
    error NotGuardian();
    error CctpNotSupported();
    error InvalidCctpMessage();
    error InvalidHookData();
    error RefundNotAllowed();
    error InvalidBridgeDestination();

    // ───────────── User actions ─────────────

    /// @notice Pull `assets` USDC from msg.sender, take the tiered fee, deposit the rest into `pool`,
    ///         and send the shares / aTokens to `receiver`.
    /// @param referralCode Opaque partner / referrer tag, emitted in `Deposit`. `bytes32(0)` = no referral.
    ///                     Tracking only: it doesn't change the fee or where it goes.
    /// @return shares Shares (or aTokens) received by `receiver`.
    /// @return fee    Fee sent to FEE_RECIPIENT.
    function deposit(
        address pool,
        uint256 assets,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        bytes32 referralCode
    ) external returns (uint256 shares, uint256 fee);

    /// @notice `deposit` in one transaction, without a prior `approve`: first applies the caller's EIP-2612
    ///         USDC permit for exactly `assets` to this router, valid until `deadline`.
    /// @dev The permit's owner is always msg.sender. A permit that fails (e.g. front-run with the same
    ///      signature) is ignored, and the deposit proceeds if the allowance is in place.
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
    ) external returns (uint256 shares, uint256 fee);

    /// @notice Pull `shares` (or aTokens) from msg.sender, redeem them, and send the USDC to `receiver`.
    /// @param shares    Pass type(uint256).max to withdraw msg.sender's full balance.
    /// @param minAssets Must be > 0, so a queued (async) redeem reverts instead of completing silently.
    /// @return assets   USDC received by `receiver`.
    function withdraw(address pool, uint256 shares, uint256 minAssets, address receiver, uint256 deadline)
        external
        returns (uint256 assets);

    /// @notice Sends any token balance held by the router to FEE_RECIPIENT. Callable by anyone.
    function sweep(address token) external;

    // ───────────── CCTP (cross-chain USDC) ─────────────

    /// @notice Relays a CCTP V2 burn whose `mintRecipient` is this router and whose `hookData` is
    ///         `abi.encode(CctpDepositHook)`, then deposits the minted USDC exactly like `deposit`
    ///         (tiered fee on the minted amount, shares to `hook.receiver`). Callable by anyone.
    /// @dev Any failure reverts the whole call, so the CCTP message stays unused and can be relayed again
    ///      or refunded with `receiveAndRefund`. The source should set `destinationCaller` to this router:
    ///      otherwise anyone can relay the message straight to the MessageTransmitter, leaving the USDC
    ///      in the router where `sweep` sends it to FEE_RECIPIENT.
    function receiveAndDeposit(bytes calldata message, bytes calldata attestation)
        external
        returns (uint256 shares, uint256 fee);

    /// @notice Relays a CCTP V2 burn to this router and sends the minted USDC, without fee, to `hook.receiver`.
    ///         For deposits that can't go through (pool disabled, deadline passed, slippage).
    /// @dev Callable by `hook.receiver` at any time, and by anyone once `hook.deadline` has passed.
    ///      If `hookData` doesn't decode to a valid hook, anyone can call it and the USDC goes to the
    ///      source-chain `messageSender` address on this chain.
    function receiveAndRefund(bytes calldata message, bytes calldata attestation) external returns (uint256 amount);

    /// @notice Same as `withdraw`, but burns the redeemed USDC through CCTP V2 to `bridge.mintRecipient` on
    ///         `bridge.destinationDomain` instead of sending it to a local receiver. No router fee.
    /// @return assets USDC burned. The recipient receives `assets` minus the CCTP fee (at most `maxFee`).
    function withdrawAndBridge(
        address pool,
        uint256 shares,
        uint256 minAssets,
        uint256 deadline,
        CctpBridge calldata bridge
    ) external returns (uint256 assets);

    // ───────────── Views ─────────────

    function FEE_RECIPIENT() external view returns (address);
    function GUARDIAN() external view returns (address);
    function AAVE_POOL() external view returns (address);
    function USDC() external view returns (address);
    function MAX_FEE_BPS() external view returns (uint16);
    function MAX_TIERS() external view returns (uint256);
    /// @dev All three are zero when the router was deployed without CCTP support.
    function CCTP_TOKEN_MESSENGER() external view returns (address);
    function CCTP_MESSAGE_TRANSMITTER() external view returns (address);
    function CCTP_LOCAL_DOMAIN() external view returns (uint32);

    function poolType(address pool) external view returns (PoolType);
    function getPools() external view returns (address[] memory);
    function getFeeTiers() external view returns (FeeTier[] memory);
    function depositsDisabled(address pool) external view returns (bool);
    function allDepositsDisabled() external view returns (bool);

    /// @notice Quote for the frontend: fee, tier, net amount, and expected shares.
    function previewDeposit(address pool, uint256 assets)
        external
        view
        returns (uint256 fee, uint8 tierIndex, uint256 netAssets, uint256 expectedShares);

    function previewWithdraw(address pool, uint256 shares) external view returns (uint256 expectedAssets);

    // ───────────── Guardian (one-way) ─────────────

    function disablePoolDeposits(address pool) external;
    function disableAllDeposits() external;
}
