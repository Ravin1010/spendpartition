// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {ISpendPartition} from "../src/ISpendPartition.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReentrantToken, RevertingToken, FalseReturningToken, ReentrantDelegate} from "./mocks/AdversarialTokens.sol";

/// Layout v1.1 Part 5: the token is assumed standard, and the payment path keeps the transfer last.
/// These tests drop that assumption and use tokens that call back, revert, or lie.
contract AdversarialTokenTest is Test {
    address internal constant MERCHANT = address(0xBEEF);
    uint256 internal constant WINDOW = 7 days;
    uint256 internal constant BUDGET = 100;

    address[] internal ag;

    function setUp() public {
        ag = new address[](2);
        ag[0] = address(0xA000);
        ag[1] = address(0xA001);
    }

    function _agentSlot(address agent) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, uint256(0)));
    }

    // =====================================================================
    // reentrancy
    // =====================================================================

    /// The token calls pay() again, as the same delegate, from inside the outer transfer.
    function test_ReentrantPaymentBySameDelegateReverts() public {
        ReentrantToken token = new ReentrantToken();
        SpendPartition sp = new SpendPartition(IERC20(address(token)), ag, BUDGET, 1, 2, WINDOW);
        token.mint(address(sp), BUDGET * 64);

        // The callback runs with the contract as msg.sender, so it uses a delegate's authority via
        // a nested pay(); bubbling makes the outer call fail with the inner revert data.
        token.arm(address(sp), abi.encodeCall(ISpendPartition.pay, (MERCHANT, 10)), true);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(ag[0]);
        sp.pay(MERCHANT, 20);

        assertEq(token.balanceOf(MERCHANT), 0);
        assertEq(vm.load(address(sp), _agentSlot(ag[0])), bytes32(uint256(1))); // indexPlusOne only
    }

    /// Same, with the callback swallowed by the token instead of bubbled: the nested call must still
    /// fail, and the outer payment must complete exactly once.
    function test_ReentrantCallbackFailsWhileOuterPaymentCompletes() public {
        ReentrantToken token = new ReentrantToken();
        SpendPartition sp = new SpendPartition(IERC20(address(token)), ag, BUDGET, 1, 2, WINDOW);
        token.mint(address(sp), BUDGET * 64);

        token.arm(address(sp), abi.encodeCall(ISpendPartition.pay, (MERCHANT, 10)), false);

        vm.prank(ag[0]);
        sp.pay(MERCHANT, 20);

        assertTrue(token.callbackRan());
        assertFalse(token.callbackSucceeded());
        assertEq(bytes4(token.callbackReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(sp.spentOf(ag[0]), 20);
        assertEq(token.balanceOf(MERCHANT), 20);
    }

    /// The guard is contract-wide, not per delegate: a nested payment by the other delegate is
    /// refused as well.
    function test_ReentrantPaymentByOtherDelegateReverts() public {
        ReentrantToken token = new ReentrantToken();
        SpendPartition sp = new SpendPartition(IERC20(address(token)), ag, BUDGET, 1, 2, WINDOW);
        token.mint(address(sp), BUDGET * 64);

        token.arm(address(sp), abi.encodeCall(ISpendPartition.pay, (MERCHANT, 10)), false);

        vm.prank(ag[0]);
        sp.pay(MERCHANT, 20);

        assertFalse(token.callbackSucceeded());
        assertEq(sp.spentOf(ag[1]), 0);
        assertEq(token.balanceOf(MERCHANT), 20);
    }

    /// A read during the callback sees the payment already accounted for, which is what
    /// interaction-last buys: there is no window in which the transfer has started but the
    /// accounting has not.
    function test_ViewDuringCallbackSeesCommittedState() public {
        ReentrantToken token = new ReentrantToken();
        SpendPartition sp = new SpendPartition(IERC20(address(token)), ag, BUDGET, 1, 2, WINDOW);
        token.mint(address(sp), BUDGET * 64);

        token.arm(address(sp), abi.encodeCall(ISpendPartition.spentOf, (ag[0])), false);

        vm.prank(ag[0]);
        sp.pay(MERCHANT, 40); // r = 25, so 15 spills into the surplus

        assertTrue(token.callbackSucceeded());
        assertEq(abi.decode(token.callbackReturnData(), (uint256)), 40);
        assertEq(sp.spentOf(ag[0]), 40);
        assertEq(sp.surplusUsed(), 15);
    }

    /// The delegate is itself a contract, so the token callback re-enters under the delegate's own
    /// authority. This is the case the guard exists for: a token calling back on its own account is
    /// rejected anyway, because it was never registered.
    function test_ReentrantDelegateIsBlockedAndPaysOnce() public {
        ReentrantDelegate delegate = new ReentrantDelegate();
        address[] memory agents = new address[](2);
        agents[0] = address(delegate);
        agents[1] = address(0xA001);

        ReentrantToken token = new ReentrantToken();
        SpendPartition sp = new SpendPartition(IERC20(address(token)), agents, BUDGET, 1, 2, WINDOW);
        token.mint(address(sp), BUDGET * 64);
        token.arm(
            address(delegate),
            abi.encodeCall(ReentrantDelegate.reenter, (ISpendPartition(address(sp)), MERCHANT, 10)),
            false
        );

        vm.recordLogs();
        delegate.payOnce(ISpendPartition(address(sp)), MERCHANT, 20);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 payments;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(sp) && logs[i].topics[0] == keccak256("Paid(address,address,uint256,uint256,uint48)")) {
                ++payments;
            }
        }

        assertTrue(token.callbackRan());
        assertFalse(token.callbackSucceeded());
        assertEq(payments, 1, "one entry point call, one payment");
        assertEq(sp.spentOf(address(delegate)), 20);
        assertEq(token.balanceOf(MERCHANT), 20);
    }

    // =====================================================================
    // tokens that refuse or lie
    // =====================================================================

    function test_RevertingTransferLeavesNoTrace() public {
        RevertingToken token = new RevertingToken();
        SpendPartition sp = new SpendPartition(IERC20(address(token)), ag, BUDGET, 1, 2, WINDOW);
        token.mint(address(sp), BUDGET * 64);

        bytes32 agentBefore = vm.load(address(sp), _agentSlot(ag[0]));
        bytes32 surplusBefore = vm.load(address(sp), bytes32(uint256(1)));

        vm.expectRevert(RevertingToken.TransferRefused.selector);
        vm.prank(ag[0]);
        sp.pay(MERCHANT, 20);

        assertEq(vm.load(address(sp), _agentSlot(ag[0])), agentBefore);
        assertEq(vm.load(address(sp), bytes32(uint256(1))), surplusBefore);
        assertEq(sp.spentOf(ag[0]), 0);
    }

    function test_FalseReturningTransferIsRejected() public {
        FalseReturningToken token = new FalseReturningToken();
        SpendPartition sp = new SpendPartition(IERC20(address(token)), ag, BUDGET, 1, 2, WINDOW);
        token.mint(address(sp), BUDGET * 64);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ag[0]);
        sp.pay(MERCHANT, 20);

        assertEq(sp.spentOf(ag[0]), 0);
        assertEq(sp.surplusUsed(), 0);
    }
}
