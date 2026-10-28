// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {BaseTest} from "./BaseTest.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";

contract DepositWithPermitTest is BaseTest {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant REF = "omnibus";

    uint256 internal ownerKey = 0xA11CE;
    address internal owner = vm.addr(ownerKey);

    function test_depositWithPermit() public {
        usdc.mint(owner, 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, 1_000e6, block.timestamp);

        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Deposit(
            owner, bob, address(vault), address(usdc), 1_000e6, 3e6, 997e6, 997e6, 0, 30, REF, USER_REF
        );
        vm.prank(owner);
        (uint256 shares, uint256 fee) =
            router.depositWithPermit(address(vault), 1_000e6, 997e6, bob, block.timestamp, REF, USER_REF, v, r, s);

        assertEq(shares, 997e6);
        assertEq(fee, 3e6);
        assertEq(vault.balanceOf(bob), 997e6);
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(usdc.allowance(owner, address(router)), 0, "permit fully consumed");
        assertEq(usdc.nonces(owner), 1);
        _assertRouterClean();
    }

    function test_depositWithPermit_aave() public {
        usdc.mint(owner, 100_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, 100_000e6, block.timestamp);
        vm.prank(owner);
        (uint256 shares,) =
            router.depositWithPermit(address(aToken), 100_000e6, 0, owner, block.timestamp, 0, bytes32(0), v, r, s);
        assertEq(shares, 99_900e6);
        _assertRouterClean();
    }

    /// @dev Someone submits the signature to USDC first: the router's permit call reverts on the used nonce,
    ///      but the allowance is already set, so the deposit still goes through.
    function test_depositWithPermit_frontRunPermit() public {
        usdc.mint(owner, 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, 1_000e6, block.timestamp);
        vm.prank(bob);
        usdc.permit(owner, address(router), 1_000e6, block.timestamp, v, r, s);

        vm.prank(owner);
        (uint256 shares,) =
            router.depositWithPermit(address(vault), 1_000e6, 0, owner, block.timestamp, 0, bytes32(0), v, r, s);
        assertEq(shares, 997e6);
        _assertRouterClean();
    }

    /// @dev An existing approval also works with a junk signature (same behavior as plain `deposit`).
    function test_depositWithPermit_existingApproval() public {
        _fundAndApprove(owner, 1_000e6);
        vm.prank(owner);
        router.depositWithPermit(
            address(vault), 1_000e6, 0, owner, block.timestamp, 0, bytes32(0), 27, bytes32(0), bytes32(0)
        );
        assertEq(vault.balanceOf(owner), 997e6);
    }

    function test_revert_depositWithPermit_badSignature() public {
        usdc.mint(owner, 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(0xB0B, owner, 1_000e6, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, 1_000e6)
        );
        vm.prank(owner);
        router.depositWithPermit(address(vault), 1_000e6, 0, owner, block.timestamp, 0, bytes32(0), v, r, s);
    }

    /// @dev The permit owner is always msg.sender: a third party can't spend someone else's signature.
    function test_revert_depositWithPermit_callerNotOwner() public {
        usdc.mint(owner, 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, 1_000e6, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, 1_000e6)
        );
        vm.prank(bob);
        router.depositWithPermit(address(vault), 1_000e6, 0, bob, block.timestamp, 0, bytes32(0), v, r, s);
        assertEq(usdc.balanceOf(owner), 1_000e6);
    }

    /// @dev Signature covers a different amount than the deposit.
    function test_revert_depositWithPermit_amountMismatch() public {
        usdc.mint(owner, 2_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, 1_000e6, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, 2_000e6)
        );
        vm.prank(owner);
        router.depositWithPermit(address(vault), 2_000e6, 0, owner, block.timestamp, 0, bytes32(0), v, r, s);
    }

    function test_revert_depositWithPermit_deadline() public {
        usdc.mint(owner, 1_000e6);
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, 1_000e6, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(IRestakeRouter.DeadlineExpired.selector);
        vm.prank(owner);
        router.depositWithPermit(address(vault), 1_000e6, 0, owner, deadline, 0, bytes32(0), v, r, s);
    }

    function test_revert_depositWithPermit_depositsDisabled() public {
        vm.prank(guardian);
        router.disablePoolDeposits(address(vault));
        usdc.mint(owner, 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, 1_000e6, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.DepositsDisabled.selector, address(vault)));
        vm.prank(owner);
        router.depositWithPermit(address(vault), 1_000e6, 0, owner, block.timestamp, 0, bytes32(0), v, r, s);
    }

    function testFuzz_depositWithPermit(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000e6);
        usdc.mint(owner, amount);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, amount, block.timestamp);
        vm.prank(owner);
        router.depositWithPermit(address(vault18), amount, 0, owner, block.timestamp, 0, bytes32(0), v, r, s);
        assertEq(usdc.allowance(owner, address(router)), 0);
        _assertRouterClean();
    }

    function _sign(uint256 key, address holder, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, address(router), value, usdc.nonces(holder), deadline));
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
    }
}
