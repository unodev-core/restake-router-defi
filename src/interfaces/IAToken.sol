// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal Aave V3 aToken interface used by the router.
interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
