// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.sol";
import {RestakeRouter} from "../../src/RestakeRouter.sol";
import {IRestakeRouter} from "../../src/interfaces/IRestakeRouter.sol";
import {MockFakeRecipient} from "./mocks/MockCctp.sol";

contract CctpTest is BaseTest {
    address internal omnibus = makeAddr("omnibus"); // partner omnibus: burner on Arbitrum, share owner on Base
    address internal relayer = makeAddr("relayer");
    bytes32 internal constant REF = "partner-x";

    // ───────────── Config ─────────────

    function test_config() public view {
        assertEq(router.CCTP_TOKEN_MESSENGER(), address(tokenMessenger));
        assertEq(router.CCTP_MESSAGE_TRANSMITTER(), address(transmitter));
        assertEq(router.CCTP_LOCAL_DOMAIN(), BASE_DOMAIN);
    }

    function test_revert_disabledWithoutMessenger() public {
        RestakeRouter r = new RestakeRouter(
            feeRecipient, guardian, address(usdc), address(aavePool), address(0), defaultTiers(), defaultPools()
        );
        assertEq(r.CCTP_MESSAGE_TRANSMITTER(), address(0));
        assertEq(r.CCTP_LOCAL_DOMAIN(), 0);

        vm.expectRevert(IRestakeRouter.CctpNotSupported.selector);
        r.receiveAndDeposit("", "");
        vm.expectRevert(IRestakeRouter.CctpNotSupported.selector);
        r.receiveAndRefund("", "");
        vm.expectRevert(IRestakeRouter.CctpNotSupported.selector);
        r.withdrawAndBridge(address(vault), 1, 1, block.timestamp, _bridge(omnibus, 0));
    }

    // ───────────── Inbound: receiveAndDeposit ─────────────

    function test_receiveAndDeposit_vault() public {
        bytes memory message =
            _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, block.timestamp, REF));

        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.CctpReceived("n1", ARBITRUM_DOMAIN, _toBytes32(omnibus), 1_000e6);
        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Deposit(
            relayer, omnibus, address(vault), address(usdc), 1_000e6, 3e6, 997e6, 997e6, 0, 30, REF
        );
        vm.prank(relayer);
        (uint256 shares, uint256 fee) = router.receiveAndDeposit(message, "");

        assertEq(shares, 997e6);
        assertEq(fee, 3e6);
        assertEq(vault.balanceOf(omnibus), 997e6);
        assertEq(usdc.balanceOf(feeRecipient), 3e6);
        assertTrue(transmitter.usedNonces("n1"));
        _assertRouterClean();
    }

    function test_receiveAndDeposit_aave() public {
        bytes memory message =
            _cctpMessage("n1", omnibus, 50_000e6, 0, _hook(address(aToken), 49_900e6, omnibus, block.timestamp, 0));
        (uint256 shares, uint256 fee) = router.receiveAndDeposit(message, "");
        assertEq(fee, 100e6); // tier 1: 0.20%
        assertEq(shares, 49_900e6);
        assertEq(aToken.balanceOf(omnibus), 49_900e6);
        _assertRouterClean();
    }

    /// @dev Fast transfer: the router fee is sized on what CCTP actually minted, not the burned amount.
    function test_receiveAndDeposit_fastTransferFee() public {
        bytes memory message =
            _cctpMessage("n1", omnibus, 10_000e6, 1e6, _hook(address(vault), 0, omnibus, block.timestamp, 0));
        (uint256 shares, uint256 fee) = router.receiveAndDeposit(message, "");
        assertEq(fee, 29_997_000); // 9 999 USDC → tier 0 (0.30%)
        assertEq(shares, 9_999e6 - fee);
        assertEq(usdc.balanceOf(tokenMessenger.feeRecipient()), 1e6);
        _assertRouterClean();
    }

    function test_revert_receiveAndDeposit_replay() public {
        bytes memory message = _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, 1e18, 0));
        router.receiveAndDeposit(message, "");
        vm.expectRevert("Nonce already used");
        router.receiveAndDeposit(message, "");
    }

    /// @dev A failed deposit reverts the receive too: the message stays unused and can be retried or refunded.
    function test_revert_receiveAndDeposit_slippage_messageStaysUnused() public {
        bytes memory message =
            _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(address(vault), 998e6, omnibus, block.timestamp, 0));
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.SlippageExceeded.selector, 997e6, 998e6));
        router.receiveAndDeposit(message, "");
        assertFalse(transmitter.usedNonces("n1"));
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_revert_receiveAndDeposit_deadline() public {
        bytes memory message =
            _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, block.timestamp, 0));
        vm.warp(block.timestamp + 1);
        vm.expectRevert(IRestakeRouter.DeadlineExpired.selector);
        router.receiveAndDeposit(message, "");
    }

    function test_revert_receiveAndDeposit_depositsDisabled() public {
        vm.prank(guardian);
        router.disablePoolDeposits(address(vault));
        bytes memory message =
            _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, block.timestamp, 0));
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.DepositsDisabled.selector, address(vault)));
        router.receiveAndDeposit(message, "");
    }

    function test_revert_receiveAndDeposit_unregisteredPool() public {
        bytes memory message = _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(bob, 0, omnibus, block.timestamp, 0));
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.PoolNotRegistered.selector, bob));
        router.receiveAndDeposit(message, "");
    }

    function test_revert_receiveAndDeposit_malformedHook() public {
        bytes memory message = _cctpMessage("n1", omnibus, 1_000e6, 0, hex"1234");
        vm.expectRevert(IRestakeRouter.InvalidHookData.selector);
        router.receiveAndDeposit(message, "");

        // Dirty upper bits in an address word.
        bytes memory dirty = abi.encode(uint256(type(uint160).max) + 1, 0, omnibus, block.timestamp, bytes32(0));
        message = _cctpMessage("n2", omnibus, 1_000e6, 0, dirty);
        vm.expectRevert(IRestakeRouter.InvalidHookData.selector);
        router.receiveAndDeposit(message, "");

        message = _cctpMessage("n3", omnibus, 1_000e6, 0, _hook(address(vault), 0, address(0), block.timestamp, 0));
        vm.expectRevert(IRestakeRouter.InvalidHookData.selector);
        router.receiveAndDeposit(message, "");
    }

    /// @dev A non-TokenMessenger recipient could return success without minting anything.
    function test_revert_receive_recipientNotTokenMessenger() public {
        MockFakeRecipient fake = new MockFakeRecipient();
        bytes memory message = _cctpMessageTo(
            "n1", address(fake), address(router), omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, 1e18, 0)
        );
        vm.expectRevert(IRestakeRouter.InvalidCctpMessage.selector);
        router.receiveAndDeposit(message, "");
    }

    function test_revert_receive_mintRecipientNotRouter() public {
        bytes memory message = _cctpMessageTo(
            "n1", address(tokenMessenger), bob, omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, 1e18, 0)
        );
        vm.expectRevert(IRestakeRouter.InvalidCctpMessage.selector);
        router.receiveAndDeposit(message, "");
    }

    function test_revert_receive_truncatedMessage() public {
        vm.expectRevert(IRestakeRouter.InvalidCctpMessage.selector);
        router.receiveAndDeposit(new bytes(375), "");
    }

    // ───────────── Inbound: receiveAndRefund ─────────────

    function test_receiveAndRefund_byReceiverBeforeDeadline() public {
        vm.prank(guardian);
        router.disableAllDeposits();
        bytes memory message =
            _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, block.timestamp + 1 days, 0));

        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.CctpRefunded(omnibus, 1_000e6);
        vm.prank(omnibus);
        uint256 amount = router.receiveAndRefund(message, "");

        assertEq(amount, 1_000e6);
        assertEq(usdc.balanceOf(omnibus), 1_000e6, "no fee on refunds");
        assertEq(usdc.balanceOf(feeRecipient), 0);
        _assertRouterClean();
    }

    function test_receiveAndRefund_byAnyoneAfterDeadline() public {
        bytes memory message =
            _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, block.timestamp, 0));

        vm.expectRevert(IRestakeRouter.RefundNotAllowed.selector);
        vm.prank(relayer);
        router.receiveAndRefund(message, "");

        vm.warp(block.timestamp + 1);
        vm.prank(relayer);
        router.receiveAndRefund(message, "");
        assertEq(usdc.balanceOf(omnibus), 1_000e6);
        _assertRouterClean();
    }

    function test_receiveAndRefund_malformedHook_toMessageSender() public {
        bytes memory message = _cctpMessage("n1", omnibus, 1_000e6, 0, hex"deadbeef");
        vm.prank(relayer);
        router.receiveAndRefund(message, "");
        assertEq(usdc.balanceOf(omnibus), 1_000e6);
        _assertRouterClean();
    }

    function test_revert_receiveAndRefund_afterDeposit() public {
        bytes memory message =
            _cctpMessage("n1", omnibus, 1_000e6, 0, _hook(address(vault), 0, omnibus, block.timestamp, 0));
        router.receiveAndDeposit(message, "");
        vm.expectRevert("Nonce already used");
        vm.prank(omnibus);
        router.receiveAndRefund(message, "");
    }

    // ───────────── Outbound: withdrawAndBridge ─────────────

    function test_withdrawAndBridge_vault() public {
        uint256 shares = _deposit(omnibus, address(vault), 1_000e6);
        _approveShares(omnibus, address(vault), shares);
        IRestakeRouter.CctpBridge memory b = _bridge(omnibus, 0);

        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.Withdraw(omnibus, address(router), address(vault), address(usdc), shares, 997e6);
        vm.expectEmit(true, true, true, true, address(router));
        emit IRestakeRouter.CctpBridged(omnibus, ARBITRUM_DOMAIN, _toBytes32(omnibus), 997e6, 0, 2000);
        vm.prank(omnibus);
        uint256 assets = router.withdrawAndBridge(address(vault), shares, 997e6, block.timestamp, b);

        assertEq(assets, 997e6);
        assertEq(vault.balanceOf(omnibus), 0);
        _assertBurn(997e6, omnibus, 0, 2000);
        _assertRouterClean();
    }

    function test_withdrawAndBridge_aave_fullMax_fast() public {
        _deposit(omnibus, address(aToken), 20_000e6);
        _accrueAaveInterest(50);
        uint256 balance = aToken.balanceOf(omnibus);
        _approveShares(omnibus, address(aToken), type(uint256).max);
        IRestakeRouter.CctpBridge memory b = _bridge(omnibus, 2e6);
        b.minFinalityThreshold = 1000;

        vm.prank(omnibus);
        uint256 assets = router.withdrawAndBridge(address(aToken), type(uint256).max, balance - 1, block.timestamp, b);

        assertApproxEqAbs(assets, balance, 1);
        assertEq(aToken.scaledBalanceOf(omnibus), 0, "no dust");
        _assertBurn(assets, omnibus, 2e6, 1000);
        _assertRouterClean();
    }

    function test_withdrawAndBridge_worksWhenDepositsDisabled() public {
        uint256 shares = _deposit(omnibus, address(vault), 1_000e6);
        vm.prank(guardian);
        router.disableAllDeposits();
        _approveShares(omnibus, address(vault), shares);
        vm.prank(omnibus);
        router.withdrawAndBridge(address(vault), shares, 1, block.timestamp, _bridge(omnibus, 0));
        _assertRouterClean();
    }

    function test_revert_withdrawAndBridge_badDestination() public {
        vm.startPrank(omnibus);
        vm.expectRevert(IRestakeRouter.InvalidBridgeDestination.selector);
        router.withdrawAndBridge(address(vault), 1, 1, block.timestamp, _bridge(address(0), 0));

        vm.expectRevert(IRestakeRouter.InvalidBridgeDestination.selector);
        router.withdrawAndBridge(address(vault), 1, 1, block.timestamp, _bridge(address(router), 0));

        IRestakeRouter.CctpBridge memory local = _bridge(omnibus, 0);
        local.destinationDomain = BASE_DOMAIN;
        vm.expectRevert(IRestakeRouter.InvalidBridgeDestination.selector);
        router.withdrawAndBridge(address(vault), 1, 1, block.timestamp, local);
        vm.stopPrank();
    }

    function test_revert_withdrawAndBridge_slippage() public {
        uint256 shares = _deposit(omnibus, address(vault), 1_000e6);
        _approveShares(omnibus, address(vault), shares);
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.SlippageExceeded.selector, 997e6, 998e6));
        vm.prank(omnibus);
        router.withdrawAndBridge(address(vault), shares, 998e6, block.timestamp, _bridge(omnibus, 0));
    }

    function test_revert_withdrawAndBridge_deadlineAndZero() public {
        vm.expectRevert(IRestakeRouter.DeadlineExpired.selector);
        router.withdrawAndBridge(address(vault), 1, 1, block.timestamp - 1, _bridge(omnibus, 0));
        vm.expectRevert(IRestakeRouter.ZeroAmount.selector);
        router.withdrawAndBridge(address(vault), 1, 0, block.timestamp, _bridge(omnibus, 0));
        vm.expectRevert(abi.encodeWithSelector(IRestakeRouter.PoolNotRegistered.selector, bob));
        router.withdrawAndBridge(bob, 1, 1, block.timestamp, _bridge(omnibus, 0));
    }

    function test_revert_withdrawAndBridge_maxFeeNotBelowAmount() public {
        uint256 shares = _deposit(omnibus, address(vault), 1_000e6);
        _approveShares(omnibus, address(vault), shares);
        vm.expectRevert("Max fee must be less than amount");
        vm.prank(omnibus);
        router.withdrawAndBridge(address(vault), shares, 1, block.timestamp, _bridge(omnibus, 997e6));
    }

    /// @dev Round trip: Arbitrum omnibus → Base vault → Arbitrum omnibus.
    function testFuzz_roundTrip(uint256 amount, uint256 cctpFee) public {
        amount = bound(amount, 2, 10_000_000e6);
        cctpFee = bound(cctpFee, 0, (amount - 1) / 1000);
        bytes memory message =
            _cctpMessage("n1", omnibus, amount, cctpFee, _hook(address(vault18), 0, omnibus, block.timestamp, 0));
        (uint256 shares, uint256 fee) = router.receiveAndDeposit(message, "");
        vm.assume(shares > 0);
        _approveShares(omnibus, address(vault18), shares);
        vm.prank(omnibus);
        uint256 assets = router.withdrawAndBridge(address(vault18), shares, 1, block.timestamp, _bridge(omnibus, 0));
        assertApproxEqAbs(assets, amount - cctpFee - fee, 1);
        _assertRouterClean();
    }

    // ───────────── Helpers ─────────────

    function _bridge(address recipient, uint256 maxFee) internal pure returns (IRestakeRouter.CctpBridge memory) {
        return IRestakeRouter.CctpBridge({
            destinationDomain: ARBITRUM_DOMAIN,
            mintRecipient: _toBytes32(recipient),
            maxFee: maxFee,
            minFinalityThreshold: 2000
        });
    }

    function _assertBurn(uint256 amount, address recipient, uint256 maxFee, uint32 finality) internal view {
        (
            uint256 bAmount,
            uint32 domain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destinationCaller,
            uint256 bMaxFee,
            uint32 bFinality
        ) = tokenMessenger.lastBurn();
        assertEq(bAmount, amount, "burn amount");
        assertEq(domain, ARBITRUM_DOMAIN);
        assertEq(mintRecipient, _toBytes32(recipient));
        assertEq(burnToken, address(usdc));
        assertEq(destinationCaller, bytes32(0));
        assertEq(bMaxFee, maxFee);
        assertEq(bFinality, finality);
        assertEq(usdc.balanceOf(address(tokenMessenger)), amount, "burned");
    }
}
