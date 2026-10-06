// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {SpendPartitionWeighted} from "../src/SpendPartitionWeighted.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// P1-P6 against mathematical consequences, with no weighted reference or Hamilton ranking oracle.
/// N<=8 bounds constructor O(N^2) cost. Small integer budgets/weights exercise rounding and ties;
/// the existing fixed scenarios retain maximum-budget/full-precision coverage.
/// Uses the unchanged global fuzz runs and seed. No assumptions or per-test run overrides.
contract WeightedFuzzTest is Test {
    uint256 private constant MAX_N = 8;
    uint256 private constant MAX_VALUE = 1_000_000;
    uint256 private constant WINDOW = 7 days;
    address private constant MERCHANT = address(0xBEEF);
    MockUSDC private token;

    struct Input {
        uint256[8] weights;
        uint256 n;
        uint256 budget;
        uint256 rhoNum;
        uint256 rhoDen;
        uint256 order;
        uint256 selected;
        uint256 change;
        uint256 zeroCount;
        uint256 amount;
    }

    struct Config {
        address[] agents;
        uint256[] weights;
        uint256 budget;
        uint256 rhoNum;
        uint256 rhoDen;
    }

    function setUp() public {
        token = new MockUSDC();
    }

    function _configuration(Input memory raw, uint256 minN) private pure returns (Config memory c) {
        uint256 n = bound(raw.n, minN, MAX_N);
        c.budget = bound(raw.budget, 1, MAX_VALUE);
        c.rhoDen = bound(raw.rhoDen, 1, 1000);
        c.rhoNum = bound(raw.rhoNum, 0, c.rhoDen);
        c.agents = new address[](n);
        c.weights = new uint256[](n);
        uint256 rotation = bound(raw.order, 0, n - 1);
        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            // Distinct nonzero addresses, with randomized registration order.
            c.agents[i] = address(uint160(0xA000 + (i + rotation) % n));
            c.weights[i] = bound(raw.weights[i], 0, MAX_VALUE);
            total += c.weights[i];
        }
        // Construct validity rather than reject all-zero samples. Other zero weights remain.
        if (total == 0) c.weights[0] = 1;
    }

    function _deploy(Config memory c) private returns (SpendPartitionWeighted) {
        return new SpendPartitionWeighted(token, c.agents, c.weights, c.budget, c.rhoNum, c.rhoDen, WINDOW);
    }

    /// P1: Conservation, plus the defining floor inequality for R, independent of allocation logic.
    function testFuzz_P1_ExactConservation(Input memory raw) public {
        Config memory c = _configuration(raw, 1);
        SpendPartitionWeighted sp = _deploy(c);
        uint256 r = sp.reservedTotal();
        // Products fit under this bounded domain. These inequalities uniquely characterize R.
        assertLe(r * c.rhoDen, c.budget * c.rhoNum, "R lower inequality");
        assertLt(c.budget * c.rhoNum, (r + 1) * c.rhoDen, "R upper inequality");
        uint256 sum;
        for (uint256 i = 0; i < c.agents.length; ++i) {
            sum += sp.reservationOf(c.agents[i]);
        }
        assertEq(sum, r, "P1 reservation conservation");
        assertEq(sp.surplusCap(), c.budget - r);
    }

    /// P2: Only floor/ceil quota bounds; no ranking, sorting, or leftover assignment oracle.
    function testFuzz_P2_QuotaBounds(Input memory raw) public {
        Config memory c = _configuration(raw, 1);
        SpendPartitionWeighted sp = _deploy(c);
        uint256 totalWeight;
        for (uint256 i = 0; i < c.weights.length; ++i) {
            totalWeight += c.weights[i];
        }
        uint256 r = Math.mulDiv(c.budget, c.rhoNum, c.rhoDen);
        assertEq(sp.reservedTotal(), r);
        for (uint256 i = 0; i < c.weights.length; ++i) {
            uint256 quotaFloor = Math.mulDiv(r, c.weights[i], totalWeight);
            uint256 quotaCeil = quotaFloor + (mulmod(r, c.weights[i], totalWeight) == 0 ? 0 : 1);
            uint256 reservation = sp.reservationOf(c.agents[i]);
            assertGe(reservation, quotaFloor, "P2 below floor");
            assertLe(reservation, quotaCeil, "P2 above ceiling");
        }
    }

    /// P3: Compare equal positive weights to the untouched baseline equal-split implementation.
    function testFuzz_P3_EqualWeightCompatibility(Input memory raw) public {
        Config memory c = _configuration(raw, 1);
        uint256 commonWeight = bound(raw.change, 1, MAX_VALUE);
        for (uint256 i = 0; i < c.weights.length; ++i) {
            c.weights[i] = commonWeight;
        }
        SpendPartition baseline = new SpendPartition(token, c.agents, c.budget, c.rhoNum, c.rhoDen, WINDOW);
        SpendPartitionWeighted weighted = _deploy(c);
        assertEq(weighted.reservedTotal(), baseline.reservedTotal());
        assertEq(weighted.surplusCap(), baseline.surplusCap());
        for (uint256 i = 0; i < c.agents.length; ++i) {
            assertEq(weighted.reservationOf(c.agents[i]), baseline.reservationOf(c.agents[i]), "P3 equal split");
        }
    }

    /// P4: Identical ordered configurations deployed independently give identical allocations.
    function testFuzz_P4_Determinism(Input memory raw) public {
        Config memory c = _configuration(raw, 1);
        SpendPartitionWeighted first = _deploy(c);
        SpendPartitionWeighted second = _deploy(c);
        assertEq(first.reservedTotal(), second.reservedTotal());
        assertEq(first.surplusCap(), second.surplusCap());
        uint256 sumFirst;
        uint256 sumSecond;
        for (uint256 i = 0; i < c.agents.length; ++i) {
            uint256 a = first.reservationOf(c.agents[i]);
            uint256 b = second.reservationOf(c.agents[i]);
            assertEq(a, b, "P4 reservation vector");
            sumFirst += a;
            sumSecond += b;
        }
        assertEq(sumFirst, sumSecond);
        assertEq(sumFirst, first.reservedTotal());
    }

    /// P5: Force one or more zero weights, keep a positive total, and exercise surplus every run.
    function testFuzz_P5_ZeroWeightCanSpendSurplus(Input memory raw) public {
        Config memory c = _configuration(raw, 2);
        uint256 n = c.agents.length;
        uint256 zeroIndex = bound(raw.selected, 0, n - 1);
        uint256 zeroCount = bound(raw.zeroCount, 1, n - 1);
        for (uint256 j = 0; j < zeroCount; ++j) {
            c.weights[(zeroIndex + j) % n] = 0;
        }
        uint256 positiveIndex = (zeroIndex + zeroCount) % n;
        c.weights[positiveIndex] = bound(raw.weights[positiveIndex], 1, MAX_VALUE);
        // Strictly subunit rho guarantees a positive surplus even when B=1.
        c.rhoNum = bound(raw.rhoNum, 0, c.rhoDen - 1);
        SpendPartitionWeighted sp = _deploy(c);
        _assertZeroReservations(sp, c);
        assertTrue(sp.isAgent(c.agents[zeroIndex]));
        assertGt(sp.surplusCap(), 0);
        token.mint(address(sp), c.budget);
        uint256 amount = bound(raw.amount, 1, sp.surplusCap());
        vm.prank(c.agents[zeroIndex]);
        sp.pay(MERCHANT, amount);
        assertEq(sp.spentOf(c.agents[zeroIndex]), amount);
        assertEq(sp.surplusUsed(), amount, "P5 entire payment from surplus");
        assertEq(token.balanceOf(MERCHANT), amount);
        _assertZeroReservations(sp, c);
    }

    function _assertZeroReservations(SpendPartitionWeighted sp, Config memory c) private view {
        for (uint256 i = 0; i < c.weights.length; ++i) {
            if (c.weights[i] == 0) assertEq(sp.reservationOf(c.agents[i]), 0, "P5 zero protected reservation");
        }
    }

    /// P6: Single-coordinate own-weight test, not a claim about population or house-size stability.
    /// Only the selected weight increases; R, all other weights, and agent order stay fixed.
    function testFuzz_P6_OwnWeightMonotonicity(Input memory raw) public {
        Config memory c = _configuration(raw, 1);
        uint256 selected = bound(raw.selected, 0, c.agents.length - 1);
        SpendPartitionWeighted beforeIncrease = _deploy(c);
        uint256 previousReservation = beforeIncrease.reservationOf(c.agents[selected]);
        uint256 oldWeight = c.weights[selected];
        uint256 increment = bound(raw.change, 1, MAX_VALUE);
        c.weights[selected] += increment; // At most 2e6; total weight remains valid without rejection.
        SpendPartitionWeighted afterIncrease = _deploy(c);
        assertEq(beforeIncrease.reservedTotal(), afterIncrease.reservedTotal(), "P6 fixed R");
        assertEq(beforeIncrease.surplusCap(), afterIncrease.surplusCap());
        uint256 nextReservation = afterIncrease.reservationOf(c.agents[selected]);
        if (nextReservation < previousReservation) {
            // Log the normalized valid case for reproduction if Foundry discovers a counterexample.
            emit log_named_uint("R", beforeIncrease.reservedTotal());
            emit log_named_uint("selected index", selected);
            emit log_named_uint("old selected weight", oldWeight);
            emit log_named_uint("positive increment", increment);
            emit log_named_uint("reservation before", previousReservation);
            emit log_named_uint("reservation after", nextReservation);
            emit log_named_array("weights after increase", c.weights);
        }
        assertGe(nextReservation, previousReservation, "P6 own reservation decreased");
    }
}
