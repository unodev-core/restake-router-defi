// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RestakeRouter} from "../../src/RestakeRouter.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626, MockAsyncRedeemVault} from "./mocks/MockVaults.sol";
import {MockAavePool, MockAToken} from "./mocks/MockAave.sol";
import {MockMessageTransmitterV2, MockTokenMessengerV2} from "./mocks/MockCctp.sol";

abstract contract BaseTest is Test {
    uint256 internal constant USDC_UNIT = 1e6;
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant ARBITRUM_DOMAIN = 3;

    MockERC20 internal usdc;
    MockERC4626 internal vault; // 6-decimal shares (Fluid, YO, Veranta)
    MockERC4626 internal vault18; // 18-decimal shares (Morpho, Sky sUSDC, AUTO)
    MockAsyncRedeemVault internal asyncVault; // YO-style async redeem
    MockAavePool internal aavePool;
    MockAToken internal aToken;
    MockMessageTransmitterV2 internal transmitter;
    MockTokenMessengerV2 internal tokenMessenger;
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
        transmitter = new MockMessageTransmitterV2(BASE_DOMAIN);
        tokenMessenger = new MockTokenMessengerV2(usdc, address(transmitter));

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
        return new RestakeRouter(
            feeRecipient, guardian, address(usdc), address(aavePool), address(tokenMessenger), tiers, pools
        );
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

    // ───────────── CCTP ─────────────

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _hook(address pool, uint256 minShares, address receiver, uint256 deadline, bytes32 referralCode)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(IRestakeRouter.CctpDepositHook(pool, minShares, receiver, deadline, referralCode));
    }

    /// @dev MessageV2 carrying a BurnMessageV2 of USDC from Arbitrum to the router on Base, relayable only
    ///      by the router.
    function _cctpMessage(bytes32 nonce, address messageSender, uint256 amount, uint256 feeExecuted, bytes memory hook)
        internal
        view
        returns (bytes memory)
    {
        return _cctpMessageTo(nonce, address(tokenMessenger), address(router), messageSender, amount, feeExecuted, hook);
    }

    function _cctpMessageTo(
        bytes32 nonce,
        address recipient,
        address mintRecipient,
        address messageSender,
        uint256 amount,
        uint256 feeExecuted,
        bytes memory hook
    ) internal view returns (bytes memory) {
        bytes memory body = abi.encodePacked(
            uint32(1),
            _toBytes32(address(usdc)),
            _toBytes32(mintRecipient),
            amount,
            _toBytes32(messageSender),
            feeExecuted, // maxFee
            feeExecuted,
            uint256(0), // expirationBlock
            hook
        );
        return abi.encodePacked(
            uint32(1),
            ARBITRUM_DOMAIN,
            BASE_DOMAIN,
            nonce,
            bytes32(uint256(0xA4B)), // remote TokenMessenger
            _toBytes32(recipient),
            _toBytes32(address(router)), // destinationCaller
            uint32(1000),
            uint32(feeExecuted == 0 ? 2000 : 1000),
            body
        );
    }

    // ───────────── Assertions ─────────────

    /// @dev Invariants 2 and 5: no balances, no outstanding approvals.
    function _assertRouterClean() internal view {
        address[] memory pools = router.getPools();
        assertEq(usdc.balanceOf(address(router)), 0, "router USDC");
        assertEq(usdc.allowance(address(router), address(aavePool)), 0, "aave allowance");
        assertEq(usdc.allowance(address(router), address(tokenMessenger)), 0, "cctp allowance");
        for (uint256 i; i < pools.length; ++i) {
            assertEq(IERC20(pools[i]).balanceOf(address(router)), 0, "router shares");
            assertEq(usdc.allowance(address(router), pools[i]), 0, "vault allowance");
        }
    }
}
