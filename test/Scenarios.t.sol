// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SPBase} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Fixed scenarios. Test IDs refer to Property-Test Plan v1.1; appendix traces are copied literally.
contract ScenariosTest is SPBase {
    function setUp() public {
        usdc = new MockUSDC();
    }

    // =====================================================================
    // Problem reproduction (proposal v1.3 section 1; demo acts 1-2)
    // =====================================================================

    /// Two per-delegation caps of 80 while the principal's intended aggregate is 100.
    /// Per-delegation caps are modelled on the same code path as rho = 1 with B_G = 80 + 80:
    /// each delegate has its own counter and S = 0.
    function test_Problem_PerDelegationCapsExceedIntendedAggregate() public {
        uint256 intendedAggregate = 100;
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 160, 1, 1);

        assertEq(sp.reservationOf(ag[0]), 80);
        assertEq(sp.reservationOf(ag[1]), 80);
        assertTrue(_pay(sp, ag[0], 80));
        assertTrue(_pay(sp, ag[1], 80));

        uint256 total = _sumSpent(sp, ag);
        assertEq(total, 160);
        assertGt(total, intendedAggregate);
    }

    /// Static 50/50 split of B_G = 100: delegate A requests 80 while B has spent nothing.
    function test_Problem_StaticSplitRejectsRequestWithinAggregate() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 1, 1); // r = (50, 50), S = 0

        vm.expectRevert(abi.encodeWithSelector(SpendPartition.SurplusExhausted.selector, 30, 0));
        vm.prank(ag[0]);
        sp.pay(MERCHANT, 80);

        assertEq(_sumSpent(sp, ag), 0);
        assertTrue(_pay(sp, ag[0], 50));
        assertFalse(_pay(sp, ag[0], 1));
    }

    // =====================================================================
    // Endpoints (demo acts 3-4), T6, T7
    // =====================================================================

    function test_SharedPool_ServesRequestAboveEqualShare() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 0, 1);
        assertTrue(_pay(sp, ag[0], 80));
        assertEq(sp.surplusUsed(), 80);
    }

    function test_SharedPool_FirstSpenderCanTakeAllCapacity() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 0, 1);
        assertTrue(_pay(sp, ag[0], 100));

        vm.expectRevert(abi.encodeWithSelector(SpendPartition.SurplusExhausted.selector, 20, 0));
        vm.prank(ag[1]);
        sp.pay(MERCHANT, 20);
    }

    /// T6 regression anchor: B_G = 100, N = 3, rho = 1 gives r = (34, 33, 33); B_G = 101 gives (34, 34, 33).
    function test_T6_StaticPartitionApportionment() public {
        address[] memory ag = _agents(3);

        SpendPartition sp = _deploy(ag, 100, 1, 1);
        assertEq(sp.reservedTotal(), 100);
        assertEq(sp.surplusCap(), 0);
        assertEq(sp.reservationOf(ag[0]), 34);
        assertEq(sp.reservationOf(ag[1]), 33);
        assertEq(sp.reservationOf(ag[2]), 33);
        assertTrue(_pay(sp, ag[0], 34));
        assertFalse(_pay(sp, ag[0], 1));

        SpendPartition sp2 = _deploy(ag, 101, 1, 1);
        assertEq(sp2.surplusCap(), 0);
        assertEq(sp2.reservationOf(ag[0]), 34);
        assertEq(sp2.reservationOf(ag[1]), 34);
        assertEq(sp2.reservationOf(ag[2]), 33);
    }

    /// T7: rho = 0 gives R = 0, all r_i = 0, S = B_G; one agent can consume B_G.
    function test_T7_SharedPoolEndpoint() public {
        address[] memory ag = _agents(3);
        SpendPartition sp = _deploy(ag, 1000, 0, 1);
        assertEq(sp.reservedTotal(), 0);
        assertEq(sp.surplusCap(), 1000);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(sp.reservationOf(ag[i]), 0);
        }
        assertTrue(_pay(sp, ag[2], 1000));
        assertEq(_sumSpent(sp, ag), 1000);
    }

    // =====================================================================
    // T12 — ordering redistributes capacity but never breaks I1
    // =====================================================================

    /// Primary case: N = 3, B_G = 100, rho = 0; requests A = 60, B = 60, C = 40; all 3! orderings.
    function test_T12_Primary_AllOrderings() public {
        address[] memory ag = _agents(3);
        uint256[3] memory req = [uint256(60), 60, 40];
        uint8[3][6] memory orders =
            [[uint8(0), 1, 2], [uint8(0), 2, 1], [uint8(1), 0, 2], [uint8(1), 2, 0], [uint8(2), 0, 1], [uint8(2), 1, 0]];

        bool seen60_0_40;
        bool seen0_60_40;
        for (uint256 k = 0; k < 6; ++k) {
            SpendPartition sp = _deploy(ag, 100, 0, 1);
            for (uint256 j = 0; j < 3; ++j) {
                uint8 who = orders[k][j];
                _pay(sp, ag[who], req[who]);
            }
            uint256 a = sp.spentOf(ag[0]);
            uint256 b = sp.spentOf(ag[1]);
            uint256 c = sp.spentOf(ag[2]);

            assertEq(a + b + c, 100);
            assertEq(sp.surplusUsed(), 100);

            if (a == 60 && b == 0 && c == 40) seen60_0_40 = true;
            else if (a == 0 && b == 60 && c == 40) seen0_60_40 = true;
            else revert("grant vector outside {(60,0,40),(0,60,40)}");
        }
        assertTrue(seen60_0_40 && seen0_60_40);
    }

    /// Secondary case: N = 3, B_G = 100, rho = 3/10 -> R = 30, r_i = 10, S = 70; each requests 40.
    /// Appendix A.2 trace for ordering A -> B -> C.
    function test_T12_Secondary_AtomicGranularityStrands() public {
        address[] memory ag = _agents(3);
        SpendPartition sp = _deploy(ag, 100, 3, 10);
        assertEq(sp.reservedTotal(), 30);
        assertEq(sp.surplusCap(), 70);

        _step(sp, ag[0], 40, true, 40, 30);
        _step(sp, ag[1], 40, true, 40, 60);
        _step(sp, ag[2], 40, false, 0, 60);

        uint256 total = _sumSpent(sp, ag);
        assertEq(total, 80);
        assertEq(sp.budget() - total, 20); // stranded
    }

    // =====================================================================
    // T13 — protected reservation cannot be encroached (Appendix A.3)
    // N = 2, B_G = 100, rho = 1/2 -> R = 50, r_A = r_B = 25, S = 50
    // =====================================================================

    function test_T13_Variant1_SingleMaximalSpend() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 1, 2);
        assertEq(sp.reservationOf(ag[0]), 25);
        assertEq(sp.surplusCap(), 50);

        _step(sp, ag[0], 76, false, 0, 0); // step 0
        _step(sp, ag[0], 75, true, 75, 50); // step 1
        _step(sp, ag[0], 1, false, 75, 50); // step 2
        _step(sp, ag[1], 25, true, 25, 50); // step 3
        _step(sp, ag[1], 1, false, 25, 50); // step 4

        assertEq(_sumSpent(sp, ag), 100);
    }

    function test_T13_Variant2_BoundaryStraddling() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 1, 2);

        _step(sp, ag[0], 40, true, 40, 15); // straddles: fromRes = 25, fromSur = 15
        _step(sp, ag[0], 35, true, 75, 50);
        _step(sp, ag[0], 1, false, 75, 50);
        _step(sp, ag[1], 25, true, 25, 50);
        _step(sp, ag[1], 1, false, 25, 50);

        assertEq(_sumSpent(sp, ag), 100);
    }

    // =====================================================================
    // Window semantics: T5, T9, T11
    // =====================================================================

    function test_T5_T11_ViewsReadZeroAfterRolloverBeforeAnyWrite() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 1, 2);
        assertTrue(_pay(sp, ag[0], 75));
        assertTrue(_pay(sp, ag[1], 25));

        vm.warp(block.timestamp + WINDOW);
        assertEq(sp.currentWindowId(), 1);

        // Physical storage still holds window-0 values ...
        (, uint48 wA, uint192 rawA) = _rawAgent(sp, ag[0]);
        (uint48 wS, uint208 rawS) = _rawSurplus(sp);
        assertEq(wA, 0);
        assertEq(rawA, 75);
        assertEq(wS, 0);
        assertEq(rawS, 50);

        // ... and every public view returns the effective window-1 value.
        assertEq(sp.spentOf(ag[0]), 0);
        assertEq(sp.spentOf(ag[1]), 0);
        assertEq(sp.surplusUsed(), 0);
    }

    function test_T9_LazyResetAfterIdleWindows() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 1, 2);
        assertTrue(_pay(sp, ag[0], 75));
        assertTrue(_pay(sp, ag[1], 10));
        (,, uint192 rawBBefore) = _rawAgent(sp, ag[1]);
        (, uint48 wBBefore,) = _rawAgent(sp, ag[1]);

        vm.warp(block.timestamp + 5 * WINDOW); // idle through windows 1..4, transact in window 5
        assertTrue(_pay(sp, ag[0], 75)); // full r_A + S available again

        (, uint48 wA, uint192 rawA) = _rawAgent(sp, ag[0]);
        assertEq(wA, 5);
        assertEq(rawA, 75);

        (, uint48 wBAfter, uint192 rawBAfter) = _rawAgent(sp, ag[1]); // not touched
        assertEq(wBAfter, wBBefore);
        assertEq(rawBAfter, rawBBefore);
    }

    // =====================================================================
    // T16 — revert atomicity, including a failing first access in a new window
    // =====================================================================

    function test_T16_RejectedPaymentLeavesStateUnchanged() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 1, 2);
        assertTrue(_pay(sp, ag[0], 75));

        vm.warp(block.timestamp + WINDOW); // next call by A is its first access in window 1

        bytes32 agentBefore = vm.load(address(sp), _agentKey(ag[0]));
        bytes32 surplusBefore = vm.load(address(sp), SURPLUS_SLOT);
        uint256 merchantBefore = usdc.balanceOf(MERCHANT);

        vm.expectRevert(abi.encodeWithSelector(SpendPartition.SurplusExhausted.selector, 51, 50));
        vm.prank(ag[0]);
        sp.pay(MERCHANT, 76);

        assertEq(vm.load(address(sp), _agentKey(ag[0])), agentBefore);
        assertEq(vm.load(address(sp), SURPLUS_SLOT), surplusBefore);
        assertEq(usdc.balanceOf(MERCHANT), merchantBefore);
    }

    // =====================================================================
    // T17 — boundary arithmetic
    // =====================================================================

    function test_T17_Boundaries() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 1, 2); // r = 25, S = 50

        vm.startPrank(ag[0]);
        vm.expectRevert(SpendPartition.InvalidAmount.selector);
        sp.pay(MERCHANT, 0);
        vm.expectRevert(SpendPartition.InvalidAmount.selector);
        sp.pay(MERCHANT, type(uint256).max);
        vm.expectRevert(SpendPartition.InvalidAmount.selector);
        sp.pay(MERCHANT, 101);
        vm.stopPrank();

        assertTrue(_pay(sp, ag[0], 25)); // exactly ownRemaining
        assertEq(sp.surplusUsed(), 0);
        assertTrue(_pay(sp, ag[0], 1)); // spent at r_i, one more unit routes to surplus
        assertEq(sp.surplusUsed(), 1);

        vm.expectRevert(abi.encodeWithSelector(SpendPartition.NotAgent.selector, address(this)));
        sp.pay(MERCHANT, 1);
    }

    function test_T17_MaximumSupportedBudget() public {
        address[] memory ag = _agents(2);
        uint256 maxBudget = type(uint192).max;
        SpendPartition sp = new SpendPartition(usdcAsToken(), ag, maxBudget, 0, 1, WINDOW);
        usdc.mint(address(sp), maxBudget);
        assertTrue(_pay(sp, ag[0], maxBudget));
        assertEq(sp.spentOf(ag[0]), maxBudget);
        assertFalse(_pay(sp, ag[1], 1));
    }

    function test_ConstructorRejectsInvalidConfig() public {
        address[] memory ag = _agents(2);
        vm.expectRevert(SpendPartition.InvalidConfig.selector);
        new SpendPartition(usdcAsToken(), ag, 0, 1, 2, WINDOW); // B_G = 0
        vm.expectRevert(SpendPartition.InvalidConfig.selector);
        new SpendPartition(usdcAsToken(), ag, uint256(type(uint192).max) + 1, 1, 2, WINDOW); // A3
        vm.expectRevert(SpendPartition.InvalidConfig.selector);
        new SpendPartition(usdcAsToken(), ag, 100, 1, 0, WINDOW); // rho_den = 0
        vm.expectRevert(SpendPartition.InvalidConfig.selector);
        new SpendPartition(usdcAsToken(), ag, 100, 3, 2, WINDOW); // rho_num > rho_den
        vm.expectRevert(SpendPartition.InvalidConfig.selector);
        new SpendPartition(usdcAsToken(), ag, 100, 1, uint256(type(uint32).max) + 1, WINDOW); // A4
        vm.expectRevert(SpendPartition.InvalidConfig.selector);
        new SpendPartition(usdcAsToken(), ag, 100, 1, 2, 0); // Delta = 0

        address[] memory dup = new address[](2);
        dup[0] = address(0xA000);
        dup[1] = address(0xA000);
        vm.expectRevert(abi.encodeWithSelector(SpendPartition.DuplicateAgent.selector, address(0xA000)));
        new SpendPartition(usdcAsToken(), dup, 100, 1, 2, WINDOW);

        address[] memory zero = new address[](1);
        vm.expectRevert(SpendPartition.ZeroAddress.selector);
        new SpendPartition(usdcAsToken(), zero, 100, 1, 2, WINDOW);
    }

    // =====================================================================
    // Layout v1.1 checks: packing, G1/G2, touched slots per payment (H3)
    // =====================================================================

    function test_Layout_AgentSlotPackingRoundTrip() public {
        address[] memory ag = _agents(3);
        SpendPartition sp = _deploy(ag, 1000, 1, 2);
        vm.warp(block.timestamp + 3 * WINDOW);
        assertTrue(_pay(sp, ag[2], 123));

        (uint16 idxp1, uint48 w, uint192 spent) = _rawAgent(sp, ag[2]);
        assertEq(idxp1, 3);
        assertEq(w, 3);
        assertEq(spent, 123);
        assertEq(sp.indexOf(ag[2]), 2);
    }

    /// rho = 1: an accepted payment writes only the payer's agent slot; the surplus slot stays zero.
    function test_Layout_Rho1_SurplusSlotNeverWritten() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 1, 1);

        vm.record();
        assertTrue(_pay(sp, ag[0], 50));
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(sp));

        assertEq(_count(writes, _agentKey(ag[0])), 1);
        assertEq(_count(writes, SURPLUS_SLOT), 0);
        assertEq(_count(reads, SURPLUS_SLOT), 0); // G2: not read either
        assertEq(vm.load(address(sp), SURPLUS_SLOT), bytes32(0));
    }

    /// rho = 0: an accepted payment writes the payer's agent slot and the surplus slot, once each.
    function test_Layout_Rho0_TwoSlotsWrittenOnceEach() public {
        address[] memory ag = _agents(2);
        SpendPartition sp = _deploy(ag, 100, 0, 1);

        vm.record();
        assertTrue(_pay(sp, ag[0], 40));
        (, bytes32[] memory writes) = vm.accesses(address(sp));

        assertEq(_count(writes, _agentKey(ag[0])), 1);
        assertEq(_count(writes, SURPLUS_SLOT), 1);
    }

    // =====================================================================
    // helpers
    // =====================================================================

    /// One trace row: agent pays `amount`; asserts accept/reject and effective values after the call.
    function _step(
        SpendPartition sp,
        address agent,
        uint256 amount,
        bool expectAccept,
        uint256 spentAfter,
        uint256 surplusUsedAfter
    ) internal {
        assertEq(_pay(sp, agent, amount), expectAccept, "accept/reject");
        assertEq(sp.spentOf(agent), spentAfter, "spent after");
        assertEq(sp.surplusUsed(), surplusUsedAfter, "surplusUsed after");
    }

    function _count(bytes32[] memory slots, bytes32 target) internal pure returns (uint256 c) {
        for (uint256 i = 0; i < slots.length; ++i) {
            if (slots[i] == target) ++c;
        }
    }

    function usdcAsToken() internal view returns (IERC20) {
        return IERC20(address(usdc));
    }
}
