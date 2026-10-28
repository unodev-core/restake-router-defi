// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseTest} from "../unit/BaseTest.sol";
import {RestakeRouter} from "../../src/RestakeRouter.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {MockERC20} from "../unit/mocks/MockERC20.sol";
import {MockAavePool, MockAToken} from "../unit/mocks/MockAave.sol";

/// @dev Drives random deposit / withdraw / interest / guardian sequences against the router. Every action is
///      bounded so it can't revert for input reasons, so `fail_on_revert` catches real failures.
contract RouterHandler is Test {
    RestakeRouter internal immutable router;
    MockERC20 internal immutable usdc;
    MockAavePool internal immutable aavePool;
    MockAToken internal immutable aToken;
    address internal immutable guardian;
    address[] internal pools;
    address[] internal actors;

    uint256 public ghostGross;
    uint256 public ghostFees;
    uint256 public ghostMaxFees;
    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;

    constructor(RestakeRouter router_, MockAToken aToken_, address guardian_) {
        router = router_;
        usdc = MockERC20(router_.USDC());
        aavePool = MockAavePool(router_.AAVE_POOL());
        aToken = aToken_;
        guardian = guardian_;
        pools = router_.getPools();
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function deposit(uint256 actorSeed, uint256 poolSeed, uint256 amount, uint256 receiverSeed, bytes32 referral)
        external
    {
        address pool = pools[poolSeed % pools.length];
        if (router.allDepositsDisabled() || router.depositsDisabled(pool)) return;
        address actor = actors[actorSeed % actors.length];
        address receiver = actors[receiverSeed % actors.length];
        amount = bound(amount, 1, 1_000_000e6);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(router), type(uint256).max);
        (, uint256 fee) = router.deposit(pool, amount, 0, receiver, block.timestamp, referral);
        vm.stopPrank();

        ghostGross += amount;
        ghostFees += fee;
        ghostMaxFees += amount * router.MAX_FEE_BPS() / 10_000;
        ++ghostDeposits;
    }

    function withdraw(uint256 actorSeed, uint256 poolSeed, uint256 fractionBps, uint256 receiverSeed) external {
        address pool = pools[poolSeed % pools.length];
        address actor = actors[actorSeed % actors.length];
        address receiver = actors[receiverSeed % actors.length];
        uint256 balance = IERC20(pool).balanceOf(actor);
        fractionBps = bound(fractionBps, 1, 10_000);
        uint256 shares = fractionBps == 10_000 ? type(uint256).max : balance * fractionBps / 10_000;
        if (
            balance == 0 || shares == 0
                || router.previewWithdraw(pool, shares == type(uint256).max ? balance : shares) == 0
        ) {
            return;
        }
        // Mock aTokens burn rayDiv(amount): skip tiny partials that would round to zero scaled.
        if (pool == address(aToken) && shares < 2) return;

        vm.startPrank(actor);
        IERC20(pool).approve(address(router), type(uint256).max);
        router.withdraw(pool, shares, 1, receiver, block.timestamp);
        vm.stopPrank();
        ++ghostWithdrawals;
    }

    /// @dev Aave interest (rebasing aTokens) and ERC-4626 yield (direct donation to the vault).
    function accrue(uint256 poolSeed, uint256 bps) external {
        bps = bound(bps, 1, 200);
        address pool = pools[poolSeed % pools.length];
        if (pool == address(aToken)) {
            uint256 supplyBefore = aToken.totalSupply();
            aavePool.setLiquidityIndex(aavePool.liquidityIndex() * (10_000 + bps) / 10_000);
            usdc.mint(address(aToken), aToken.totalSupply() - supplyBefore + 1);
        } else {
            usdc.mint(pool, IERC4626(pool).totalAssets() * bps / 10_000);
        }
    }

    function disablePool(uint256 poolSeed, uint256 chance) external {
        if (chance % 20 != 0) return; // rare
        vm.prank(guardian);
        router.disablePoolDeposits(pools[poolSeed % pools.length]);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 7 days));
    }
}

contract RouterInvariantTest is BaseTest {
    RouterHandler internal handler;
    bytes32 internal tiersHash;
    bytes32 internal poolsHash;

    function setUp() public override {
        super.setUp();
        handler = new RouterHandler(router, aToken, guardian);
        tiersHash = keccak256(abi.encode(router.getFeeTiers()));
        poolsHash = _poolsHash();

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RouterHandler.deposit.selector;
        selectors[1] = RouterHandler.withdraw.selector;
        selectors[2] = RouterHandler.accrue.selector;
        selectors[3] = RouterHandler.disablePool.selector;
        selectors[4] = RouterHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Invariants 2 and 5: zero balances and zero allowances after every call.
    function invariant_routerHoldsNothing() public view {
        _assertRouterClean();
        assertEq(aToken.scaledBalanceOf(address(router)), 0);
    }

    /// @dev Invariant 3: every fee went to FEE_RECIPIENT, within the cap.
    function invariant_feeBounds() public view {
        assertEq(usdc.balanceOf(feeRecipient), handler.ghostFees());
        assertLe(handler.ghostFees(), handler.ghostMaxFees());
    }

    /// @dev Invariant 6: pool list and fee tiers never change.
    function invariant_configImmutable() public view {
        assertEq(keccak256(abi.encode(router.getFeeTiers())), tiersHash);
        assertEq(_poolsHash(), poolsHash);
    }

    function _poolsHash() internal view returns (bytes32) {
        address[] memory pools = router.getPools();
        uint8[] memory types = new uint8[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            types[i] = uint8(router.poolType(pools[i]));
        }
        return keccak256(abi.encode(pools, types));
    }
}
