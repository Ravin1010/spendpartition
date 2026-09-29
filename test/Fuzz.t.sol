// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SPBase} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract FuzzTest is SPBase {
    function setUp() public {
        usdc = new MockUSDC();
    }

    /// T8 — integer apportionment. The oracle checks R against its defining inequality
    /// (Layout v1.1 Part 4) and never recomputes R or r_i with the contract's arithmetic.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_T8_Apportionment(uint256 budget, uint256 rhoNum, uint256 rhoDen, uint256 n) public {
        n = bound(n, 1, 64);
        rhoDen = bound(rhoDen, 1, type(uint32).max);
        rhoNum = bound(rhoNum, 0, rhoDen);
        budget = bound(budget, 1, type(uint192).max);

        address[] memory ag = _agents(n);
        SpendPartition sp = new SpendPartition(IERC20(address(usdc)), ag, budget, rhoNum, rhoDen, WINDOW);
        uint256 R = sp.reservedTotal();

        assertLe(R * rhoDen, budget * rhoNum);
        assertLt(budget * rhoNum, (R + 1) * rhoDen);
        assertEq(sp.surplusCap(), budget - R);
        if (rhoNum == 0) assertEq(R, 0); // one direction only
        if (rhoNum == rhoDen) assertEq(R, budget);

        uint256 sum;
        uint256 mx;
        uint256 mn = type(uint256).max;
        uint256 prev = type(uint256).max;
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = sp.reservationOf(ag[i]);
            assertEq(sp.reservationOf(ag[i]), r); // determinism
            assertLe(r, prev); // non-increasing in idx
            prev = r;
            sum += r;
            if (r > mx) mx = r;
            if (r < mn) mn = r;
        }
        assertEq(sum, R);
        assertLe(mx - mn, 1);
    }

    /// T8 fixed case: rho_num != 0 does not imply R != 0.
    function test_T8_NonzeroRhoCanFloorToZero() public {
        SpendPartition sp = new SpendPartition(IERC20(address(usdc)), _agents(2), 100, 1, 1000, WINDOW);
        assertEq(sp.reservedTotal(), 0);
        assertEq(sp.surplusCap(), 100);
    }

    /// T18 — debit-order transition, with ownRemaining evaluated before the call.
    struct T18Input {
        uint256 n;
        uint256 budget;
        uint256 rhoNum;
        uint256 rhoDen;
        uint256 whoSeed;
        uint256 otherSeed;
        uint256 preSelf;
        uint256 preOther;
        uint256 a;
    }

    function testFuzz_T18_DebitOrderTransition(T18Input memory in_) public {
        in_.n = bound(in_.n, 2, 10);
        in_.rhoDen = bound(in_.rhoDen, 1, 1000);
        in_.rhoNum = bound(in_.rhoNum, 0, in_.rhoDen);
        in_.budget = bound(in_.budget, 1, 1e18);

        address[] memory ag = _agents(in_.n);
        SpendPartition sp = _deploy(ag, in_.budget, in_.rhoNum, in_.rhoDen);
        address x = ag[bound(in_.whoSeed, 0, in_.n - 1)];

        // Arbitrary prior history by another delegate and by x; either call may be rejected.
        _pay(sp, ag[bound(in_.otherSeed, 0, in_.n - 1)], bound(in_.preOther, 1, in_.budget));
        _pay(sp, x, bound(in_.preSelf, 1, in_.budget));

        _checkTransition(sp, x, bound(in_.a, 1, in_.budget));
    }

    function _checkTransition(SpendPartition sp, address x, uint256 a) internal {
        uint256 spent0 = sp.spentOf(x);
        uint256 used0 = sp.surplusUsed();
        uint256 r = sp.reservationOf(x);
        uint256 ownRemaining = r > spent0 ? r - spent0 : 0;

        bool ok = _pay(sp, x, a);

        if (ok) {
            assertEq(sp.spentOf(x) - spent0, a);
            if (a <= ownRemaining) assertEq(sp.surplusUsed(), used0);
            else assertEq(sp.surplusUsed() - used0, a - ownRemaining);
        } else {
            assertEq(sp.spentOf(x), spent0);
            assertEq(sp.surplusUsed(), used0);
            assertGt(a, ownRemaining, "I2: request within own remaining reservation was rejected");
            assertGt(a - ownRemaining, sp.surplusCap() - used0); // rejected only when the spill exceeds what is left
        }
    }
}
