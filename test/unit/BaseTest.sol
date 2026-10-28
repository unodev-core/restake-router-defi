// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RestakeRouter} from "../../src/RestakeRouter.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626, MockAsyncRedeemVault} from "./mocks/MockVaults.sol";
import {MockAavePool, MockAToken} from "./mocks/MockAave.sol";

abstract contract BaseTest is Test {
    uint256 internal constant USDC_UNIT = 1e6;

    MockERC20 internal usdc;
    MockERC4626 internal vault; // 6-decimal shares (Fluid, YO, Veranta)
    MockERC4626 internal vault18; // 18-decimal shares (Morpho, Sky sUSDC, AUTO)
    MockAsyncRedeemVault internal asyncVault; // YO-style async redeem
    MockAavePool internal aavePool;
    MockAToken internal aToken;
    RestakeRouter internal router;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockERC4626(usdc, 0);
        vault18 = new MockERC4626(usdc, 12);
        asyncVault = new MockAsyncRedeemVault(usdc);
        aavePool = new MockAavePool();
        aToken = new MockAToken(address(usdc), aavePool);
        aavePool.listReserve(address(usdc), address(aToken));

        router = _deployRouter(defaultTiers(), defaultPools());
    }

    // ───────────── Config ─────────────

    /// @dev v1.0 schedule: 0.30% / 0.20% from 10k / 0.10% from 100k.
    function defaultTiers() internal pure returns (IRestakeRouter.FeeTier[] memory tiers) {
        tiers = new IRestakeRouter.FeeTier[](3);
        tiers[0] = IRestakeRouter.FeeTier({minAmount: 0, feeBps: 30});
        tiers[1] = IRestakeRouter.FeeTier({minAmount: 10_000e6, feeBps: 20});
        tiers[2] = IRestakeRouter.FeeTier({minAmount: 100_000e6, feeBps: 10});
    }

    function defaultPools() internal view returns (IRestakeRouter.PoolInit[] memory pools) {
        pools = new IRestakeRouter.PoolInit[](4);
        pools[0] = IRestakeRouter.PoolInit(address(vault), IRestakeRouter.PoolType.ERC4626);
        pools[1] = IRestakeRouter.PoolInit(address(vault18), IRestakeRouter.PoolType.ERC4626);
        pools[2] = IRestakeRouter.PoolInit(address(asyncVault), IRestakeRouter.PoolType.ERC4626);
        pools[3] = IRestakeRouter.PoolInit(address(aToken), IRestakeRouter.PoolType.AAVE_V3);
    }

    function _deployRouter(IRestakeRouter.FeeTier[] memory tiers, IRestakeRouter.PoolInit[] memory pools)
        internal
        returns (RestakeRouter)
    {
        return new RestakeRouter(feeRecipient, guardian, address(usdc), address(aavePool), tiers, pools);
    }

    function _pool(uint256 i) internal view returns (address) {
        return defaultPools()[i].pool;
    }

    // ───────────── Actions ─────────────

    function _fundAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(router), amount);
    }

    function _deposit(address user, address pool, uint256 amount) internal returns (uint256 shares) {
        _fundAndApprove(user, amount);
        vm.prank(user);
        (shares,) = router.deposit(pool, amount, 0, user, block.timestamp, bytes32(0));
    }

    function _approveShares(address user, address pool, uint256 amount) internal {
        vm.prank(user);
        IERC20(pool).approve(address(router), amount);
    }

    /// @dev Raises the Aave liquidity index by `bps` and backs the accrued interest with USDC.
    function _accrueAaveInterest(uint256 bps) internal {
        uint256 supplyBefore = aToken.totalSupply();
        aavePool.setLiquidityIndex(aavePool.liquidityIndex() * (10_000 + bps) / 10_000);
        usdc.mint(address(aToken), aToken.totalSupply() - supplyBefore + 1);
    }

    // ───────────── Assertions ─────────────

    /// @dev Invariants 2 and 5: no balances, no outstanding approvals.
    function _assertRouterClean() internal view {
        address[] memory pools = router.getPools();
        assertEq(usdc.balanceOf(address(router)), 0, "router USDC");
        assertEq(usdc.allowance(address(router), address(aavePool)), 0, "aave allowance");
        for (uint256 i; i < pools.length; ++i) {
            assertEq(IERC20(pools[i]).balanceOf(address(router)), 0, "router shares");
            assertEq(usdc.allowance(address(router), pools[i]), 0, "vault allowance");
        }
    }
}
