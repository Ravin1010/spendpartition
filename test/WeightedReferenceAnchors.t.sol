// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SpendPartitionWeightedReference as Ref} from "../src/SpendPartitionWeightedReference.sol";
import {ISpendPartition} from "../src/ISpendPartition.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RevertingToken, ReentrantToken, ReentrantDelegate} from "./mocks/AdversarialTokens.sol";

/// Fixed, hand-calculated anchors for the plain reference alone. No optimized oracle or fuzzing.
contract WeightedReferenceAnchorsTest is Test {
    MockUSDC private token;
    address private constant MERCHANT = address(0xBEEF);
    uint256 private constant WINDOW = 7 days;

    function setUp() public {
        token = new MockUSDC();
    }

    function _agents(uint256 n) private pure returns (address[] memory agents) {
        agents = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            agents[i] = address(uint160(0xA000 + i));
        }
    }

    function _weights(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory weights) {
        weights = new uint256[](3);
        weights[0] = a;
        weights[1] = b;
        weights[2] = c;
    }

    function _deploy(uint256[] memory weights, uint256 budget_, uint256 num, uint256 den) private returns (Ref ref) {
        ref = new Ref(token, _agents(weights.length), weights, budget_, num, den, WINDOW);
        token.mint(address(ref), budget_ * 64);
    }

    function _check(Ref ref, uint256 a, uint256 b, uint256 c) private view {
        address[] memory ag = _agents(3);
        assertEq(ref.reservationOf(ag[0]), a);
        assertEq(ref.reservationOf(ag[1]), b);
        assertEq(ref.reservationOf(ag[2]), c);
        assertEq(a + b + c, ref.reservedTotal());
        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(ref.isAgent(ag[i]));
            assertEq(ref.indexOf(ag[i]), i);
        }
    }

    function _pay(Ref ref, uint256 index, uint256 amount) private {
        vm.prank(address(uint160(0xA000 + index)));
        ref.pay(MERCHANT, amount);
    }

    function test_EqualWeights() public {
        _check(_deploy(_weights(1, 1, 1), 100, 1, 1), 34, 33, 33);
    }

    function test_UnequalWeights() public {
        _check(_deploy(_weights(1, 2, 3), 100, 1, 1), 17, 33, 50);
    }

    function test_ZeroWeight() public {
        _check(_deploy(_weights(0, 1, 3), 100, 1, 1), 0, 25, 75);
    }

    function test_TieUsesRegistrationOrder() public {
        address[] memory ag = _agents(3);
        (ag[0], ag[1]) = (ag[1], ag[0]);
        Ref ref = new Ref(token, ag, _weights(1, 1, 2), 2, 1, 1, WINDOW);
        // Quotas [0.5,0.5,1]: registration index zero receives the leftover.
        assertEq(ref.indexOf(ag[0]), 0);
        assertEq(ref.reservationOf(ag[0]), 1);
        assertEq(ref.reservationOf(ag[1]), 0);
        assertEq(ref.reservationOf(ag[2]), 1);
    }

    function test_MultipleLeftoversSelectDistinctWinners() public {
        uint256[] memory weights = new uint256[](4);
        for (uint256 i = 0; i < 4; ++i) {
            weights[i] = 1;
        }
        Ref ref = _deploy(weights, 3, 1, 1);
        address[] memory ag = _agents(4);
        // Four quotas of 0.75, with three distinct winning indices.
        assertEq(ref.reservationOf(ag[0]), 1);
        assertEq(ref.reservationOf(ag[1]), 1);
        assertEq(ref.reservationOf(ag[2]), 1);
        assertEq(ref.reservationOf(ag[3]), 0);
    }

    function test_RhoZero() public {
        Ref ref = _deploy(_weights(0, 1, 3), 100, 0, 1);
        _check(ref, 0, 0, 0);
        assertEq(ref.surplusCap(), 100);
        _pay(ref, 0, 100);
        assertEq(ref.surplusUsed(), 100);
        vm.expectRevert(abi.encodeWithSelector(Ref.SurplusExhausted.selector, 1, 0));
        _pay(ref, 1, 1);
    }

    function test_RhoOne() public {
        Ref ref = _deploy(_weights(1, 2, 3), 100, 1, 1);
        assertEq(ref.surplusCap(), 0);
        vm.expectRevert(abi.encodeWithSelector(Ref.SurplusExhausted.selector, 1, 0));
        _pay(ref, 0, 18);
        assertEq(ref.spentOf(_agents(3)[0]), 0);
        _pay(ref, 0, 17);
        _pay(ref, 1, 33);
        _pay(ref, 2, 50);
        assertEq(token.balanceOf(MERCHANT), 100);
        assertEq(ref.surplusUsed(), 0);
    }

    function test_InvalidWeightLength() public {
        address[] memory ag = _agents(3);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, new uint256[](2), 100, 1, 1, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, new uint256[](4), 100, 1, 1, WINDOW);
    }

    function test_AllZeroWeights() public {
        address[] memory ag = _agents(3);
        uint256[] memory weights = _weights(0, 0, 0);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, 100, 1, 1, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, 100, 0, 1, WINDOW);
    }

    function test_WeightSumOverflowIsInvalidConfig() public {
        address[] memory ag = _agents(3);
        uint256[] memory weights = _weights(type(uint256).max, 0, 1);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, 100, 1, 1, WINDOW);
    }

    function test_FullPrecisionQuotaWithOverflowingProduct() public {
        uint256 budget_ = type(uint192).max;
        uint256 weight = uint256(1) << 200;
        assertGt(weight, type(uint256).max / budget_, "naive product would overflow");
        Ref ref = _deploy(_weights(weight, weight, 0), budget_, 1, 1);
        // Odd R split exactly in half: the equal-remainder tie goes to index zero.
        _check(ref, budget_ / 2 + 1, budget_ / 2, 0);
        _pay(ref, 0, budget_ / 2 + 1);
        _pay(ref, 1, budget_ / 2);
        assertEq(token.balanceOf(MERCHANT), budget_);
    }

    function test_ReservationFirstThenSurplusProtectsOtherAgent() public {
        Ref ref = _deploy(_weights(0, 1, 3), 200, 1, 2);
        _check(ref, 0, 25, 75);
        _pay(ref, 1, 20);
        assertEq(ref.surplusUsed(), 0);
        _pay(ref, 1, 15); // Remaining reservation 5, surplus charge 10.
        assertEq(ref.surplusUsed(), 10);
        _pay(ref, 1, 5); // Already beyond reservation: entire payment is surplus.
        assertEq(ref.surplusUsed(), 15);
        _pay(ref, 0, 85); // Zero-weight delegate can consume the remaining surplus.
        vm.expectRevert(abi.encodeWithSelector(Ref.SurplusExhausted.selector, 1, 0));
        _pay(ref, 1, 1);
        _pay(ref, 2, 75);
        assertEq(token.balanceOf(MERCHANT), 200);
    }

    function test_LazyWindowResetAfterIdleWindows() public {
        Ref ref = _deploy(_weights(0, 1, 3), 200, 1, 2);
        address[] memory ag = _agents(3);
        _pay(ref, 1, 125);
        _pay(ref, 2, 75);
        vm.warp(ref.startTime() + 5 * WINDOW);
        assertEq(ref.currentWindowId(), 5);
        assertEq(ref.spentOf(ag[1]), 0);
        assertEq(ref.spentOf(ag[2]), 0);
        assertEq(ref.surplusUsed(), 0);
        _check(ref, 0, 25, 75);
        _pay(ref, 1, 125);
        assertEq(ref.spentOf(ag[1]), 125);
        assertEq(ref.spentOf(ag[2]), 0);
        assertEq(ref.surplusUsed(), 100);
    }

    function test_RejectedPaymentAtomicAcrossWindowReset() public {
        Ref ref = _deploy(_weights(0, 1, 3), 200, 1, 2);
        _pay(ref, 1, 125);
        uint256 merchantBefore = token.balanceOf(MERCHANT);
        uint256 contractBefore = token.balanceOf(address(ref));
        vm.warp(ref.startTime() + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(Ref.SurplusExhausted.selector, 101, 100));
        _pay(ref, 1, 126);
        assertEq(ref.spentOf(_agents(3)[1]), 0);
        assertEq(ref.surplusUsed(), 0);
        assertEq(token.balanceOf(MERCHANT), merchantBefore);
        assertEq(token.balanceOf(address(ref)), contractBefore);
        _pay(ref, 1, 125); // Rejected call neither consumes budget nor leaves the guard locked.
        assertEq(ref.surplusUsed(), 100);
    }

    function test_BaselineConfigurationChecks() public {
        address[] memory ag = _agents(3);
        uint256[] memory weights = _weights(1, 2, 3);
        vm.expectRevert(Ref.ZeroAddress.selector);
        new Ref(IERC20(address(0)), ag, weights, 100, 1, 2, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, new address[](0), new uint256[](0), 100, 1, 2, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, 0, 1, 2, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, uint256(type(uint192).max) + 1, 1, 2, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, 100, 1, 0, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, 100, 3, 2, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, 100, 1, uint256(type(uint32).max) + 1, WINDOW);
        vm.expectRevert(Ref.InvalidConfig.selector);
        new Ref(token, ag, weights, 100, 1, 2, 0);
        ag[2] = ag[0];
        vm.expectRevert(abi.encodeWithSelector(Ref.DuplicateAgent.selector, ag[0]));
        new Ref(token, ag, weights, 100, 1, 2, WINDOW);
        ag[2] = address(0);
        vm.expectRevert(Ref.ZeroAddress.selector);
        new Ref(token, ag, weights, 100, 1, 2, WINDOW);
    }

    function test_InterfaceViewsMembershipAndAmountGuards() public {
        Ref ref = _deploy(_weights(1, 2, 3), 201, 1, 2);
        ISpendPartition api = ISpendPartition(address(ref));
        assertEq(api.budget(), 201);
        assertEq(api.agentCount(), 3);
        assertEq(api.rhoNum(), 1);
        assertEq(api.rhoDen(), 2);
        assertEq(api.reservedTotal(), 100);
        assertEq(api.surplusCap(), 101);
        assertEq(api.windowDuration(), WINDOW);
        assertEq(api.startTime(), vm.getBlockTimestamp());
        assertFalse(api.isAgent(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Ref.NotAgent.selector, address(this)));
        api.indexOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(Ref.NotAgent.selector, address(this)));
        api.reservationOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(Ref.NotAgent.selector, address(this)));
        api.spentOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(Ref.NotAgent.selector, address(this)));
        api.pay(MERCHANT, 1);
        vm.expectRevert(Ref.InvalidAmount.selector);
        _pay(ref, 0, 0);
        vm.expectRevert(Ref.InvalidAmount.selector);
        _pay(ref, 0, 202);
    }

    function test_TransferFailureRollsBackStateAndUnlocksGuard() public {
        RevertingToken badToken = new RevertingToken();
        Ref ref = new Ref(badToken, _agents(3), _weights(0, 1, 3), 200, 1, 2, WINDOW);
        badToken.mint(address(ref), 200);
        vm.expectRevert(RevertingToken.TransferRefused.selector);
        _pay(ref, 1, 125);
        assertEq(ref.spentOf(_agents(3)[1]), 0);
        assertEq(ref.surplusUsed(), 0);
        assertEq(badToken.balanceOf(MERCHANT), 0);
        // A second call reaches the transfer again rather than failing the reentrancy guard.
        vm.expectRevert(RevertingToken.TransferRefused.selector);
        _pay(ref, 1, 125);
    }

    function test_RegisteredDelegateReentrancyBlocked() public {
        ReentrantToken callbackToken = new ReentrantToken();
        ReentrantDelegate delegate = new ReentrantDelegate();
        address[] memory ag = _agents(3);
        ag[1] = address(delegate);
        Ref ref = new Ref(callbackToken, ag, _weights(0, 1, 3), 200, 1, 2, WINDOW);
        callbackToken.mint(address(ref), 200);
        callbackToken.arm(
            address(delegate),
            abi.encodeCall(ReentrantDelegate.reenter, (ISpendPartition(address(ref)), MERCHANT, 1)),
            false
        );
        delegate.payOnce(ISpendPartition(address(ref)), MERCHANT, 40);
        assertTrue(callbackToken.callbackRan());
        assertFalse(callbackToken.callbackSucceeded());
        assertEq(bytes4(callbackToken.callbackReturnData()), Ref.ReentrancyGuardReentrantCall.selector);
        assertEq(ref.spentOf(address(delegate)), 40);
        assertEq(ref.surplusUsed(), 15);
        assertEq(callbackToken.balanceOf(MERCHANT), 40);
    }

    function test_TransferLastCallbackSeesAccountedSpend() public {
        ReentrantToken callbackToken = new ReentrantToken();
        address[] memory ag = _agents(3);
        Ref ref = new Ref(callbackToken, ag, _weights(0, 1, 3), 200, 1, 2, WINDOW);
        callbackToken.mint(address(ref), 200);
        callbackToken.arm(address(ref), abi.encodeCall(ISpendPartition.spentOf, (ag[1])), false);
        _pay(ref, 1, 40);
        assertTrue(callbackToken.callbackSucceeded());
        assertEq(abi.decode(callbackToken.callbackReturnData(), (uint256)), 40);
        assertEq(ref.surplusUsed(), 15);
    }

    function test_WindowIdCheckedAtApiBound() public {
        Ref ref = _deploy(_weights(1, 2, 3), 100, 1, 1);
        uint256 tooLarge = uint256(type(uint48).max) + 1;
        vm.warp(ref.startTime() + tooLarge * WINDOW);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(48), tooLarge));
        ref.currentWindowId();
    }
}
