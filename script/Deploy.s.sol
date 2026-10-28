// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {RestakeRouter} from "../src/RestakeRouter.sol";
import {IRestakeRouter} from "../src/interfaces/IRestakeRouter.sol";
import {ICreateX} from "../src/interfaces/ICreateX.sol";

/// @notice Deploys RestakeRouter through CreateX `deployCreate3` with a permissioned salt (architecture §10).
/// @dev Usage:
///      forge script script/Deploy.s.sol --rpc-url base --account <deployer> --broadcast --verify
///      CONFIG_PATH overrides the default config file (script/config/constructor-config.v1.json).
contract Deploy is Script {
    struct Config {
        string release;
        address createX;
        string saltLabel;
        bool crossChainRedeployProtection;
        address deployer;
        address expectedRouter;
        address feeRecipient;
        address guardian;
        address usdc;
        address aavePool;
        address cctpTokenMessenger;
        IRestakeRouter.FeeTier[] feeTiers;
        IRestakeRouter.PoolInit[] pools;
        bool[] poolVerified;
    }

    string internal constant DEFAULT_CONFIG_PATH = "script/config/constructor-config.v1.json";

    function run() external returns (address router) {
        string memory path = vm.envOr("CONFIG_PATH", string(DEFAULT_CONFIG_PATH));
        Config memory cfg = loadConfig(vm.readFile(string.concat(vm.projectRoot(), "/", path)), block.chainid);
        checkReady(cfg);
        router = deploy(cfg);

        console2.log("RestakeRouter", cfg.release, "deployed at", router);
    }

    // ───────────── Config ─────────────

    /// @notice Reads the `chains.<name>` entry whose chainId matches `chainId`. Every field is read by key,
    ///         so field order and label fields (`name`, `protocol`, `slug`) don't matter.
    function loadConfig(string memory json, uint256 chainId) public view returns (Config memory cfg) {
        cfg.release = vm.parseJsonString(json, ".release");
        cfg.createX = vm.parseJsonAddress(json, ".deployment.createX");
        cfg.saltLabel = vm.parseJsonString(json, ".deployment.saltLabel");
        cfg.crossChainRedeployProtection = vm.parseJsonBool(json, ".deployment.crossChainRedeployProtection");

        string memory chain = _findChain(json, chainId);
        cfg.deployer = vm.parseJsonAddress(json, string.concat(chain, ".deployer"));
        cfg.expectedRouter = vm.parseJsonAddress(json, string.concat(chain, ".expectedRouter"));

        string memory ctor = string.concat(chain, ".constructor");
        cfg.feeRecipient = vm.parseJsonAddress(json, string.concat(ctor, ".feeRecipient"));
        cfg.guardian = vm.parseJsonAddress(json, string.concat(ctor, ".guardian"));
        cfg.usdc = vm.parseJsonAddress(json, string.concat(ctor, ".usdc"));
        cfg.aavePool = vm.parseJsonAddress(json, string.concat(ctor, ".aavePool"));
        cfg.cctpTokenMessenger = vm.parseJsonAddress(json, string.concat(ctor, ".cctpTokenMessenger"));

        uint256 nTiers = _arrayLength(json, string.concat(ctor, ".feeTiers"));
        cfg.feeTiers = new IRestakeRouter.FeeTier[](nTiers);
        for (uint256 i; i < nTiers; ++i) {
            string memory tier = string.concat(ctor, ".feeTiers[", vm.toString(i), "]");
            cfg.feeTiers[i] = IRestakeRouter.FeeTier({
                minAmount: vm.parseJsonUint(json, string.concat(tier, ".minAmount")),
                feeBps: uint16(vm.parseJsonUint(json, string.concat(tier, ".feeBps")))
            });
        }

        uint256 nPools = _arrayLength(json, string.concat(ctor, ".pools"));
        cfg.pools = new IRestakeRouter.PoolInit[](nPools);
        cfg.poolVerified = new bool[](nPools);
        for (uint256 i; i < nPools; ++i) {
            string memory pool = string.concat(ctor, ".pools[", vm.toString(i), "]");
            cfg.pools[i] = IRestakeRouter.PoolInit({
                pool: vm.parseJsonAddress(json, string.concat(pool, ".pool")),
                poolType: parsePoolType(vm.parseJsonString(json, string.concat(pool, ".poolType")))
            });
            cfg.poolVerified[i] = vm.parseJsonBool(json, string.concat(pool, ".verified"));
        }
    }

    /// @notice Pre-broadcast checks: no zero-address placeholders left and every pool through onboarding (§8).
    function checkReady(Config memory cfg) public pure {
        require(cfg.deployer != address(0), "Deploy: deployer not set");
        require(cfg.expectedRouter != address(0), "Deploy: expectedRouter not set");
        require(cfg.feeRecipient != address(0), "Deploy: feeRecipient not set");
        require(cfg.guardian != address(0), "Deploy: guardian not set");
        for (uint256 i; i < cfg.poolVerified.length; ++i) {
            require(cfg.poolVerified[i], string.concat("Deploy: pool not verified: ", vm.toString(cfg.pools[i].pool)));
        }
    }

    function parsePoolType(string memory name) public pure returns (IRestakeRouter.PoolType) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("ERC4626")) return IRestakeRouter.PoolType.ERC4626;
        if (h == keccak256("AAVE_V3")) return IRestakeRouter.PoolType.AAVE_V3;
        revert(string.concat("Deploy: unknown poolType ", name));
    }

    // ───────────── Salt ─────────────

    /// @notice Salt layout: bytes 0–19 deployer, byte 20 cross-chain redeploy protection flag,
    ///         bytes 21–31 `bytes11(keccak256(saltLabel))`.
    function salt(Config memory cfg) public pure returns (bytes32) {
        return bytes32(
            abi.encodePacked(
                cfg.deployer,
                cfg.crossChainRedeployProtection ? bytes1(0x01) : bytes1(0x00),
                bytes11(keccak256(bytes(cfg.saltLabel)))
            )
        );
    }

    /// @notice Mirrors CreateX `_guard` for a permissioned salt deployed by `cfg.deployer`.
    function guardedSalt(Config memory cfg) public view returns (bytes32) {
        bytes32 raw = salt(cfg);
        if (cfg.crossChainRedeployProtection) return keccak256(abi.encode(cfg.deployer, block.chainid, raw));
        return keccak256(abi.encode(bytes32(uint256(uint160(cfg.deployer))), raw));
    }

    function initCode(Config memory cfg) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(RestakeRouter).creationCode,
            abi.encode(
                cfg.feeRecipient, cfg.guardian, cfg.usdc, cfg.aavePool, cfg.cctpTokenMessenger, cfg.feeTiers, cfg.pools
            )
        );
    }

    // ───────────── Deploy ─────────────

    /// @notice Checks the predicted address and deploys, broadcasting as `cfg.deployer` (CreateX guards the salt
    ///         with msg.sender). Fails unless the wallet passed to forge (--account / --private-key) is the deployer.
    function deploy(Config memory cfg) public returns (address router) {
        ICreateX createX = ICreateX(cfg.createX);
        address predicted = createX.computeCreate3Address(guardedSalt(cfg));
        require(predicted == cfg.expectedRouter, "Deploy: predicted address != expectedRouter");

        vm.startBroadcast(cfg.deployer);
        router = createX.deployCreate3(salt(cfg), initCode(cfg));
        vm.stopBroadcast();
        require(router == predicted, "Deploy: deployed address != predicted");
    }

    // ───────────── Helpers ─────────────

    function _findChain(string memory json, uint256 chainId) internal pure returns (string memory) {
        string[] memory names = vm.parseJsonKeys(json, ".chains");
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(".chains.", names[i]);
            if (vm.parseJsonUint(json, string.concat(key, ".chainId")) == chainId) return key;
        }
        revert(string.concat("Deploy: no config for chainId ", vm.toString(chainId)));
    }

    function _arrayLength(string memory json, string memory key) internal view returns (uint256 n) {
        for (; vm.keyExistsJson(json, string.concat(key, "[", vm.toString(n), "]")); ++n) {}
    }
}
