// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal Aave V3 Pool interface used by the router.
interface IAaveV3Pool {
    /// @dev `ReserveDataLegacy` layout, returned by `getReserveData` on every Aave V3 version.
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @param amount type(uint256).max withdraws the caller's full aToken balance.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function getReserveData(address asset) external view returns (ReserveData memory);
}
