// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract GuardianTest is BaseTest {
    function test_disablePoolDeposits() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.PoolDepositsDisabled(address(vault));
        vm.prank(guardian);
        router.disablePoolDeposits(address(vault));

        assertTrue(router.depositsDisabled(address(vault)));
        assertFalse(router.depositsDisabled(address(vault18)));
        assertFalse(router.allDepositsDisabled());
    }

    function test_disableAllDeposits() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.AllDepositsDisabled();
        vm.prank(guardian);
        router.disableAllDeposits();
        assertTrue(router.allDepositsDisabled());
    }

    function testFuzz_revert_notGuardian(address caller) public {
        vm.assume(caller != guardian);
        vm.startPrank(caller);
        vm.expectRevert(IRestakeRouter.NotGuardian.selector);
        router.disablePoolDeposits(address(vault));
        vm.expectRevert(IRestakeRouter.NotGuardian.selector);
        router.disableAllDeposits();
        vm.stopPrank();
    }

    function test_revert_disableUnknownPool() public {
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.PoolNotRegistered.selector, address(usdc)));
        vm.prank(guardian);
        router.disablePoolDeposits(address(usdc));
    }

    /// @dev One-way: disabling again keeps it disabled, and no function re-enables.
    function test_switchesAreOneWay() public {
        vm.startPrank(guardian);
        router.disablePoolDeposits(address(vault));
        router.disablePoolDeposits(address(vault));
        router.disableAllDeposits();
        router.disableAllDeposits();
        vm.stopPrank();
        assertTrue(router.depositsDisabled(address(vault)));
        assertTrue(router.allDepositsDisabled());

        // No re-enable entry point exists in the ABI.
        bytes4[4] memory candidates = [
            bytes4(keccak256("enablePoolDeposits(address)")),
            bytes4(keccak256("enableAllDeposits()")),
            bytes4(keccak256("setDepositsDisabled(address,bool)")),
            bytes4(keccak256("setAllDepositsDisabled(bool)"))
        ];
        for (uint256 i; i < candidates.length; ++i) {
            vm.prank(guardian);
            (bool ok,) = address(router).call(abi.encodePacked(candidates[i], abi.encode(address(vault))));
            assertFalse(ok);
        }
        assertTrue(router.allDepositsDisabled());
    }

    // ───────────── Sweep ─────────────

    function test_sweep() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(router), 5e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Swept(address(stray), 5e18);
        vm.prank(bob); // anyone
        router.sweep(address(stray));

        assertEq(stray.balanceOf(feeRecipient), 5e18);
        assertEq(stray.balanceOf(address(router)), 0);
    }

    function test_sweep_shares() public {
        uint256 shares = _deposit(alice, address(vault), 1_000e6);
        vm.prank(alice);
        vault.transfer(address(router), shares);
        router.sweep(address(vault));
        assertEq(vault.balanceOf(feeRecipient), shares);
    }

    function test_revert_sweepNothing() public {
        vm.expectRevert(IRestakeRouter.ZeroAmount.selector);
        router.sweep(address(usdc));
    }
}
