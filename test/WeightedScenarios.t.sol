// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SPBase} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SpendPartitionWeighted} from "../src/SpendPartitionWeighted.sol";
import {ISpendPartition} from "../src/ISpendPartition.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {RevertingToken, ReentrantToken, ReentrantDelegate} from "./mocks/AdversarialTokens.sol";

/// Deterministic weighted constructor and payment scenarios; no property campaign in this iteration.
contract WeightedScenariosTest is SPBase {
    function setUp() public {
        usdc = new MockUSDC();
    }

    function _weights(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory w) {
        w = new uint256[](3);
        w[0] = a;
        w[1] = b;
        w[2] = c;
    }

    function _weighted(uint256[] memory weights, uint256 budget_, uint256 num, uint256 den)
        internal
        returns (SpendPartitionWeighted sp)
    {
        sp = new SpendPartitionWeighted(usdc, _agents(weights.length), weights, budget_, num, den, WINDOW);
        usdc.mint(address(sp), budget_ * 64);
    }

    function _assertReservations(SpendPartitionWeighted sp, uint256 a, uint256 b, uint256 c) internal view {
        address[] memory ag = _agents(3);
        assertEq(sp.reservationOf(ag[0]), a);
        assertEq(sp.reservationOf(ag[1]), b);
        assertEq(sp.reservationOf(ag[2]), c);
        assertEq(a + b + c, sp.reservedTotal());
        for (uint256 i = 0; i < ag.length; ++i) {
            assertTrue(sp.isAgent(ag[i]));
            assertEq(sp.indexOf(ag[i]), i);
        }
    }

    function _weightedPay(SpendPartitionWeighted sp, address agent, uint256 amount) internal {
        vm.prank(agent);
        sp.pay(MERCHANT, amount);
    }

    function test_EqualWeights() public {
        _assertReservations(_weighted(_weights(1, 1, 1), 100, 1, 1), 34, 33, 33);
    }

    function test_UnequalWeights() public {
        _assertReservations(_weighted(_weights(1, 2, 3), 100, 1, 1), 17, 33, 50);
    }

    function test_ZeroWeight() public {
        _assertReservations(_weighted(_weights(0, 1, 3), 100, 1, 1), 0, 25, 75);
    }

    /// R=2, W=4: remainders [2,2,0]. The single leftover goes to index 0.
    /// Reverse the addresses to show that priority follows registration, not address order.
    function test_EqualRemainderTieUsesRegistrationIndex() public {
        address[] memory ag = _agents(3);
        (ag[0], ag[1]) = (ag[1], ag[0]);
        SpendPartitionWeighted sp = new SpendPartitionWeighted(usdc, ag, _weights(1, 1, 2), 2, 1, 1, WINDOW);
        assertEq(sp.indexOf(ag[0]), 0);
        assertEq(sp.reservationOf(ag[0]), 1);
        assertEq(sp.reservationOf(ag[1]), 0);
        assertEq(sp.reservationOf(ag[2]), 1);
    }

    function test_RhoZero() public {
        SpendPartitionWeighted sp = _weighted(_weights(0, 1, 3), 100, 0, 1);
        _assertReservations(sp, 0, 0, 0);
        assertEq(sp.surplusCap(), 100);
        address[] memory ag = _agents(3);
        _weightedPay(sp, ag[0], 100);
        assertEq(sp.surplusUsed(), 100);
        vm.expectRevert(abi.encodeWithSelector(SpendPartitionWeighted.SurplusExhausted.selector, 1, 0));
        _weightedPay(sp, ag[1], 1);
    }

    function test_RhoOne() public {
        SpendPartitionWeighted sp = _weighted(_weights(1, 2, 3), 100, 1, 1);
        assertEq(sp.surplusCap(), 0);
        address[] memory ag = _agents(3);
        vm.expectRevert(abi.encodeWithSelector(SpendPartitionWeighted.SurplusExhausted.selector, 1, 0));
        _weightedPay(sp, ag[0], 18);
        assertEq(sp.spentOf(ag[0]), 0);
        _weightedPay(sp, ag[0], 17);
        _weightedPay(sp, ag[1], 33);
        _weightedPay(sp, ag[2], 50);
        assertEq(usdc.balanceOf(MERCHANT), 100);
        assertEq(sp.surplusUsed(), 0);
    }

    function test_InvalidWeightArrayLength() public {
        address[] memory ag = _agents(2);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, _weights(1, 1, 1), 100, 1, 1, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, new uint256[](1), 100, 1, 1, WINDOW);
    }

    function test_AllZeroWeights() public {
        address[] memory ag = _agents(3);
        uint256[] memory weights = _weights(0, 0, 0);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 100, 1, 1, WINDOW);
        // Even the shared-pool endpoint requires a valid positive weight sum.
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 100, 0, 1, WINDOW);
    }

    function test_WeightSumOverflowUsesConfigError() public {
        address[] memory ag = _agents(3);
        uint256[] memory weights = _weights(type(uint256).max, 1, 0);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 100, 1, 1, WINDOW);
    }

    /// R*w exceeds uint256; W=2^256-1 and R is odd, giving [ceil(R/2),floor(R/2),0].
    function test_FullPrecisionAtMaximumBudgetAndWeightSum() public {
        uint256 r = type(uint192).max;
        uint256 half = uint256(1) << 255;
        SpendPartitionWeighted sp = _weighted(_weights(half, half - 1, 0), r, 1, 1);
        _assertReservations(sp, (r / 2) + 1, r / 2, 0);
        address[] memory ag = _agents(3);
        _weightedPay(sp, ag[0], (r / 2) + 1);
        _weightedPay(sp, ag[1], r / 2);
        assertEq(usdc.balanceOf(MERCHANT), r);
    }

    function test_ReservationFirstSurplusAndIsolation() public {
        SpendPartitionWeighted sp = _weighted(_weights(0, 1, 3), 200, 1, 2);
        _assertReservations(sp, 0, 25, 75);
        address[] memory ag = _agents(3);
        _weightedPay(sp, ag[1], 20);
        assertEq(sp.surplusUsed(), 0);
        _weightedPay(sp, ag[1], 15); // five reservation units, then ten surplus
        assertEq(sp.spentOf(ag[1]), 35);
        assertEq(sp.surplusUsed(), 10);
        _weightedPay(sp, ag[0], 90); // zero-weight agent may exhaust the remaining surplus
        vm.expectRevert(abi.encodeWithSelector(SpendPartitionWeighted.SurplusExhausted.selector, 1, 0));
        _weightedPay(sp, ag[0], 1);
        _weightedPay(sp, ag[2], 75); // protected capacity remains usable
        assertEq(usdc.balanceOf(MERCHANT), 200);
    }

    function test_TwoSlotLayoutAndLazyReset() public {
        SpendPartitionWeighted sp = _weighted(_weights(0, 1, 3), 200, 1, 2);
        address[] memory ag = _agents(3);
        _weightedPay(sp, ag[1], 125);
        _weightedPay(sp, ag[2], 10);
        bytes32 key = _agentKey(ag[1]);
        bytes32 reservationKey = bytes32(uint256(key) + 1);
        bytes32 untouchedBefore = vm.load(address(sp), _agentKey(ag[2]));
        assertEq(uint256(vm.load(address(sp), reservationKey)), 25);
        vm.warp(sp.startTime() + 5 * WINDOW);
        assertEq(sp.spentOf(ag[1]), 0);
        assertEq(sp.spentOf(ag[2]), 0);
        assertEq(sp.surplusUsed(), 0);
        _weightedPay(sp, ag[1], 125);
        uint256 packed = uint256(vm.load(address(sp), key));
        assertEq(uint16(packed), 2);
        assertEq(uint48(packed >> 16), 5);
        assertEq(uint192(packed >> 64), 125);
        assertEq(uint256(vm.load(address(sp), reservationKey)), 25);
        assertEq(vm.load(address(sp), _agentKey(ag[2])), untouchedBefore);
    }

    function test_RejectedFirstPaymentAfterRolloverIsAtomic() public {
        SpendPartitionWeighted sp = _weighted(_weights(0, 1, 3), 200, 1, 2);
        address agent = _agents(3)[1];
        _weightedPay(sp, agent, 125);
        bytes32 agentBefore = vm.load(address(sp), _agentKey(agent));
        bytes32 surplusBefore = vm.load(address(sp), SURPLUS_SLOT);
        uint256 merchantBefore = usdc.balanceOf(MERCHANT);
        vm.warp(sp.startTime() + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(SpendPartitionWeighted.SurplusExhausted.selector, 101, 100));
        _weightedPay(sp, agent, 126);
        assertEq(vm.load(address(sp), _agentKey(agent)), agentBefore);
        assertEq(vm.load(address(sp), SURPLUS_SLOT), surplusBefore);
        assertEq(usdc.balanceOf(MERCHANT), merchantBefore);
    }

    function test_RevertingTransferRollsBackAccounting() public {
        RevertingToken token = new RevertingToken();
        address[] memory ag = _agents(3);
        SpendPartitionWeighted sp = new SpendPartitionWeighted(token, ag, _weights(0, 1, 3), 200, 1, 2, WINDOW);
        token.mint(address(sp), 200);
        bytes32 beforeSlot = vm.load(address(sp), _agentKey(ag[1]));
        vm.expectRevert(RevertingToken.TransferRefused.selector);
        _weightedPay(sp, ag[1], 125);
        assertEq(vm.load(address(sp), _agentKey(ag[1])), beforeSlot);
        assertEq(sp.spentOf(ag[1]), 0);
        assertEq(sp.surplusUsed(), 0);
        assertEq(sp.reservationOf(ag[1]), 25);
    }

    function test_TransferCallbackSeesAccounting() public {
        ReentrantToken token = new ReentrantToken();
        address[] memory ag = _agents(3);
        SpendPartitionWeighted sp = new SpendPartitionWeighted(token, ag, _weights(0, 1, 3), 200, 1, 2, WINDOW);
        token.mint(address(sp), 200);
        token.arm(address(sp), abi.encodeCall(ISpendPartition.spentOf, (ag[1])), false);
        _weightedPay(sp, ag[1], 40);
        assertTrue(token.callbackSucceeded());
        assertEq(abi.decode(token.callbackReturnData(), (uint256)), 40);
        assertEq(sp.surplusUsed(), 15);
    }

    function test_ReentrancyByRegisteredDelegateIsBlocked() public {
        ReentrantToken token = new ReentrantToken();
        ReentrantDelegate delegate = new ReentrantDelegate();
        address[] memory ag = _agents(3);
        ag[1] = address(delegate);
        SpendPartitionWeighted sp = new SpendPartitionWeighted(token, ag, _weights(0, 1, 3), 200, 1, 2, WINDOW);
        token.mint(address(sp), 200);
        token.arm(
            address(delegate),
            abi.encodeCall(ReentrantDelegate.reenter, (ISpendPartition(address(sp)), MERCHANT, 1)),
            false
        );
        delegate.payOnce(ISpendPartition(address(sp)), MERCHANT, 40);
        assertTrue(token.callbackRan());
        assertFalse(token.callbackSucceeded());
        assertEq(bytes4(token.callbackReturnData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(sp.spentOf(address(delegate)), 40);
        assertEq(token.balanceOf(MERCHANT), 40);
    }

    function test_BaselineConfigurationValidation() public {
        address[] memory ag = _agents(3);
        uint256[] memory weights = _weights(1, 2, 3);
        vm.expectRevert(SpendPartitionWeighted.ZeroAddress.selector);
        new SpendPartitionWeighted(IERC20(address(0)), ag, weights, 100, 1, 2, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, new address[](0), new uint256[](0), 100, 1, 2, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, new address[](65536), new uint256[](65536), 100, 1, 2, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 0, 1, 2, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, uint256(type(uint192).max) + 1, 1, 2, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 100, 1, 0, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 100, 3, 2, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 100, 1, uint256(type(uint32).max) + 1, WINDOW);
        vm.expectRevert(SpendPartitionWeighted.InvalidConfig.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 100, 1, 2, 0);
        ag[1] = ag[0];
        vm.expectRevert(abi.encodeWithSelector(SpendPartitionWeighted.DuplicateAgent.selector, ag[0]));
        new SpendPartitionWeighted(usdc, ag, weights, 100, 1, 2, WINDOW);
        ag[1] = address(0);
        vm.expectRevert(SpendPartitionWeighted.ZeroAddress.selector);
        new SpendPartitionWeighted(usdc, ag, weights, 100, 1, 2, WINDOW);
    }
}
