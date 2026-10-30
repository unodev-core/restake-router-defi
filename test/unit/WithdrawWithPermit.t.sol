// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {BaseTest} from "./BaseTest.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";

contract WithdrawWithPermitTest is BaseTest {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal ownerKey = 0xA11CE;
    address internal owner = vm.addr(ownerKey);

    function test_withdrawWithPermit() public {
        uint256 shares = _deposit(owner, address(vault18), 1_000e6);
        uint256 expected = vault18.previewRedeem(shares);
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault18), ownerKey, owner, shares, block.timestamp);

        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Withdraw(owner, bob, address(vault18), address(usdc), shares, expected, USER_REF);
        vm.prank(owner);
        uint256 assets =
            router.withdrawWithPermit(address(vault18), shares, expected, bob, block.timestamp, USER_REF, v, r, s);

        assertEq(assets, expected);
        assertEq(usdc.balanceOf(bob), expected);
        assertEq(vault18.balanceOf(owner), 0);
        assertEq(vault18.allowance(owner, address(router)), 0, "permit fully consumed");
        assertEq(vault18.nonces(owner), 1);
        _assertRouterClean();
    }

    /// @dev Full exit: the signature covers type(uint256).max, the router pulls the whole balance.
    function test_withdrawWithPermit_full_max() public {
        uint256 shares = _deposit(owner, address(vault), 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), ownerKey, owner, type(uint256).max, block.timestamp);
        vm.prank(owner);
        uint256 assets =
            router.withdrawWithPermit(address(vault), type(uint256).max, 1, owner, block.timestamp, 0, v, r, s);
        assertEq(assets, 997e6);
        assertEq(vault.balanceOf(owner), 0);
        assertEq(shares, 997e6);
        _assertRouterClean();
    }

    /// @dev Someone submits the signature to the vault first: the router's permit call reverts on the used
    ///      nonce, but the allowance is already set, so the withdrawal still goes through.
    function test_withdrawWithPermit_frontRunPermit() public {
        uint256 shares = _deposit(owner, address(vault), 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), ownerKey, owner, shares, block.timestamp);
        vm.prank(bob);
        vault.permit(owner, address(router), shares, block.timestamp, v, r, s);

        vm.prank(owner);
        uint256 assets = router.withdrawWithPermit(address(vault), shares, 1, owner, block.timestamp, 0, v, r, s);
        assertEq(assets, 997e6);
        _assertRouterClean();
    }

    /// @dev The mock aToken has no `permit` (like yoUSD / avUSDC on Base): with an existing approval and a
    ///      junk signature the withdrawal behaves exactly like plain `withdraw`.
    function test_withdrawWithPermit_tokenWithoutPermit_existingApproval() public {
        uint256 shares = _deposit(owner, address(aToken), 100_000e6);
        _approveShares(owner, address(aToken), type(uint256).max);
        vm.prank(owner);
        uint256 assets = router.withdrawWithPermit(
            address(aToken), type(uint256).max, 1, owner, block.timestamp, 0, 27, bytes32(0), bytes32(0)
        );
        assertEq(assets, shares);
        assertEq(aToken.balanceOf(owner), 0);
        _assertRouterClean();
    }

    function test_revert_withdrawWithPermit_tokenWithoutPermit_noApproval() public {
        _deposit(owner, address(aToken), 100_000e6);
        vm.expectRevert();
        vm.prank(owner);
        router.withdrawWithPermit(
            address(aToken), type(uint256).max, 1, owner, block.timestamp, 0, 27, bytes32(0), bytes32(0)
        );
    }

    function test_revert_withdrawWithPermit_badSignature() public {
        uint256 shares = _deposit(owner, address(vault), 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), 0xB0B, owner, shares, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, shares)
        );
        vm.prank(owner);
        router.withdrawWithPermit(address(vault), shares, 1, owner, block.timestamp, 0, v, r, s);
    }

    /// @dev The permit owner is always msg.sender: a third party can't redeem someone else's shares.
    function test_revert_withdrawWithPermit_callerNotOwner() public {
        uint256 shares = _deposit(owner, address(vault), 1_000e6);
        _deposit(bob, address(vault), 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), ownerKey, owner, shares, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, shares)
        );
        vm.prank(bob);
        router.withdrawWithPermit(address(vault), shares, 1, bob, block.timestamp, 0, v, r, s);
        assertEq(vault.balanceOf(owner), shares);
    }

    /// @dev Signature covers fewer shares than the withdrawal.
    function test_revert_withdrawWithPermit_amountMismatch() public {
        uint256 shares = _deposit(owner, address(vault), 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), ownerKey, owner, shares / 2, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, shares)
        );
        vm.prank(owner);
        router.withdrawWithPermit(address(vault), shares, 1, owner, block.timestamp, 0, v, r, s);
    }

    /// @dev A signature for one vault can't be replayed against another (different EIP-712 domain).
    function test_revert_withdrawWithPermit_wrongPool() public {
        uint256 shares = _deposit(owner, address(vault), 1_000e6);
        _deposit(owner, address(asyncVault), 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), ownerKey, owner, shares, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, shares)
        );
        vm.prank(owner);
        router.withdrawWithPermit(address(asyncVault), shares, 1, owner, block.timestamp, 0, v, r, s);
    }

    function test_revert_withdrawWithPermit_deadline() public {
        uint256 shares = _deposit(owner, address(vault), 1_000e6);
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), ownerKey, owner, shares, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(IRestakeRouter.DeadlineExpired.selector);
        vm.prank(owner);
        router.withdrawWithPermit(address(vault), shares, 1, owner, deadline, 0, v, r, s);
    }

    function test_revert_withdrawWithPermit_unregisteredPool() public {
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.PoolNotRegistered.selector, address(usdc)));
        vm.prank(owner);
        router.withdrawWithPermit(address(usdc), 1, 1, owner, block.timestamp, 0, 27, bytes32(0), bytes32(0));
    }

    /// @dev Withdrawals stay open after the guardian kills deposits.
    function test_withdrawWithPermit_afterAllDepositsDisabled() public {
        uint256 shares = _deposit(owner, address(vault), 1_000e6);
        vm.prank(guardian);
        router.disableAllDeposits();
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), ownerKey, owner, shares, block.timestamp);
        vm.prank(owner);
        assertEq(router.withdrawWithPermit(address(vault), shares, 1, owner, block.timestamp, 0, v, r, s), 997e6);
    }

    function testFuzz_withdrawWithPermit(uint256 amount, uint256 sharesToWithdraw) public {
        amount = bound(amount, 1_000, 10_000_000e6);
        uint256 shares = _deposit(owner, address(vault18), amount);
        sharesToWithdraw = bound(sharesToWithdraw, 1, shares);
        vm.assume(vault18.previewRedeem(sharesToWithdraw) > 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault18), ownerKey, owner, sharesToWithdraw, block.timestamp);
        vm.prank(owner);
        router.withdrawWithPermit(address(vault18), sharesToWithdraw, 1, owner, block.timestamp, 0, v, r, s);
        assertEq(vault18.balanceOf(owner), shares - sharesToWithdraw);
        assertEq(vault18.allowance(owner, address(router)), 0);
        _assertRouterClean();
    }

    function _sign(address token, uint256 key, address holder, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        IERC20Permit t = IERC20Permit(token);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, address(router), value, t.nonces(holder), deadline));
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), structHash)));
    }
}
