// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {RestakeRouter} from "../../src/RestakeRouter.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {ICreateX} from "../../src/interfaces/ICreateX.sol";

interface INonViewPreviewRedeem {
    function previewRedeem(uint256 shares) external returns (uint256);
}

/// @dev Base mainnet fork. Deploys the router from the real v1 config through CreateX, with test addresses in
///      place of the zero-address placeholders. Skipped unless BASE_RPC_URL is set.
///      BASE_FORK_BLOCK overrides the pinned block (0 = latest).
abstract contract BaseForkTest is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 53_190_000;

    Deploy internal script;
    Deploy.Config internal cfg;
    RestakeRouter internal router;
    IERC20 internal usdc;

    address internal deployer = makeAddr("deployer");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");

    function setUp() public virtual {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
            return;
        }
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        script = new Deploy();
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/config/constructor-config.v1.json"));
        Deploy.Config memory c = script.loadConfig(json, block.chainid);
        c.deployer = deployer;
        c.feeRecipient = feeRecipient;
        c.guardian = guardian;
        c.expectedRouter = ICreateX(c.createX).computeCreate3Address(script.guardedSalt(c));
        for (uint256 i; i < c.poolVerified.length; ++i) {
            c.poolVerified[i] = true;
        }
        script.checkReady(c);
        _storeConfig(c);

        router = RestakeRouter(script.deploy(c));
        usdc = IERC20(c.usdc);
    }

    /// @dev Memory -> storage copy of the nested struct arrays (not supported by a plain assignment).
    function _storeConfig(Deploy.Config memory c) internal {
        cfg.release = c.release;
        cfg.createX = c.createX;
        cfg.saltLabel = c.saltLabel;
        cfg.crossChainRedeployProtection = c.crossChainRedeployProtection;
        cfg.deployer = c.deployer;
        cfg.expectedRouter = c.expectedRouter;
        cfg.feeRecipient = c.feeRecipient;
        cfg.guardian = c.guardian;
        cfg.usdc = c.usdc;
        cfg.aavePool = c.aavePool;
        for (uint256 i; i < c.feeTiers.length; ++i) {
            cfg.feeTiers.push(c.feeTiers[i]);
        }
        for (uint256 i; i < c.pools.length; ++i) {
            cfg.pools.push(c.pools[i]);
            cfg.poolVerified.push(c.poolVerified[i]);
        }
    }

    function _config() internal view returns (Deploy.Config memory) {
        return cfg;
    }

    // ───────────── Helpers ─────────────

    function _depositAs(address user, address pool, uint256 amount) internal returns (uint256 shares, uint256 fee) {
        deal(address(usdc), user, amount);
        (,,, uint256 expected) = router.previewDeposit(pool, amount);
        vm.startPrank(user);
        usdc.approve(address(router), amount);
        (shares, fee) = router.deposit(pool, amount, expected * 9_990 / 10_000, user, block.timestamp, bytes32("fork"));
        vm.stopPrank();
    }

    function _withdrawAs(address user, address pool, uint256 shares) internal returns (uint256 assets) {
        uint256 amount = shares == type(uint256).max ? IERC20(pool).balanceOf(user) : shares;
        uint256 expected = _quoteWithdraw(pool, amount);
        vm.startPrank(user);
        IERC20(pool).approve(address(router), type(uint256).max);
        // AUTO Autopools can return less than previewRedeem when unwinding (§8): 1% tolerance.
        assets = router.withdraw(pool, shares, _max(expected * 99 / 100, 1), user, block.timestamp);
        vm.stopPrank();
    }

    /// @dev AUTO's Autopool `previewRedeem` simulates the redeem with a state-changing self-call, so it reverts
    ///      under STATICCALL (i.e. via the router's view `previewWithdraw`). Quote ERC-4626 pools with a plain
    ///      CALL to the vault instead, which is what the frontend's eth_call does.
    function _quoteWithdraw(address pool, uint256 shares) internal returns (uint256) {
        if (router.poolType(pool) == IRestakeRouter.PoolType.AAVE_V3) return router.previewWithdraw(pool, shares);
        return INonViewPreviewRedeem(pool).previewRedeem(shares);
    }

    function _assertRouterClean() internal view {
        assertEq(usdc.balanceOf(address(router)), 0, "router USDC");
        assertEq(usdc.allowance(address(router), cfg.aavePool), 0, "aave allowance");
        for (uint256 i; i < cfg.pools.length; ++i) {
            assertEq(IERC20(cfg.pools[i].pool).balanceOf(address(router)), 0, "router shares");
            assertEq(usdc.allowance(address(router), cfg.pools[i].pool), 0, "vault allowance");
        }
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
