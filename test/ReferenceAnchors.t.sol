// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpendPartitionReference} from "../src/SpendPartitionReference.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// The same anchors the optimised contract is held to, replayed against the reference
/// implementation: T6, T7, T12 (both cases), T13 (both appendix variants), T5/T11, T9, T17.
/// Expected values are the hand-computed ones in Property-Test Plan v1.1, Appendix A.
contract ReferenceAnchorsTest is Test {
    MockUSDC internal usdc;

    address internal constant MERCHANT = address(0xBEEF);
    uint256 internal constant WINDOW = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
    }

    function _agents(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = address(uint160(0xA000 + i));
        }
    }

    function _deploy(address[] memory ag, uint256 budget, uint256 rhoNum, uint256 rhoDen)
        internal
        returns (SpendPartitionReference sp)
    {
        sp = new SpendPartitionReference(IERC20(address(usdc)), ag, budget, rhoNum, rhoDen, WINDOW);
        usdc.mint(address(sp), budget * 64);
    }

    function _pay(SpendPartitionReference sp, address agent, uint256 amount) internal returns (bool ok) {
        vm.prank(agent);
        try sp.pay(MERCHANT, amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _step(
        SpendPartitionReference sp,
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

    function _sumSpent(SpendPartitionReference sp, address[] memory ag) internal view returns (uint256 s) {
        for (uint256 i = 0; i < ag.length; ++i) {
            s += sp.spentOf(ag[i]);
        }
    }

    // T6
    function test_Ref_T6_StaticPartitionApportionment() public {
        address[] memory ag = _agents(3);

        SpendPartitionReference sp = _deploy(ag, 100, 1, 1);
        assertEq(sp.reservedTotal(), 100);
        assertEq(sp.surplusCap(), 0);
        assertEq(sp.reservationOf(ag[0]), 34);
        assertEq(sp.reservationOf(ag[1]), 33);
        assertEq(sp.reservationOf(ag[2]), 33);
        assertTrue(_pay(sp, ag[0], 34));
        assertFalse(_pay(sp, ag[0], 1));

        SpendPartitionReference sp2 = _deploy(ag, 101, 1, 1);
        assertEq(sp2.reservationOf(ag[0]), 34);
        assertEq(sp2.reservationOf(ag[1]), 34);
        assertEq(sp2.reservationOf(ag[2]), 33);
    }

    // T7
    function test_Ref_T7_SharedPoolEndpoint() public {
        address[] memory ag = _agents(3);
        SpendPartitionReference sp = _deploy(ag, 1000, 0, 1);
        assertEq(sp.reservedTotal(), 0);
        assertEq(sp.surplusCap(), 1000);
        assertTrue(_pay(sp, ag[2], 1000));
        assertEq(_sumSpent(sp, ag), 1000);
    }

    // T12 primary
    function test_Ref_T12_Primary_AllOrderings() public {
        address[] memory ag = _agents(3);
        uint256[3] memory req = [uint256(60), 60, 40];
        uint8[3][6] memory orders =
            [[uint8(0), 1, 2], [uint8(0), 2, 1], [uint8(1), 0, 2], [uint8(1), 2, 0], [uint8(2), 0, 1], [uint8(2), 1, 0]];

        bool seen60_0_40;
        bool seen0_60_40;
        for (uint256 k = 0; k < 6; ++k) {
            SpendPartitionReference sp = _deploy(ag, 100, 0, 1);
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

    // T12 secondary, Appendix A.2 trace
    function test_Ref_T12_Secondary_AtomicGranularityStrands() public {
        address[] memory ag = _agents(3);
        SpendPartitionReference sp = _deploy(ag, 100, 3, 10);
        assertEq(sp.reservedTotal(), 30);
        assertEq(sp.surplusCap(), 70);

        _step(sp, ag[0], 40, true, 40, 30);
        _step(sp, ag[1], 40, true, 40, 60);
        _step(sp, ag[2], 40, false, 0, 60);

        assertEq(_sumSpent(sp, ag), 80);
    }

    // T13, Appendix A.3
    function test_Ref_T13_Variant1_SingleMaximalSpend() public {
        address[] memory ag = _agents(2);
        SpendPartitionReference sp = _deploy(ag, 100, 1, 2);
        assertEq(sp.reservationOf(ag[0]), 25);
        assertEq(sp.surplusCap(), 50);

        _step(sp, ag[0], 76, false, 0, 0);
        _step(sp, ag[0], 75, true, 75, 50);
        _step(sp, ag[0], 1, false, 75, 50);
        _step(sp, ag[1], 25, true, 25, 50);
        _step(sp, ag[1], 1, false, 25, 50);

        assertEq(_sumSpent(sp, ag), 100);
    }

    function test_Ref_T13_Variant2_BoundaryStraddling() public {
        address[] memory ag = _agents(2);
        SpendPartitionReference sp = _deploy(ag, 100, 1, 2);

        _step(sp, ag[0], 40, true, 40, 15);
        _step(sp, ag[0], 35, true, 75, 50);
        _step(sp, ag[0], 1, false, 75, 50);
        _step(sp, ag[1], 25, true, 25, 50);
        _step(sp, ag[1], 1, false, 25, 50);

        assertEq(_sumSpent(sp, ag), 100);
    }

    // T5 / T11
    function test_Ref_T5_T11_ViewsReadZeroAfterRollover() public {
        address[] memory ag = _agents(2);
        SpendPartitionReference sp = _deploy(ag, 100, 1, 2);
        assertTrue(_pay(sp, ag[0], 75));
        assertTrue(_pay(sp, ag[1], 25));

        vm.warp(vm.getBlockTimestamp() + WINDOW);
        assertEq(sp.currentWindowId(), 1);
        assertEq(sp.spentOf(ag[0]), 0);
        assertEq(sp.spentOf(ag[1]), 0);
        assertEq(sp.surplusUsed(), 0);
    }

    // T9
    function test_Ref_T9_LazyResetAfterIdleWindows() public {
        address[] memory ag = _agents(2);
        SpendPartitionReference sp = _deploy(ag, 100, 1, 2);
        assertTrue(_pay(sp, ag[0], 75));

        vm.warp(vm.getBlockTimestamp() + 5 * WINDOW);
        assertEq(sp.currentWindowId(), 5);
        assertTrue(_pay(sp, ag[0], 75));
        assertEq(sp.spentOf(ag[0]), 75);
    }

    // T17
    function test_Ref_T17_Boundaries() public {
        address[] memory ag = _agents(2);
        SpendPartitionReference sp = _deploy(ag, 100, 1, 2);

        vm.startPrank(ag[0]);
        vm.expectRevert(SpendPartitionReference.InvalidAmount.selector);
        sp.pay(MERCHANT, 0);
        vm.expectRevert(SpendPartitionReference.InvalidAmount.selector);
        sp.pay(MERCHANT, type(uint256).max);
        vm.expectRevert(SpendPartitionReference.InvalidAmount.selector);
        sp.pay(MERCHANT, 101);
        vm.stopPrank();

        assertTrue(_pay(sp, ag[0], 25));
        assertEq(sp.surplusUsed(), 0);
        assertTrue(_pay(sp, ag[0], 1));
        assertEq(sp.surplusUsed(), 1);

        vm.expectRevert(abi.encodeWithSelector(SpendPartitionReference.NotAgent.selector, address(this)));
        sp.pay(MERCHANT, 1);
    }

    function test_Ref_ConstructorRejectsInvalidConfig() public {
        address[] memory ag = _agents(2);
        IERC20 t = IERC20(address(usdc));

        vm.expectRevert(SpendPartitionReference.InvalidConfig.selector);
        new SpendPartitionReference(t, ag, 0, 1, 2, WINDOW);
        vm.expectRevert(SpendPartitionReference.InvalidConfig.selector);
        new SpendPartitionReference(t, ag, 100, 3, 2, WINDOW);
        vm.expectRevert(SpendPartitionReference.InvalidConfig.selector);
        new SpendPartitionReference(t, ag, 100, 1, 2, 0);

        address[] memory dup = new address[](2);
        dup[0] = address(0xA000);
        dup[1] = address(0xA000);
        vm.expectRevert(abi.encodeWithSelector(SpendPartitionReference.DuplicateAgent.selector, address(0xA000)));
        new SpendPartitionReference(t, dup, 100, 1, 2, WINDOW);
    }
}
