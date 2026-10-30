// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {BaseForkTest} from "./BaseFork.t.sol";

/// @dev `withdrawWithPermit` against every pool's share token on a Base fork. yoUSD and avUSDC have no EIP-2612
///      permit: for them the router ignores the failed permit and falls back to a regular approval.
contract WithdrawWithPermitForkTest is BaseForkTest {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    address internal constant AV_USDC = 0x944766f715b51967E56aFdE5f0Aa76cEaCc9E7f9;

    function test_withdrawWithPermit_allPools() public {
        (address owner, uint256 key) = makeAddrAndKey("permitOwner");
        for (uint256 i; i < cfg.pools.length; ++i) {
            address pool = cfg.pools[i].pool;
            _depositAs(owner, pool, 1_000e6);
            uint256 minAssets = _max(_quoteWithdraw(pool, IERC20(pool).balanceOf(owner)) * 99 / 100, 1);

            bool hasPermit = pool != YO_USD && pool != AV_USDC;
            uint8 v = 27;
            bytes32 r;
            bytes32 s;
            if (hasPermit) {
                (v, r, s) = _sign(pool, key, owner, type(uint256).max);
            } else {
                vm.prank(owner);
                IERC20(pool).approve(address(router), type(uint256).max);
            }

            vm.prank(owner);
            uint256 assets =
                router.withdrawWithPermit(pool, type(uint256).max, minAssets, owner, block.timestamp, 0, v, r, s);
            assertGe(assets, minAssets);
            assertEq(IERC20(pool).balanceOf(owner), 0, "full exit");
            if (hasPermit) assertEq(IERC20Permit(pool).nonces(owner), 1, "permit applied");
            _assertRouterClean();
            deal(address(usdc), owner, 0);
        }
    }

    /// @dev Without a permit and without an approval, the pull reverts.
    function test_revert_withdrawWithPermit_noPermitToken_noApproval() public {
        (address owner,) = makeAddrAndKey("permitOwner");
        _depositAs(owner, YO_USD, 1_000e6);
        vm.expectRevert();
        vm.prank(owner);
        router.withdrawWithPermit(YO_USD, type(uint256).max, 1, owner, block.timestamp, 0, 27, bytes32(0), bytes32(0));
    }

    function _sign(address token, uint256 key, address owner, uint256 value)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        IERC20Permit t = IERC20Permit(token);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(router), value, t.nonces(owner), block.timestamp));
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), structHash)));
    }
}
