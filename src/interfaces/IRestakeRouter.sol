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

    /// @notice Pull `shares` (or aTokens) from msg.sender, redeem them, and send the USDC to `receiver`.
    /// @param shares    Pass type(uint256).max to withdraw msg.sender's full balance.
    /// @param minAssets Must be > 0, so a queued (async) redeem reverts instead of completing silently.
    /// @return assets   USDC received by `receiver`.
    function withdraw(address pool, uint256 shares, uint256 minAssets, address receiver, uint256 deadline)
        external
        returns (uint256 assets);

    /// @notice Sends any token balance held by the router to FEE_RECIPIENT. Callable by anyone.
    function sweep(address token) external;

    // ───────────── Views ─────────────

    function FEE_RECIPIENT() external view returns (address);
    function GUARDIAN() external view returns (address);
    function AAVE_POOL() external view returns (address);
    function USDC() external view returns (address);
    function MAX_FEE_BPS() external view returns (uint16);
    function MAX_TIERS() external view returns (uint256);

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
