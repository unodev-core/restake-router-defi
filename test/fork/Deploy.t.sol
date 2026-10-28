// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseForkTest} from "./BaseFork.t.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {RestakeRouter} from "../../src/RestakeRouter.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {ICreateX} from "../../src/interfaces/ICreateX.sol";

/// @dev Real CreateX deployment on a Base fork, from the committed v1 config.
contract DeployForkTest is BaseForkTest {
    function test_deployedAtPredictedAddress() public view {
        assertEq(address(router), cfg.expectedRouter);
        assertGt(address(router).code.length, 0);
    }

    function test_configMatchesJson() public view {
        assertEq(router.FEE_RECIPIENT(), feeRecipient);
        assertEq(router.GUARDIAN(), guardian);
        assertEq(router.USDC(), cfg.usdc);
        assertEq(router.AAVE_POOL(), cfg.aavePool);

        address[] memory pools = router.getPools();
        assertEq(pools.length, cfg.pools.length);
        for (uint256 i; i < pools.length; ++i) {
            assertEq(pools[i], cfg.pools[i].pool);
            assertEq(uint8(router.poolType(pools[i])), uint8(cfg.pools[i].poolType));
        }
        IRestakeRouter.FeeTier[] memory tiers = router.getFeeTiers();
        assertEq(tiers.length, cfg.feeTiers.length);
        for (uint256 i; i < tiers.length; ++i) {
            assertEq(tiers[i].minAmount, cfg.feeTiers[i].minAmount);
            assertEq(tiers[i].feeBps, cfg.feeTiers[i].feeBps);
        }
    }

    /// @dev The address depends only on deployer + salt, not on constructor args (§10).
    function test_addressIndependentOfConstructorArgs() public {
        Deploy.Config memory c = _config();
        c.saltLabel = "restake.router.test-args";
        c.expectedRouter = ICreateX(c.createX).computeCreate3Address(script.guardedSalt(c));
        address predicted = c.expectedRouter;

        c.feeTiers[0].feeBps = 0; // different initCode, same salt
        assertEq(script.deploy(c), predicted);
    }

    /// @dev Someone else submitting our raw salt lands at a different address, so the release address stays ours.
    function test_otherDeployerCantUseSalt() public {
        Deploy.Config memory c = _config();
        c.saltLabel = "restake.router.test-squat";
        c.expectedRouter = ICreateX(c.createX).computeCreate3Address(script.guardedSalt(c));

        vm.prank(makeAddr("attacker"));
        address squatted = ICreateX(c.createX).deployCreate3(script.salt(c), script.initCode(c));
        assertTrue(squatted != c.expectedRouter);

        assertEq(script.deploy(c), c.expectedRouter);
    }

    function test_revert_expectedRouterMismatch() public {
        Deploy.Config memory c = _config();
        c.saltLabel = "restake.router.test-mismatch";
        vm.expectRevert(bytes("Deploy: predicted address != expectedRouter"));
        script.deploy(c);
    }

    /// @dev Same release, same deployer -> same address regardless of chain.
    function test_sameAddressOnAnotherChainId() public {
        Deploy.Config memory c = _config();
        vm.chainId(42_161);
        assertEq(ICreateX(c.createX).computeCreate3Address(script.guardedSalt(c)), address(router));
    }
}
