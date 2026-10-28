// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRestakeRouter} from "../interfaces/IRestakeRouter.sol";

/// @title FeeLib
/// @notice Fee tier validation, tier lookup and fee math. Pure, so it can be fuzzed in isolation.
library FeeLib {
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant MAX_FEE_BPS = 100; // 1%
    uint256 internal constant MAX_TIERS = 5;

    /// @dev Reverts unless: 1 <= length <= MAX_TIERS, tiers[0].minAmount == 0, minAmount strictly ascending,
    ///      and every feeBps <= MAX_FEE_BPS.
    function validate(IRestakeRouter.FeeTier[] memory tiers) internal pure {
        uint256 n = tiers.length;
        if (n == 0 || n > MAX_TIERS || tiers[0].minAmount != 0) revert IRestakeRouter.InvalidFeeTiers();
        for (uint256 i; i < n; ++i) {
            if (tiers[i].feeBps > MAX_FEE_BPS) revert IRestakeRouter.FeeTooHigh(tiers[i].feeBps);
            if (i != 0 && tiers[i].minAmount <= tiers[i - 1].minAmount) revert IRestakeRouter.InvalidFeeTiers();
        }
    }

    /// @notice The highest tier with `minAmount <= amount`.
    /// @dev Assumes `tiers` passed `validate`, so tiers[0].minAmount == 0 bounds the scan.
    function tierFor(IRestakeRouter.FeeTier[] memory tiers, uint256 amount)
        internal
        pure
        returns (uint8 index, uint16 feeBps)
    {
        uint256 i = tiers.length - 1;
        for (; tiers[i].minAmount > amount; --i) {}
        // forge-lint: disable-next-line(unsafe-typecast) i < MAX_TIERS
        return (uint8(i), tiers[i].feeBps);
    }

    /// @dev Rounds down, in the user's favor.
    function feeFor(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return amount * feeBps / BPS_DENOMINATOR;
    }
}
