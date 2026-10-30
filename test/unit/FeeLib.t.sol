// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {FeeLib} from "../../src/libraries/FeeLib.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";

/// @dev Exposes the internal library so reverts can be asserted.
contract FeeLibHarness {
    function validate(IRestakeRouter.FeeTier[] memory tiers) external pure {
        FeeLib.validate(tiers);
    }

    function tierFor(IRestakeRouter.FeeTier[] memory tiers, uint256 amount) external pure returns (uint8, uint16) {
        return FeeLib.tierFor(tiers, amount);
    }

    function feeFor(uint256 amount, uint16 feeBps) external pure returns (uint256) {
        return FeeLib.feeFor(amount, feeBps);
    }

    function packRoundTrip(IRestakeRouter.FeeTier memory tier) external pure returns (IRestakeRouter.FeeTier memory) {
        return FeeLib.unpack(FeeLib.pack(tier));
    }
}

contract FeeLibTest is Test {
    FeeLibHarness internal lib = new FeeLibHarness();

    function _v1() internal pure returns (IRestakeRouter.FeeTier[] memory tiers) {
        tiers = new IRestakeRouter.FeeTier[](3);
        tiers[0] = IRestakeRouter.FeeTier(0, 30);
        tiers[1] = IRestakeRouter.FeeTier(10_000e6, 20);
        tiers[2] = IRestakeRouter.FeeTier(100_000e6, 10);
    }

    // ───────────── v1.0 schedule ─────────────

    function test_v1Schedule_boundaries() public view {
        _assertTier(0, 0, 30);
        _assertTier(1, 0, 30);
        _assertTier(10_000e6 - 1, 0, 30);
        _assertTier(10_000e6, 1, 20);
        _assertTier(10_000e6 + 1, 1, 20);
        _assertTier(100_000e6 - 1, 1, 20);
        _assertTier(100_000e6, 2, 10);
        _assertTier(100_000e6 + 1, 2, 10);
        _assertTier(type(uint256).max, 2, 10);
    }

    function test_v1Schedule_feeAmounts() public view {
        assertEq(lib.feeFor(1_000e6, 30), 3e6); // 1,000 USDC -> 3 USDC
        assertEq(lib.feeFor(10_000e6, 20), 20e6); // 10,000 USDC -> 20 USDC
        assertEq(lib.feeFor(100_000e6, 10), 100e6); // 100,000 USDC -> 100 USDC
        assertEq(lib.feeFor(333, 30), 0); // dust rounds down to zero
    }

    function _assertTier(uint256 amount, uint8 expectedIndex, uint16 expectedBps) internal view {
        (uint8 index, uint16 bps) = lib.tierFor(_v1(), amount);
        assertEq(index, expectedIndex, "tier index");
        assertEq(bps, expectedBps, "tier bps");
    }

    // ───────────── Fuzz ─────────────

    function testFuzz_feeMath(uint256 amount, uint16 feeBps) public view {
        amount = bound(amount, 0, type(uint256).max / FeeLib.MAX_FEE_BPS);
        feeBps = uint16(bound(feeBps, 0, FeeLib.MAX_FEE_BPS));
        uint256 fee = lib.feeFor(amount, feeBps);
        assertEq(fee, amount * feeBps / 10_000, "rounds down");
        assertLe(fee, amount * FeeLib.MAX_FEE_BPS / 10_000, "fee <= cap");
        assertEq(fee + (amount - fee), amount, "fee + net == gross");
    }

    /// @dev Random valid schedules: tierFor must equal a brute-force "highest tier with minAmount <= amount".
    function testFuzz_tierFor_matchesBruteForce(uint256 seed, uint8 n, uint256 amount) public view {
        IRestakeRouter.FeeTier[] memory tiers = _randomValidTiers(seed, n);
        lib.validate(tiers);

        uint256 expected;
        for (uint256 i; i < tiers.length; ++i) {
            if (tiers[i].minAmount <= amount) expected = i;
        }
        (uint8 index, uint16 bps) = lib.tierFor(tiers, amount);
        assertEq(index, expected);
        assertEq(bps, tiers[expected].feeBps);
    }

    /// @dev Boundaries of a random schedule: minAmount - 1, minAmount, minAmount + 1.
    function testFuzz_tierFor_boundaries(uint256 seed, uint8 n) public view {
        IRestakeRouter.FeeTier[] memory tiers = _randomValidTiers(seed, n);
        for (uint256 i = 1; i < tiers.length; ++i) {
            uint256 m = tiers[i].minAmount;
            (uint8 below,) = lib.tierFor(tiers, m - 1);
            (uint8 at,) = lib.tierFor(tiers, m);
            assertEq(below, i - 1);
            assertEq(at, i);
            if (i + 1 == tiers.length || tiers[i + 1].minAmount > m + 1) {
                (uint8 above,) = lib.tierFor(tiers, m + 1);
                assertEq(above, i);
            }
        }
    }

    function _randomValidTiers(uint256 seed, uint8 n) internal pure returns (IRestakeRouter.FeeTier[] memory tiers) {
        tiers = new IRestakeRouter.FeeTier[](bound(n, 1, FeeLib.MAX_TIERS));
        uint256 min;
        for (uint256 i; i < tiers.length; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (i != 0) min += 1 + r % 1e15;
            tiers[i] = IRestakeRouter.FeeTier(min, uint16(r % (FeeLib.MAX_FEE_BPS + 1)));
        }
    }

    // ───────────── Validation ─────────────

    function test_validate_acceptsV1() public view {
        lib.validate(_v1());
    }

    function test_validate_revertsOnEmpty() public {
        vm.expectRevert(IRestakeRouter.InvalidFeeTiers.selector);
        lib.validate(new IRestakeRouter.FeeTier[](0));
    }

    function test_validate_revertsOnTooMany() public {
        IRestakeRouter.FeeTier[] memory tiers = new IRestakeRouter.FeeTier[](FeeLib.MAX_TIERS + 1);
        for (uint256 i; i < tiers.length; ++i) {
            tiers[i] = IRestakeRouter.FeeTier(i * 1e6, 10);
        }
        vm.expectRevert(IRestakeRouter.InvalidFeeTiers.selector);
        lib.validate(tiers);
    }

    function test_validate_acceptsMaxTiers() public view {
        IRestakeRouter.FeeTier[] memory tiers = new IRestakeRouter.FeeTier[](FeeLib.MAX_TIERS);
        for (uint256 i; i < tiers.length; ++i) {
            tiers[i] = IRestakeRouter.FeeTier(i * 1e6, 10);
        }
        lib.validate(tiers);
    }

    function test_validate_revertsWhenFirstNotZero() public {
        IRestakeRouter.FeeTier[] memory tiers = _v1();
        tiers[0].minAmount = 1;
        vm.expectRevert(IRestakeRouter.InvalidFeeTiers.selector);
        lib.validate(tiers);
    }

    function test_validate_revertsOnUnsorted() public {
        IRestakeRouter.FeeTier[] memory tiers = _v1();
        (tiers[1].minAmount, tiers[2].minAmount) = (tiers[2].minAmount, tiers[1].minAmount);
        vm.expectRevert(IRestakeRouter.InvalidFeeTiers.selector);
        lib.validate(tiers);
    }

    function test_validate_revertsOnEqualMinAmounts() public {
        IRestakeRouter.FeeTier[] memory tiers = _v1();
        tiers[2].minAmount = tiers[1].minAmount;
        vm.expectRevert(IRestakeRouter.InvalidFeeTiers.selector);
        lib.validate(tiers);
    }

    function test_validate_revertsAboveCap() public {
        IRestakeRouter.FeeTier[] memory tiers = _v1();
        tiers[1].feeBps = FeeLib.MAX_FEE_BPS + 1;
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.FeeTooHigh.selector, FeeLib.MAX_FEE_BPS + 1));
        lib.validate(tiers);
    }

    function test_validate_acceptsMaxMinAmount() public view {
        IRestakeRouter.FeeTier[] memory tiers = _v1();
        tiers[2].minAmount = FeeLib.MAX_MIN_AMOUNT;
        lib.validate(tiers);
    }

    function test_validate_revertsAboveMaxMinAmount() public {
        IRestakeRouter.FeeTier[] memory tiers = _v1();
        tiers[2].minAmount = FeeLib.MAX_MIN_AMOUNT + 1;
        vm.expectRevert(IRestakeRouter.InvalidFeeTiers.selector);
        lib.validate(tiers);
    }

    // ───────────── Packing ─────────────

    function testFuzz_packRoundTrip(uint256 minAmount, uint16 feeBps) public view {
        minAmount = bound(minAmount, 0, FeeLib.MAX_MIN_AMOUNT);
        IRestakeRouter.FeeTier memory tier = lib.packRoundTrip(IRestakeRouter.FeeTier(minAmount, feeBps));
        assertEq(tier.minAmount, minAmount);
        assertEq(tier.feeBps, feeBps);
    }

    function test_validate_acceptsCapAndZero() public view {
        IRestakeRouter.FeeTier[] memory tiers = _v1();
        tiers[0].feeBps = FeeLib.MAX_FEE_BPS;
        tiers[2].feeBps = 0;
        lib.validate(tiers);
    }
}
