// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseForkTest} from "./BaseFork.t.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";

interface ISparkUsdcVault {
    function psm() external view returns (address);
}

/// @dev Onboarding checklist step 2 (§8): deposit, partial withdraw and full withdraw through the router for
///      every pool in the v1 config, plus the protocol-specific edge cases from the test plan (§11).
contract PoolsForkTest is BaseForkTest {
    uint256 internal constant AMOUNT = 1_000e6;

    address internal constant SKY_SUSDC = 0x3128a0F7f0ea68E7B7c9B00AFa7E41045828e858;
    address internal constant A_BAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;

    // ───────────── Round trips, one per pool (index into config `pools[]`) ─────────────

    function test_roundTrip_00_Sky_sUSDC() public {
        _roundTrip(0, 0.01e18);
    }

    function test_roundTrip_01_Morpho_SteakhousePrime() public {
        _roundTrip(1, 0.01e18);
    }

    function test_roundTrip_02_Morpho_GauntletPrimeV2() public {
        _roundTrip(2, 0.01e18);
    }

    function test_roundTrip_03_Morpho_GauntletFrontier() public {
        _roundTrip(3, 0.01e18);
    }

    function test_roundTrip_04_Morpho_SteakhouseHighYield() public {
        _roundTrip(4, 0.01e18);
    }

    function test_roundTrip_05_Morpho_GroveSteakhouse() public {
        _roundTrip(5, 0.01e18);
    }

    function test_roundTrip_06_Morpho_ClearstarCbAssets() public {
        _roundTrip(6, 0.01e18);
    }

    function test_roundTrip_07_Morpho_GauntletPrimeV1() public {
        _roundTrip(7, 0.01e18);
    }

    function test_roundTrip_08_Morpho_SparkUsdcV1() public {
        _roundTrip(8, 0.01e18);
    }

    function test_roundTrip_09_Fluid_fUSDC() public {
        _roundTrip(9, 0.01e18);
    }

    function test_roundTrip_10_Aave_aBasUSDC() public {
        _roundTrip(10, 0.01e18);
    }

    function test_roundTrip_11_YO_yoUSD() public {
        _roundTrip(11, 0.01e18);
    }

    function test_roundTrip_12_AUTO_baseUSD() public {
        _roundTrip(12, 0.01e18);
    }

    function test_roundTrip_13_Veranta_avUSDC() public {
        // avUSDC's previewRedeem charges an exit fee (~1.48% at the pinned block, §8).
        _roundTrip(13, 0.02e18);
    }

    /// @param maxLoss Max round-trip loss vs the net deposit (1e18 = 100%), covering vault-side fees and slippage.
    /// @dev No `maxDeposit` precheck: Morpho Vault V2 always returns 0 from the max* functions.
    function _roundTrip(uint256 index, uint256 maxLoss) internal {
        address pool = cfg.pools[index].pool;

        // Deposit, to a receiver other than the payer.
        address payer = makeAddr("payer");
        deal(address(usdc), payer, AMOUNT);
        (uint256 fee,,, uint256 expected) = router.previewDeposit(pool, AMOUNT);
        vm.startPrank(payer);
        usdc.approve(address(router), AMOUNT);
        (uint256 shares, uint256 paidFee) =
            router.deposit(pool, AMOUNT, expected * 9_990 / 10_000, alice, block.timestamp, 0);
        vm.stopPrank();

        assertEq(paidFee, fee, "fee");
        assertEq(paidFee, 3e6, "0.30% tier");
        assertEq(usdc.balanceOf(feeRecipient), paidFee);
        assertEq(IERC20(pool).balanceOf(alice), shares, "shares to receiver");
        assertGt(shares, 0);
        _assertRouterClean();

        // Let some time pass (interest, epochs), then partial + full withdraw.
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1_800);
        uint256 got = _withdrawAs(alice, pool, IERC20(pool).balanceOf(alice) / 2);
        got += _withdrawAs(alice, pool, type(uint256).max);

        assertEq(IERC20(pool).balanceOf(alice), 0, "full exit");
        assertEq(usdc.balanceOf(alice), got);
        assertApproxEqRel(got, AMOUNT - paidFee, maxLoss, "round trip loss");
        assertEq(usdc.balanceOf(feeRecipient), paidFee, "no withdrawal fee");
        _assertRouterClean();
    }

    // ───────────── Protocol-specific ─────────────

    /// @dev Large deposits land in the cheaper tiers.
    function test_tiers_onFork() public {
        (, uint256 fee) = _depositAs(alice, A_BAS_USDC, 10_000e6);
        assertEq(fee, 20e6);
        (, fee) = _depositAs(alice, A_BAS_USDC, 100_000e6);
        assertEq(fee, 100e6);
    }

    /// @dev aTokens rebase: a "max" exit a month later leaves no dust with the user or the router.
    function test_aave_fullExitAfterInterest_noDust() public {
        _depositAs(alice, A_BAS_USDC, 25_000e6);
        vm.warp(block.timestamp + 30 days);
        uint256 balance = IERC20(A_BAS_USDC).balanceOf(alice);
        assertGt(balance, 25_000e6 - 50e6, "interest accrued");

        uint256 assets = _withdrawAs(alice, A_BAS_USDC, type(uint256).max);
        assertApproxEqAbs(assets, balance, 1);
        assertEq(IERC20(A_BAS_USDC).balanceOf(alice), 0, "user dust");
        _assertRouterClean();
    }

    /// @dev YO without idle liquidity queues the redeem and returns 0; the router must revert the whole tx.
    function test_yo_queuedRedeemReverts() public {
        (uint256 shares,) = _depositAs(alice, YO_USD, AMOUNT);
        deal(address(usdc), YO_USD, 0); // no idle USDC

        vm.startPrank(alice);
        IERC20(YO_USD).approve(address(router), shares);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.SlippageExceeded.selector, 0, 1));
        router.withdraw(YO_USD, shares, 1, alice, block.timestamp);
        vm.stopPrank();

        assertEq(IERC20(YO_USD).balanceOf(alice), shares, "shares stay with the user");
    }

    /// @dev Spark sUSDC pays out from PSM3. With PSM3 short on USDC the redeem must revert, not leave shares behind.
    function test_sky_psmShortOnUsdc_reverts() public {
        (uint256 shares,) = _depositAs(alice, SKY_SUSDC, AMOUNT);
        deal(address(usdc), ISparkUsdcVault(SKY_SUSDC).psm(), 0);

        vm.startPrank(alice);
        IERC20(SKY_SUSDC).approve(address(router), shares);
        vm.expectRevert();
        router.withdraw(SKY_SUSDC, shares, 1, alice, block.timestamp);
        vm.stopPrank();

        assertEq(IERC20(SKY_SUSDC).balanceOf(alice), shares);
        _assertRouterClean();
    }

    function test_withdrawWorksAfterAllDepositsDisabled() public {
        (uint256 shares,) = _depositAs(alice, SKY_SUSDC, AMOUNT);
        vm.prank(guardian);
        router.disableAllDeposits();

        deal(address(usdc), alice, AMOUNT);
        vm.startPrank(alice);
        usdc.approve(address(router), AMOUNT);
        vm.expectRevert(IRestakeRouter.AllDepositsAreDisabled.selector);
        router.deposit(SKY_SUSDC, AMOUNT, 0, alice, block.timestamp, 0);
        vm.stopPrank();

        assertGt(_withdrawAs(alice, SKY_SUSDC, shares), 0);
    }
}
