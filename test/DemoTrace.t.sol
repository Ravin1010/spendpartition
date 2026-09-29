// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SPBase} from "./Base.t.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Exports the demo trace to results/demo_trace.csv. Every row is produced by calling the real
/// contract, so the dashboard renders measured behaviour rather than a second implementation of the
/// rules in the front end.
///
/// One row per request, with the state read back after the call:
///   act, rho_num, rho_den, budget, step, agent, requested, accepted, spent_a, spent_b, surplus_used, aggregate
contract DemoTraceTest is SPBase {
    string internal constant OUT = "results/demo_trace.csv";

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_ExportDemoTrace() public {
        vm.createDir("results", true);
        vm.writeFile(
            OUT, "act,rho_num,rho_den,budget,step,agent,requested,accepted,spent_a,spent_b,surplus_used,aggregate\n"
        );

        address[] memory ag = _agents(2);

        // Act 1: two per-delegation caps of 80 while the principal intends 100 in aggregate.
        SpendPartition act1 = _deploy(ag, 160, 1, 1);
        _record(1, act1, ag, 0, 0, 80, 1, 1);
        _record(1, act1, ag, 1, 1, 80, 1, 1);

        // Act 2: a static split of the intended 100 refuses a request the aggregate could serve.
        SpendPartition act2 = _deploy(ag, 100, 1, 1);
        _record(2, act2, ag, 0, 0, 80, 1, 1);
        _record(2, act2, ag, 1, 0, 50, 1, 1);

        // Act 3: the same request against a shared pool.
        SpendPartition act3 = _deploy(ag, 100, 0, 1);
        _record(3, act3, ag, 0, 0, 80, 0, 1);

        // Act 4: a first mover takes the whole pool and the other delegate is left with nothing.
        SpendPartition act4 = _deploy(ag, 100, 0, 1);
        _record(4, act4, ag, 0, 0, 100, 0, 1);
        _record(4, act4, ag, 1, 1, 20, 0, 1);

        // Act 5: with rho = 1/2 the same first mover is capped and the second delegate's
        // reservation is still there.
        SpendPartition act5 = _deploy(ag, 100, 1, 2);
        _record(5, act5, ag, 0, 0, 76, 1, 2);
        _record(5, act5, ag, 1, 0, 75, 1, 2);
        _record(5, act5, ag, 2, 1, 25, 1, 2);

        // Act 6: the rho sweep of test/RhoSweep.t.sol, which writes results/rho_sweep.csv.
    }

    struct Row {
        uint256 act;
        uint256 rhoNum;
        uint256 rhoDen;
        uint256 budget;
        uint256 step;
        string agent;
        uint256 requested;
        bool accepted;
        uint256 spentA;
        uint256 spentB;
        uint256 surplusUsed;
    }

    /// Sends one request and appends the resulting state.
    function _record(
        uint256 act,
        SpendPartition sp,
        address[] memory ag,
        uint256 step,
        uint256 who,
        uint256 amount,
        uint256 rhoNum,
        uint256 rhoDen
    ) internal {
        Row memory r;
        r.act = act;
        r.rhoNum = rhoNum;
        r.rhoDen = rhoDen;
        r.budget = sp.budget();
        r.step = step;
        r.agent = who == 0 ? "A" : "B";
        r.requested = amount;
        r.accepted = _pay(sp, ag[who], amount);
        r.spentA = sp.spentOf(ag[0]);
        r.spentB = sp.spentOf(ag[1]);
        r.surplusUsed = sp.surplusUsed();
        _writeRow(r);
    }

    function _writeRow(Row memory r) internal {
        string memory head = string.concat(
            vm.toString(r.act), ",", vm.toString(r.rhoNum), ",", vm.toString(r.rhoDen), ",", vm.toString(r.budget), ","
        );
        string memory mid =
            string.concat(vm.toString(r.step), ",", r.agent, ",", vm.toString(r.requested), ",", r.accepted ? "1" : "0", ",");
        string memory tail = string.concat(
            vm.toString(r.spentA),
            ",",
            vm.toString(r.spentB),
            ",",
            vm.toString(r.surplusUsed),
            ",",
            vm.toString(r.spentA + r.spentB)
        );
        vm.writeLine(OUT, string.concat(head, mid, tail));
    }
}
