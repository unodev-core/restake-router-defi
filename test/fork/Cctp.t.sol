// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseForkTest} from "./BaseFork.t.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";

/// @dev CCTP V2 against Circle's live contracts on a Base fork. Inbound relays need a real Circle attestation,
///      so `receiveAndDeposit` is covered by the mock-based unit tests only.
contract CctpForkTest is BaseForkTest {
    address internal constant MESSAGE_TRANSMITTER_V2 = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant ARBITRUM_DOMAIN = 3;

    function test_cctpConfig() public view {
        assertEq(router.CCTP_TOKEN_MESSENGER(), cfg.cctpTokenMessenger);
        assertEq(router.CCTP_MESSAGE_TRANSMITTER(), MESSAGE_TRANSMITTER_V2);
        assertEq(router.CCTP_LOCAL_DOMAIN(), BASE_DOMAIN);
    }

    /// @dev Every pool: deposit on Base, then withdraw and burn to Arbitrum through the real TokenMessengerV2.
    function test_withdrawAndBridge_allPools() public {
        IRestakeRouter.CctpBridge memory bridge = IRestakeRouter.CctpBridge({
            destinationDomain: ARBITRUM_DOMAIN,
            mintRecipient: bytes32(uint256(uint160(alice))),
            maxFee: 0,
            minFinalityThreshold: 2000
        });
        uint256 supplyBefore = usdc.totalSupply();
        uint256 burned;
        for (uint256 i; i < cfg.pools.length; ++i) {
            address pool = cfg.pools[i].pool;
            (uint256 shares,) = _depositAs(alice, pool, 1_000e6);
            uint256 expected = _quoteWithdraw(pool, shares);

            vm.startPrank(alice);
            _approve(pool);
            burned += router.withdrawAndBridge(
                pool, type(uint256).max, _max(expected * 99 / 100, 1), block.timestamp, bridge
            );
            vm.stopPrank();
            _assertRouterClean();
        }
        assertEq(usdc.balanceOf(alice), 0, "nothing paid out on Base");
        assertGt(burned, 0);
        // `deal` doesn't touch totalSupply, so the drop is exactly what CCTP burned.
        assertEq(usdc.totalSupply(), supplyBefore - burned);
    }

    function _approve(address pool) internal {
        (bool ok,) = pool.call(abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max));
        require(ok);
    }
}
