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
    uint256 internal _nonce;

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
        (, uint256 fee) = router.deposit(pool, amount, 0, receiver, block.timestamp, referral, bytes32(0));
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
        router.withdraw(pool, shares, 1, receiver, block.timestamp, bytes32(0));
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

    /// @dev CCTP inbound: a burn on Arbitrum minting `amount - cctpFee` to the router, relayed with a deposit hook.
    function bridgeDeposit(uint256 poolSeed, uint256 amount, uint256 cctpFee, uint256 receiverSeed) external {
        address pool = pools[poolSeed % pools.length];
        if (router.allDepositsDisabled() || router.depositsDisabled(pool)) return;
        address receiver = actors[receiverSeed % actors.length];
        amount = bound(amount, 2, 1_000_000e6);
        cctpFee = bound(cctpFee, 0, (amount - 1) / 1000);

        bytes memory hook =
            abi.encode(IRestakeRouter.CctpDepositHook(pool, 0, receiver, block.timestamp, 0, bytes32(0)));
        (, uint256 fee) = router.receiveAndDeposit(_message(amount, cctpFee, hook), "");

        uint256 minted = amount - cctpFee;
        ghostGross += minted;
        ghostFees += fee;
        ghostMaxFees += minted * router.MAX_FEE_BPS() / 10_000;
        ++ghostDeposits;
    }

    /// @dev CCTP outbound: withdraw and burn to the actor's address on Arbitrum.
    function withdrawAndBridge(uint256 actorSeed, uint256 poolSeed, uint256 fractionBps) external {
        address pool = pools[poolSeed % pools.length];
        address actor = actors[actorSeed % actors.length];
        uint256 balance = IERC20(pool).balanceOf(actor);
        fractionBps = bound(fractionBps, 1, 10_000);
        uint256 shares = fractionBps == 10_000 ? type(uint256).max : balance * fractionBps / 10_000;
        if (
            balance == 0 || shares == 0
                || router.previewWithdraw(pool, shares == type(uint256).max ? balance : shares) == 0
        ) {
            return;
        }
        if (pool == address(aToken) && shares < 2) return;

        IRestakeRouter.CctpBridge memory bridge = IRestakeRouter.CctpBridge({
            destinationDomain: 3, mintRecipient: bytes32(uint256(uint160(actor))), maxFee: 0, minFinalityThreshold: 2000
        });
        vm.startPrank(actor);
        IERC20(pool).approve(address(router), type(uint256).max);
        router.withdrawAndBridge(pool, shares, 1, block.timestamp, bytes32(0), bridge);
        vm.stopPrank();
        ++ghostWithdrawals;
    }

    function _message(uint256 amount, uint256 cctpFee, bytes memory hook) internal returns (bytes memory) {
        bytes memory body = abi.encodePacked(
            uint32(1),
            bytes32(uint256(uint160(address(usdc)))),
            bytes32(uint256(uint160(address(router)))),
            amount,
            bytes32(uint256(0xA4B)),
            cctpFee,
            cctpFee,
            uint256(0),
            hook
        );
        return abi.encodePacked(
            uint32(1),
            uint32(3),
            router.CCTP_LOCAL_DOMAIN(),
            bytes32(++_nonce),
            bytes32(uint256(0xA4B)),
            bytes32(uint256(uint160(router.CCTP_TOKEN_MESSENGER()))),
            bytes32(uint256(uint160(address(router)))),
            uint32(1000),
            uint32(2000),
            body
        );
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

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RouterHandler.deposit.selector;
        selectors[1] = RouterHandler.withdraw.selector;
        selectors[2] = RouterHandler.accrue.selector;
        selectors[3] = RouterHandler.disablePool.selector;
        selectors[4] = RouterHandler.warp.selector;
        selectors[5] = RouterHandler.bridgeDeposit.selector;
        selectors[6] = RouterHandler.withdrawAndBridge.selector;
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
