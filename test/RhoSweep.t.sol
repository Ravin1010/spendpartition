// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SPBase} from "./Base.t.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Measurement only (Test Plan v1.1 T14): no assertion about how outcomes vary with rho.
///
/// Workload (engineering choice, not derived from the spec): N = 3, B_G = 100, one window.
/// Delegate A (idx 0) submits 10 requests of 10 first; then B (idx 1) submits 3 requests of 10;
/// then C (idx 2) submits 3 requests of 10. Aggregate demand 160 > B_G.
/// rho = k/10 for k = 0..10. Output: results/rho_sweep.csv.
contract RhoSweepTest is SPBase {
    string internal constant OUT = "results/rho_sweep.csv";
    uint256 internal constant B_G = 100;
    uint256 internal constant REQ = 10;

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_T14_RhoSweep() public {
        address[] memory ag = _agents(3);
        uint256[3] memory nRequests = [uint256(10), 3, 3];
        string[3] memory label = ["A", "B", "C"];
        string[3] memory role = ["first_mover", "later", "later"];

        vm.createDir("results", true);
        vm.writeFile(OUT, "rho_num,rho_den,agent,role,reservation,demanded,granted,rejected_requests\n");

        for (uint256 k = 0; k <= 10; ++k) {
            SpendPartition sp = _deploy(ag, B_G, k, 10);
            uint256[3] memory granted;
            uint256[3] memory rejectedRequests;

            for (uint256 who = 0; who < 3; ++who) {
                for (uint256 j = 0; j < nRequests[who]; ++j) {
                    uint256 s = sp.spentOf(ag[who]);
                    uint256 r = sp.reservationOf(ag[who]);
                    uint256 ownRemaining = r > s ? r - s : 0;
                    if (_pay(sp, ag[who], REQ)) {
                        granted[who] += REQ;
                    } else {
                        ++rejectedRequests[who];
                        assertGt(REQ, ownRemaining, "T14: rejected request was within own remaining reservation");
                    }
                }
            }
            assertLe(granted[0] + granted[1] + granted[2], B_G, "I1");

            for (uint256 who = 0; who < 3; ++who) {
                _writeRow(k, label[who], role[who], sp.reservationOf(ag[who]), nRequests[who] * REQ, granted[who], rejectedRequests[who]);
            }
        }
    }

    function _writeRow(
        uint256 k,
        string memory agent,
        string memory role,
        uint256 reservation,
        uint256 demanded,
        uint256 granted,
        uint256 rejectedRequests
    ) internal {
        string memory head = string.concat(vm.toString(k), ",10,", agent, ",", role, ",");
        string memory tail = string.concat(
            vm.toString(reservation), ",", vm.toString(demanded), ",", vm.toString(granted), ",", vm.toString(rejectedRequests)
        );
        vm.writeLine(OUT, string.concat(head, tail));
    }
}
