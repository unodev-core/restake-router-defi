// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {BaseTest} from "./BaseTest.sol";
import {RestakeRouter} from "../../src/RestakeRouter.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {MockFeeOnTransferToken} from "./mocks/MockERC20.sol";
import {MockERC4626, MockLossyVault, MockReentrantVault} from "./mocks/MockVaults.sol";

contract DepositTest is BaseTest {
    bytes32 internal constant REFERRAL = bytes32("partner-42");

    // ───────────── Happy paths ─────────────

    function test_deposit_erc4626() public {
        uint256 amount = 1_000e6;
        _fundAndApprove(alice, amount);
        uint256 expectedShares = vault18.previewDeposit(amount - 3e6);

        vm.prank(alice);
        (uint256 shares, uint256 fee) = router.deposit(address(vault18), amount, 0, alice, block.timestamp, REFERRAL);

        assertEq(fee, 3e6, "0.30% fee");
        assertEq(shares, expectedShares, "shares");
        assertEq(vault18.balanceOf(alice), shares, "alice shares");
        assertEq(usdc.balanceOf(feeRecipient), fee, "fee recipient");
        assertEq(usdc.balanceOf(alice), 0, "alice paid all");
        assertEq(vault18.totalAssets(), amount - fee, "vault got net");
        _assertRouterClean();
    }

    function test_deposit_aave() public {
        uint256 amount = 50_000e6;
        _fundAndApprove(alice, amount);

        vm.prank(alice);
        (uint256 shares, uint256 fee) = router.deposit(address(aToken), amount, 0, alice, block.timestamp, 0);

        assertEq(fee, 100e6, "0.20% fee");
        assertEq(shares, amount - fee, "aTokens 1:1 at index 1");
        assertEq(aToken.balanceOf(alice), shares);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        _assertRouterClean();
    }

    function test_deposit_aave_afterInterest_sharesAreBalanceDelta() public {
        _deposit(bob, address(aToken), 1_000e6);
        _accrueAaveInterest(537);
        uint256 before = aToken.balanceOf(alice);

        uint256 amount = 777_777_777;
        _fundAndApprove(alice, amount);
        vm.prank(alice);
        (uint256 shares, uint256 fee) = router.deposit(address(aToken), amount, 0, alice, block.timestamp, 0);

        assertEq(shares, aToken.balanceOf(alice) - before);
        assertApproxEqAbs(shares, amount - fee, 1);
        _assertRouterClean();
    }

    function test_deposit_toOtherReceiver() public {
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        (uint256 shares,) = router.deposit(address(vault), 1_000e6, 0, bob, block.timestamp, 0);
        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_deposit_tierBoundaries() public {
        _assertDepositFee(10_000e6 - 1, 29_999_999, 0, 30);
        _assertDepositFee(10_000e6, 20e6, 1, 20);
        _assertDepositFee(100_000e6 - 1, 199_999_999, 1, 20);
        _assertDepositFee(100_000e6, 100e6, 2, 10);
    }

    function test_deposit_dustSkipsFeeTransfer() public {
        _fundAndApprove(alice, 333);
        vm.prank(alice);
        (uint256 shares, uint256 fee) = router.deposit(address(vault), 333, 0, alice, block.timestamp, 0);
        assertEq(fee, 0);
        assertEq(shares, 333);
        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function test_deposit_zeroFeeTier() public {
        IRestakeRouter.FeeTier[] memory tiers = new IRestakeRouter.FeeTier[](1);
        router = _deployRouter(tiers, defaultPools());
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        (, uint256 fee) = router.deposit(address(vault), 1_000e6, 0, alice, block.timestamp, 0);
        assertEq(fee, 0);
        assertEq(vault.totalAssets(), 1_000e6);
    }

    function testFuzz_deposit(uint256 amount, uint8 poolIndex, bool otherReceiver) public {
        amount = bound(amount, 1, 10_000_000e6);
        address pool = _pool(bound(poolIndex, 0, 3));
        address receiver = otherReceiver ? bob : alice;
        (uint256 expectedFee,, uint256 expectedNet, uint256 expectedShares) = router.previewDeposit(pool, amount);

        _fundAndApprove(alice, amount);
        vm.prank(alice);
        (uint256 shares, uint256 fee) = router.deposit(pool, amount, expectedShares, receiver, block.timestamp, 0);

        assertEq(fee, expectedFee);
        assertEq(shares, expectedShares);
        assertEq(fee + expectedNet, amount);
        assertLe(fee, amount * router.MAX_FEE_BPS() / 10_000);
        assertEq(IERC20(pool).balanceOf(receiver), shares);
        _assertRouterClean();
    }

    function _assertDepositFee(uint256 amount, uint256 expectedFee, uint8 tier, uint16 bps) internal {
        address user = makeAddr(vm.toString(amount));
        _fundAndApprove(user, amount);
        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Deposit(
            user,
            user,
            address(vault),
            address(usdc),
            amount,
            expectedFee,
            amount - expectedFee,
            vault.previewDeposit(amount - expectedFee),
            tier,
            bps,
            0
        );
        vm.prank(user);
        (, uint256 fee) = router.deposit(address(vault), amount, 0, user, block.timestamp, 0);
        assertEq(fee, expectedFee);
    }

    // ───────────── Events ─────────────

    function test_deposit_event_withReferral() public {
        _fundAndApprove(alice, 1_000e6);
        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Deposit(
            alice,
            bob,
            address(vault18),
            address(usdc),
            1_000e6,
            3e6,
            997e6,
            vault18.previewDeposit(997e6),
            0,
            30,
            REFERRAL
        );
        vm.prank(alice);
        router.deposit(address(vault18), 1_000e6, 0, bob, block.timestamp, REFERRAL);
    }

    function test_deposit_event_noReferral() public {
        _fundAndApprove(alice, 200_000e6);
        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Deposit(
            alice, alice, address(aToken), address(usdc), 200_000e6, 200e6, 199_800e6, 199_800e6, 2, 10, bytes32(0)
        );
        vm.prank(alice);
        router.deposit(address(aToken), 200_000e6, 0, alice, block.timestamp, bytes32(0));
    }

    // ───────────── Reverts ─────────────

    function test_revert_slippage() public {
        _fundAndApprove(alice, 1_000e6);
        uint256 shares = vault.previewDeposit(997e6);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.SlippageExceeded.selector, shares, shares + 1));
        vm.prank(alice);
        router.deposit(address(vault), 1_000e6, shares + 1, alice, block.timestamp, 0);
    }

    function test_revert_deadline() public {
        _fundAndApprove(alice, 1_000e6);
        vm.expectRevert(IRestakeRouter.DeadlineExpired.selector);
        vm.prank(alice);
        router.deposit(address(vault), 1_000e6, 0, alice, block.timestamp - 1, 0);
    }

    function test_revert_zeroAmount() public {
        vm.expectRevert(IRestakeRouter.ZeroAmount.selector);
        vm.prank(alice);
        router.deposit(address(vault), 0, 0, alice, block.timestamp, 0);
    }

    function test_revert_unregisteredPool() public {
        MockERC4626 unknown = new MockERC4626(usdc, 0);
        _fundAndApprove(alice, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.PoolNotRegistered.selector, address(unknown)));
        vm.prank(alice);
        router.deposit(address(unknown), 1_000e6, 0, alice, block.timestamp, 0);
    }

    function test_revert_invalidReceiver() public {
        _fundAndApprove(alice, 1_000e6);
        address[3] memory bad = [address(0), address(router), address(vault)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.InvalidReceiver.selector, bad[i]));
            vm.prank(alice);
            router.deposit(address(vault), 1_000e6, 0, bad[i], block.timestamp, 0);
        }
    }

    function test_revert_poolDepositsDisabled() public {
        vm.prank(guardian);
        router.disablePoolDeposits(address(vault));
        _fundAndApprove(alice, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.DepositsDisabled.selector, address(vault)));
        vm.prank(alice);
        router.deposit(address(vault), 1_000e6, 0, alice, block.timestamp, 0);

        // Other pools are unaffected.
        vm.prank(alice);
        router.deposit(address(vault18), 1_000e6, 0, alice, block.timestamp, 0);
    }

    function test_revert_allDepositsDisabled() public {
        vm.prank(guardian);
        router.disableAllDeposits();
        _fundAndApprove(alice, 1_000e6);
        vm.expectRevert(IRestakeRouter.AllDepositsAreDisabled.selector);
        vm.prank(alice);
        router.deposit(address(aToken), 1_000e6, 0, alice, block.timestamp, 0);
    }

    function test_revert_feeOnTransferUnderlying() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        MockERC4626 fotVault = new MockERC4626(fot, 0);
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(fotVault), IRestakeRouter.PoolType.ERC4626);
        RestakeRouter r =
            new RestakeRouter(feeRecipient, guardian, address(fot), address(0), address(0), defaultTiers(), pools);

        fot.mint(alice, 1_000e6);
        vm.prank(alice);
        fot.approve(address(r), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.UnexpectedTransferAmount.selector, 1_000e6, 990e6));
        vm.prank(alice);
        r.deposit(address(fotVault), 1_000e6, 0, alice, block.timestamp, 0);
    }

    function test_revert_vaultTakesLessThanNet() public {
        MockLossyVault lossy = new MockLossyVault(usdc);
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(lossy), IRestakeRouter.PoolType.ERC4626);
        router = _deployRouter(defaultTiers(), pools);

        _fundAndApprove(alice, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.UnexpectedTransferAmount.selector, 997e6, 498.5e6));
        vm.prank(alice);
        router.deposit(address(lossy), 1_000e6, 0, alice, block.timestamp, 0);
    }

    function test_revert_reentrancy() public {
        MockReentrantVault evil = new MockReentrantVault(usdc);
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(evil), IRestakeRouter.PoolType.ERC4626);
        router = _deployRouter(defaultTiers(), pools);
        evil.arm(router, abi.encodeCall(IRestakeRouter.sweep, (address(usdc))));

        _fundAndApprove(alice, 1_000e6);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        router.deposit(address(evil), 1_000e6, 0, alice, block.timestamp, 0);
    }

    /// @dev Invariant 1: a standing approval can only be spent by its owner.
    function test_onlyPullsFromMsgSender() public {
        _fundAndApprove(alice, 1_000e6);
        vm.expectRevert(); // bob has no USDC / allowance
        vm.prank(bob);
        router.deposit(address(vault), 1_000e6, 0, bob, block.timestamp, 0);
        assertEq(usdc.balanceOf(alice), 1_000e6);
    }

    // ───────────── Preview ─────────────

    function test_previewDeposit() public view {
        (uint256 fee, uint8 tier, uint256 net, uint256 expected) = router.previewDeposit(address(vault18), 20_000e6);
        assertEq(fee, 40e6);
        assertEq(tier, 1);
        assertEq(net, 19_960e6);
        assertEq(expected, vault18.previewDeposit(19_960e6));

        (,,, expected) = router.previewDeposit(address(aToken), 20_000e6);
        assertEq(expected, 19_960e6);
    }

    function test_previewDeposit_revertsForUnknownPool() public {
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.PoolNotRegistered.selector, address(usdc)));
        router.previewDeposit(address(usdc), 1e6);
    }
}
