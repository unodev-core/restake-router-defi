// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";

/// @dev Offline checks of the deploy script's config parsing and salt layout. The real CreateX deployment is
///      exercised in test/fork/Deploy.t.sol.
contract DeployScriptTest is Test {
    Deploy internal script = new Deploy();
    string internal json;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/script/config/constructor-config.v1.json"));
    }

    function test_loadConfig_base() public view {
        Deploy.Config memory cfg = script.loadConfig(json, 8453);
        assertEq(cfg.release, "v1.0");
        assertEq(cfg.createX, 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
        assertEq(cfg.saltLabel, "restake.router.v1.0");
        assertFalse(cfg.crossChainRedeployProtection);
        assertEq(cfg.usdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(cfg.aavePool, 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5);
        assertEq(cfg.cctpTokenMessenger, 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d); // TokenMessengerV2

        assertEq(cfg.feeTiers.length, 3);
        assertEq(cfg.feeTiers[0].minAmount, 0);
        assertEq(cfg.feeTiers[0].feeBps, 30);
        assertEq(cfg.feeTiers[1].minAmount, 10_000e6);
        assertEq(cfg.feeTiers[1].feeBps, 20);
        assertEq(cfg.feeTiers[2].minAmount, 100_000e6);
        assertEq(cfg.feeTiers[2].feeBps, 10);

        assertEq(cfg.pools.length, 14);
        assertEq(cfg.pools[0].pool, 0x3128a0F7f0ea68E7B7c9B00AFa7E41045828e858); // Sky sUSDC
        assertEq(cfg.pools[10].pool, 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB); // aBasUSDC
        uint256 aave;
        for (uint256 i; i < cfg.pools.length; ++i) {
            if (cfg.pools[i].poolType == IRestakeRouter.PoolType.AAVE_V3) ++aave;
            else assertEq(uint8(cfg.pools[i].poolType), uint8(IRestakeRouter.PoolType.ERC4626));
        }
        assertEq(aave, 1);
    }

    /// @dev The test config must rehearse production's protocol config (USDC, Aave, CCTP, fee tiers, pools) under
    ///      its own salt: a test deploy must never claim the production router address, which is immutable once
    ///      taken. The operator addresses (deployer, fee recipient, guardian) may differ.
    function test_testConfig_mirrorsProductionWithOwnSalt() public {
        string memory testJson =
            vm.readFile(string.concat(vm.projectRoot(), "/script/config/constructor-config.v1-test.json"));
        Deploy.Config memory prod = script.loadConfig(json, 8453);
        Deploy.Config memory test = script.loadConfig(testJson, 8453);

        assertEq(test.release, "v1.0-test");
        assertEq(test.saltLabel, "restake.router.v1.0-test.2");
        test.deployer = prod.deployer = makeAddr("deployer");
        assertNotEq(script.salt(test), script.salt(prod), "test salt must differ from production");

        assertEq(test.createX, prod.createX);
        assertEq(test.crossChainRedeployProtection, prod.crossChainRedeployProtection);
        (test.feeRecipient, test.guardian) = (prod.feeRecipient, prod.guardian);
        assertEq(script.initCode(test), script.initCode(prod), "constructor args must match production");
    }

    function test_revert_unknownChain() public {
        vm.expectRevert(bytes("Deploy: no config for chainId 1"));
        script.loadConfig(json, 1);
    }

    /// @dev The committed config still has zero-address placeholders and unverified pools, so it must not deploy.
    function test_checkReady_rejectsPlaceholders() public {
        Deploy.Config memory cfg = script.loadConfig(json, 8453);
        vm.expectRevert(bytes("Deploy: deployer not set"));
        script.checkReady(cfg);

        cfg.deployer = address(1);
        cfg.expectedRouter = address(2);
        cfg.feeRecipient = address(3);
        cfg.guardian = address(4);
        vm.expectRevert(bytes(string.concat("Deploy: pool not verified: ", vm.toString(cfg.pools[0].pool))));
        script.checkReady(cfg);

        for (uint256 i; i < cfg.poolVerified.length; ++i) {
            cfg.poolVerified[i] = true;
        }
        script.checkReady(cfg);
    }

    function test_parsePoolType() public {
        assertEq(uint8(script.parsePoolType("ERC4626")), uint8(IRestakeRouter.PoolType.ERC4626));
        assertEq(uint8(script.parsePoolType("AAVE_V3")), uint8(IRestakeRouter.PoolType.AAVE_V3));
        vm.expectRevert(bytes("Deploy: unknown poolType NONE"));
        script.parsePoolType("NONE");
    }

    function test_saltLayout() public view {
        Deploy.Config memory cfg = script.loadConfig(json, 8453);
        cfg.deployer = 0x1111111111111111111111111111111111111111;
        bytes32 salt = script.salt(cfg);

        assertEq(address(bytes20(salt)), cfg.deployer, "bytes 0-19: deployer");
        assertEq(uint8(salt[20]), 0, "byte 20: no cross-chain redeploy protection");
        assertEq(bytes11(salt << 168), bytes11(keccak256("restake.router.v1.0")), "bytes 21-31: label hash");

        cfg.crossChainRedeployProtection = true;
        assertEq(uint8(script.salt(cfg)[20]), 1);
    }

    function testFuzz_guardedSalt_isChainIndependent(uint64 chainA, uint64 chainB) public {
        Deploy.Config memory cfg = script.loadConfig(json, 8453);
        cfg.deployer = makeAddr("deployer");
        vm.chainId(chainA);
        bytes32 a = script.guardedSalt(cfg);
        vm.chainId(chainB);
        assertEq(script.guardedSalt(cfg), a);
    }
}
