// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {BaseTest} from "./BaseTest.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {MockLossyVault, MockReentrantVault} from "./mocks/MockVaults.sol";

contract WithdrawTest is BaseTest {
    // ───────────── ERC-4626 ─────────────

    function test_withdraw_partial() public {
        uint256 shares = _deposit(alice, address(vault18), 1_000e6);
        uint256 half = shares / 2;
        uint256 expected = vault18.previewRedeem(half);
        _approveShares(alice, address(vault18), half);

        vm.prank(alice);
        uint256 assets = router.withdraw(address(vault18), half, expected, alice, block.timestamp, bytes32(0));

        assertEq(assets, expected);
        assertEq(usdc.balanceOf(alice), assets);
        assertEq(vault18.balanceOf(alice), shares - half);
        assertEq(usdc.balanceOf(feeRecipient), 3e6, "no withdrawal fee");
        _assertRouterClean();
    }

    function test_withdraw_full_max() public {
        uint256 shares = _deposit(alice, address(vault), 1_000e6);
        _approveShares(alice, address(vault), type(uint256).max);

        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Withdraw(alice, bob, address(vault), address(usdc), shares, 997e6, USER_REF);
        vm.prank(alice);
        uint256 assets = router.withdraw(address(vault), type(uint256).max, 1, bob, block.timestamp, USER_REF);

        assertEq(assets, 997e6);
        assertEq(usdc.balanceOf(bob), 997e6);
        assertEq(vault.balanceOf(alice), 0);
        _assertRouterClean();
    }

    function test_withdraw_asyncVault_instant() public {
        uint256 shares = _deposit(alice, address(asyncVault), 1_000e6);
        _approveShares(alice, address(asyncVault), shares);
        vm.prank(alice);
        uint256 assets = router.withdraw(address(asyncVault), shares, 1, alice, block.timestamp, bytes32(0));
        assertEq(assets, 997e6);
        _assertRouterClean();
    }

    /// @dev YO without idle liquidity: redeem queues and returns 0. minAssets > 0 must revert the whole tx,
    ///      so the shares never sit in a queue owned by the router.
    function test_revert_asyncVault_queuedRedeem() public {
        uint256 shares = _deposit(alice, address(asyncVault), 1_000e6);
        asyncVault.setInstant(false);
        _approveShares(alice, address(asyncVault), shares);

        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.SlippageExceeded.selector, 0, 1));
        vm.prank(alice);
        router.withdraw(address(asyncVault), shares, 1, alice, block.timestamp, bytes32(0));

        assertEq(asyncVault.balanceOf(alice), shares, "shares back with alice");
        assertEq(asyncVault.pendingShares(alice), 0, "nothing queued");
    }

    function test_revert_vaultBurnsFewerShares() public {
        MockLossyVault lossy = new MockLossyVault(usdc);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(lossy), 1_000e6);
        uint256 shares = lossy.deposit(1_000e6, alice);
        vm.stopPrank();

        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(lossy), IRestakeRouter.PoolType.ERC4626);
        router = _deployRouter(defaultTiers(), pools);
        _approveShares(alice, address(lossy), shares);

        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.UnexpectedTransferAmount.selector, shares, shares / 2));
        vm.prank(alice);
        router.withdraw(address(lossy), shares, 1, alice, block.timestamp, bytes32(0));
    }

    // ───────────── Aave ─────────────

    function test_withdraw_aave_partial() public {
        uint256 aBal = _deposit(alice, address(aToken), 10_000e6);
        _accrueAaveInterest(311);
        uint256 amount = aToken.balanceOf(alice) / 3;
        _approveShares(alice, address(aToken), amount);

        vm.prank(alice);
        uint256 assets = router.withdraw(address(aToken), amount, amount - 1, alice, block.timestamp, bytes32(0));

        assertApproxEqAbs(assets, amount, 1);
        assertGt(aToken.balanceOf(alice), aBal - amount, "interest kept");
        _assertRouterClean();
    }

    /// @dev aTokens rebase every block: "withdraw all" must leave no dust with the user or the router.
    function test_withdraw_aave_full_noDust() public {
        _deposit(alice, address(aToken), 12_345_678_901);
        _deposit(bob, address(aToken), 3e6);
        _approveShares(alice, address(aToken), type(uint256).max);

        // Interest accrues between signing and inclusion.
        _accrueAaveInterest(123);
        uint256 balance = aToken.balanceOf(alice);

        vm.prank(alice);
        uint256 assets =
            router.withdraw(address(aToken), type(uint256).max, balance - 1, alice, block.timestamp, bytes32(0));

        assertApproxEqAbs(assets, balance, 1);
        assertEq(aToken.scaledBalanceOf(alice), 0, "alice dust");
        assertEq(aToken.scaledBalanceOf(address(router)), 0, "router dust");
        _assertRouterClean();
    }

    function testFuzz_withdraw_aave(uint256 amount, uint256 interestBps, uint256 fraction) public {
        amount = bound(amount, 1e6, 10_000_000e6);
        interestBps = bound(interestBps, 0, 5_000);
        fraction = bound(fraction, 1, 100);

        _deposit(alice, address(aToken), amount);
        if (interestBps != 0) _accrueAaveInterest(interestBps);
        uint256 balance = aToken.balanceOf(alice);
        uint256 toWithdraw = fraction == 100 ? type(uint256).max : balance * fraction / 100;
        if (toWithdraw == 0) return;
        _approveShares(alice, address(aToken), type(uint256).max);

        vm.prank(alice);
        uint256 assets = router.withdraw(address(aToken), toWithdraw, 1, alice, block.timestamp, bytes32(0));

        assertApproxEqAbs(assets, fraction == 100 ? balance : toWithdraw, 1);
        assertEq(aToken.scaledBalanceOf(address(router)), 0);
        _assertRouterClean();
    }

    /// @dev Donated aTokens stay put (for sweep) instead of being paid out to the withdrawing user.
    function test_withdraw_aave_withDonation() public {
        _deposit(bob, address(aToken), 1_000e6);
        vm.prank(bob);
        aToken.transfer(address(router), 10e6);

        uint256 shares = _deposit(alice, address(aToken), 1_000e6);
        _approveShares(alice, address(aToken), shares);
        vm.prank(alice);
        uint256 assets = router.withdraw(address(aToken), shares, 1, alice, block.timestamp, bytes32(0));

        assertApproxEqAbs(assets, shares, 1);
        assertApproxEqAbs(aToken.balanceOf(address(router)), 10e6, 1);
    }

    // ───────────── Kill switches don't touch withdrawals ─────────────

    function test_withdraw_worksWhileDepositsDisabled() public {
        address[] memory pools = router.getPools();
        uint256[] memory shares = new uint256[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            shares[i] = _deposit(alice, pools[i], 1_000e6);
        }

        vm.startPrank(guardian);
        router.disablePoolDeposits(pools[0]);
        router.disableAllDeposits();
        vm.stopPrank();

        for (uint256 i; i < pools.length; ++i) {
            _approveShares(alice, pools[i], type(uint256).max);
            vm.prank(alice);
            router.withdraw(pools[i], type(uint256).max, 1, alice, block.timestamp, bytes32(0));
            assertEq(IERC20(pools[i]).balanceOf(alice), 0);
        }
        _assertRouterClean();
    }

    // ───────────── Reverts ─────────────

    function test_revert_slippage() public {
        uint256 shares = _deposit(alice, address(vault), 1_000e6);
        _approveShares(alice, address(vault), shares);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.SlippageExceeded.selector, 997e6, 997e6 + 1));
        vm.prank(alice);
        router.withdraw(address(vault), shares, 997e6 + 1, alice, block.timestamp, bytes32(0));
    }

    function test_revert_zeroMinAssets() public {
        uint256 shares = _deposit(alice, address(vault), 1_000e6);
        vm.expectRevert(IRestakeRouter.ZeroAmount.selector);
        vm.prank(alice);
        router.withdraw(address(vault), shares, 0, alice, block.timestamp, bytes32(0));
    }

    function test_revert_zeroShares() public {
        vm.expectRevert(IRestakeRouter.ZeroAmount.selector);
        vm.prank(alice);
        router.withdraw(address(vault), 0, 1, alice, block.timestamp, bytes32(0));

        // "max" with an empty balance is also zero.
        vm.expectRevert(IRestakeRouter.ZeroAmount.selector);
        vm.prank(alice);
        router.withdraw(address(vault), type(uint256).max, 1, alice, block.timestamp, bytes32(0));
    }

    function test_revert_deadline() public {
        uint256 shares = _deposit(alice, address(vault), 1_000e6);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(IRestakeRouter.DeadlineExpired.selector);
        vm.prank(alice);
        router.withdraw(address(vault), shares, 1, alice, block.timestamp - 1, bytes32(0));
    }

    function test_revert_unregisteredPool() public {
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.PoolNotRegistered.selector, address(usdc)));
        vm.prank(alice);
        router.withdraw(address(usdc), 1, 1, alice, block.timestamp, bytes32(0));
    }

    function test_revert_invalidReceiver() public {
        uint256 shares = _deposit(alice, address(vault), 1_000e6);
        address[3] memory bad = [address(0), address(router), address(vault)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.InvalidReceiver.selector, bad[i]));
            vm.prank(alice);
            router.withdraw(address(vault), shares, 1, bad[i], block.timestamp, bytes32(0));
        }
    }

    function test_revert_reentrancy() public {
        MockReentrantVault evil = new MockReentrantVault(usdc);
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(evil), IRestakeRouter.PoolType.ERC4626);
        router = _deployRouter(defaultTiers(), pools);
        uint256 shares = _deposit(alice, address(evil), 1_000e6);

        evil.arm(
            router, abi.encodeCall(IRestakeRouter.withdraw, (address(evil), 1, 1, alice, block.timestamp, bytes32(0)))
        );
        _approveShares(alice, address(evil), shares);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        router.withdraw(address(evil), shares, 1, alice, block.timestamp, bytes32(0));
    }

    /// @dev Invariant 1: bob can't spend alice's standing share approval.
    function test_onlyPullsFromMsgSender() public {
        uint256 shares = _deposit(alice, address(vault), 1_000e6);
        _approveShares(alice, address(vault), type(uint256).max);
        vm.expectRevert(IRestakeRouter.ZeroAmount.selector);
        vm.prank(bob);
        router.withdraw(address(vault), type(uint256).max, 1, bob, block.timestamp, bytes32(0));
        vm.expectRevert();
        vm.prank(bob);
        router.withdraw(address(vault), shares, 1, bob, block.timestamp, bytes32(0));
        assertEq(vault.balanceOf(alice), shares);
    }

    // ───────────── Preview ─────────────

    function test_previewWithdraw() public {
        uint256 shares = _deposit(alice, address(vault18), 1_000e6);
        assertEq(router.previewWithdraw(address(vault18), shares), vault18.previewRedeem(shares));
        assertEq(router.previewWithdraw(address(aToken), 123e6), 123e6);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.PoolNotRegistered.selector, address(usdc)));
        router.previewWithdraw(address(usdc), 1);
    }
}
