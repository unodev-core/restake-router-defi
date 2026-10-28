// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {RestakeRouter} from "../../src/RestakeRouter.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockVaults.sol";
import {MockAavePool, MockAToken} from "./mocks/MockAave.sol";

contract ConstructorTest is BaseTest {
    function test_config() public view {
        assertEq(router.FEE_RECIPIENT(), feeRecipient);
        assertEq(router.GUARDIAN(), guardian);
        assertEq(router.USDC(), address(usdc));
        assertEq(router.AAVE_POOL(), address(aavePool));
        assertEq(router.MAX_FEE_BPS(), 100);
        assertEq(router.MAX_TIERS(), 5);
        assertFalse(router.allDepositsDisabled());

        IRestakeRouter.PoolInit[] memory expected = defaultPools();
        address[] memory pools = router.getPools();
        assertEq(pools.length, expected.length);
        for (uint256 i; i < pools.length; ++i) {
            assertEq(pools[i], expected[i].pool);
            assertEq(uint8(router.poolType(pools[i])), uint8(expected[i].poolType));
            assertFalse(router.depositsDisabled(pools[i]));
        }
        assertEq(uint8(router.poolType(address(usdc))), uint8(IRestakeRouter.PoolType.NONE));

        IRestakeRouter.FeeTier[] memory tiers = router.getFeeTiers();
        IRestakeRouter.FeeTier[] memory expectedTiers = defaultTiers();
        assertEq(tiers.length, expectedTiers.length);
        for (uint256 i; i < tiers.length; ++i) {
            assertEq(tiers[i].minAmount, expectedTiers[i].minAmount);
            assertEq(tiers[i].feeBps, expectedTiers[i].feeBps);
        }
    }

    function test_emitsConfigEvents() public {
        IRestakeRouter.PoolInit[] memory pools = defaultPools();
        vm.expectEmit(true, true, true, true);
        emit IRestakeRouter.FeeTiersSet(defaultTiers());
        for (uint256 i; i < pools.length; ++i) {
            vm.expectEmit(true, true, true, true);
            emit IRestakeRouter.PoolAdded(pools[i].pool, pools[i].poolType);
        }
        _deployRouter(defaultTiers(), pools);
    }

    function test_noAavePoolNeededWithoutAavePools() public {
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(vault), IRestakeRouter.PoolType.ERC4626);
        RestakeRouter r =
            new RestakeRouter(feeRecipient, guardian, address(usdc), address(0), address(0), defaultTiers(), pools);
        assertEq(r.AAVE_POOL(), address(0));
    }

    // ───────────── Zero addresses ─────────────

    function test_revert_zeroFeeRecipient() public {
        vm.expectRevert(IRestakeRouter.ZeroAddress.selector);
        new RestakeRouter(
            address(0), guardian, address(usdc), address(aavePool), address(0), defaultTiers(), defaultPools()
        );
    }

    function test_revert_zeroGuardian() public {
        vm.expectRevert(IRestakeRouter.ZeroAddress.selector);
        new RestakeRouter(
            feeRecipient, address(0), address(usdc), address(aavePool), address(0), defaultTiers(), defaultPools()
        );
    }

    function test_revert_zeroUsdc() public {
        vm.expectRevert(IRestakeRouter.ZeroAddress.selector);
        new RestakeRouter(
            feeRecipient, guardian, address(0), address(aavePool), address(0), defaultTiers(), defaultPools()
        );
    }

    function test_revert_aavePoolMissingForAavePool() public {
        vm.expectRevert(IRestakeRouter.ZeroAddress.selector);
        new RestakeRouter(feeRecipient, guardian, address(usdc), address(0), address(0), defaultTiers(), defaultPools());
    }

    // ───────────── Fee tiers (full matrix in FeeLib.t.sol) ─────────────

    function test_revert_invalidFeeTiers() public {
        vm.expectRevert(IRestakeRouter.InvalidFeeTiers.selector);
        _deployRouter(new IRestakeRouter.FeeTier[](0), defaultPools());
    }

    function test_revert_feeTooHigh() public {
        IRestakeRouter.FeeTier[] memory tiers = defaultTiers();
        tiers[0].feeBps = 101;
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.FeeTooHigh.selector, uint16(101)));
        _deployRouter(tiers, defaultPools());
    }

    // ───────────── Pools ─────────────

    function test_revert_duplicatePool() public {
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](2);
        pools[0] = IRestakeRouter.PoolInit(address(vault), IRestakeRouter.PoolType.ERC4626);
        pools[1] = IRestakeRouter.PoolInit(address(vault), IRestakeRouter.PoolType.ERC4626);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.DuplicatePool.selector, address(vault)));
        _deployRouter(defaultTiers(), pools);
    }

    function test_revert_poolTypeNone() public {
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(vault), IRestakeRouter.PoolType.NONE);
        vm.expectRevert(IRestakeRouter.InvalidPoolType.selector);
        _deployRouter(defaultTiers(), pools);
    }

    function test_revert_erc4626NotUsdc() public {
        MockERC4626 other = new MockERC4626(new MockERC20("Other", "OTH", 6), 0);
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(other), IRestakeRouter.PoolType.ERC4626);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.AssetMismatch.selector, address(other)));
        _deployRouter(defaultTiers(), pools);
    }

    function test_revert_aTokenNotUsdc() public {
        MockAToken other = new MockAToken(address(new MockERC20("Other", "OTH", 6)), aavePool);
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(other), IRestakeRouter.PoolType.AAVE_V3);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.AssetMismatch.selector, address(other)));
        _deployRouter(defaultTiers(), pools);
    }

    /// @dev An aToken whose underlying is USDC but which isn't the Aave Pool's USDC reserve (e.g. another market).
    function test_revert_aaveReserveMismatch() public {
        MockAToken rogue = new MockAToken(address(usdc), new MockAavePool());
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(rogue), IRestakeRouter.PoolType.AAVE_V3);
        vm.expectRevert(IRestakeRouter.AaveReserveMismatch.selector);
        _deployRouter(defaultTiers(), pools);
    }

    function test_revert_erc4626TypedAsAave() public {
        IRestakeRouter.PoolInit[] memory pools = new IRestakeRouter.PoolInit[](1);
        pools[0] = IRestakeRouter.PoolInit(address(vault), IRestakeRouter.PoolType.AAVE_V3);
        vm.expectRevert(); // vault has no UNDERLYING_ASSET_ADDRESS()
        _deployRouter(defaultTiers(), pools);
    }
}
