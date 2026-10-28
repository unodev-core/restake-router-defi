// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {BaseForkTest} from "./BaseFork.t.sol";

/// @dev `depositWithPermit` against native USDC (FiatToken v2.2, EIP-2612) on a Base fork.
contract DepositWithPermitForkTest is BaseForkTest {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    address internal constant GAS_POOL = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB; // aBasUSDC

    function test_depositWithPermit_allPools() public {
        (address owner, uint256 key) = makeAddrAndKey("permitOwner");
        for (uint256 i; i < cfg.pools.length; ++i) {
            address pool = cfg.pools[i].pool;
            deal(address(usdc), owner, 1_000e6);
            (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, 1_000e6);
            vm.prank(owner);
            (uint256 shares,) =
                router.depositWithPermit(pool, 1_000e6, 1, owner, block.timestamp, bytes32("fork"), v, r, s);
            assertGt(shares, 0);
            assertEq(usdc.allowance(owner, address(router)), 0);
            _assertRouterClean();
        }
    }

    /// @dev Gas of one `depositWithPermit` transaction. Compare with `test_gas_approveThenDeposit`; each test
    ///      runs in its own EVM context, so both start from cold storage.
    function test_gas_depositWithPermit() public {
        (address a, uint256 key) = makeAddrAndKey("gasUser");
        deal(address(usdc), a, 1_000e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, a, 1_000e6);
        vm.prank(a);
        uint256 g = gasleft();
        router.depositWithPermit(GAS_POOL, 1_000e6, 1, a, block.timestamp, 0, v, r, s);
        console2.log("depositWithPermit, 1 tx incl. 21000 base:", g - gasleft() + 21_000);
    }

    function test_gas_approveThenDeposit() public {
        address a = makeAddr("gasUser");
        deal(address(usdc), a, 1_000e6);
        vm.prank(a);
        uint256 g = gasleft();
        usdc.approve(address(router), 1_000e6);
        uint256 approveGas = g - gasleft();
        // The deposit is a separate transaction: start it from cold storage again.
        vm.cool(address(usdc));
        vm.cool(address(router));
        vm.prank(a);
        g = gasleft();
        router.deposit(GAS_POOL, 1_000e6, 1, a, block.timestamp, 0);
        console2.log("approve + deposit, 2 txs incl. 2 x 21000 base:", approveGas + g - gasleft() + 42_000);
    }

    function _sign(uint256 key, address owner, uint256 value) internal view returns (uint8, bytes32, bytes32) {
        IERC20Permit token = IERC20Permit(address(usdc));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(router), value, token.nonces(owner), block.timestamp));
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }
}
