// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpendPartition} from "../src/ISpendPartition.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {MutantM1DebitOrder} from "./mutants/MutantM1DebitOrder.sol";
import {MutantM2NoWindowTag} from "./mutants/MutantM2NoWindowTag.sol";
import {MutantM3PartialFill} from "./mutants/MutantM3PartialFill.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Each mutant is the optimised contract with one behaviour changed (see the MUTATION comments in
/// test/mutants/). The checks below are the named properties the suite already tests, rewritten to
/// return a boolean instead of asserting, so that a failure can be recorded rather than abort the
/// run. The test asserts two things: every check holds on the real contract, and no mutant survives
/// all of them. The full matrix is printed.
contract MutationTest is Test {
    MockUSDC internal usdc;

    address internal constant MERCHANT = address(0xBEEF);
    uint256 internal constant WINDOW = 7 days;
    uint256 internal constant N_VARIANTS = 4;
    uint256 internal constant N_CHECKS = 5;

    string[N_VARIANTS] internal variantName =
        ["SpendPartition", "M1 debit order", "M2 no window tag", "M3 partial fill"];
    string[N_CHECKS] internal checkName =
        ["T6 apportionment", "T18 debit order", "T5/T9 window reset", "T12 ordering", "T16 atomicity"];

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_EveryMutantIsKilledByANamedCheck() public {
        bool[N_CHECKS][N_VARIANTS] memory held;

        for (uint256 v = 0; v < N_VARIANTS; ++v) {
            held[v][0] = _checkT6Apportionment(v);
            held[v][1] = _checkT18DebitOrder(v);
            held[v][2] = _checkT5WindowReset(v);
            held[v][3] = _checkT12Ordering(v);
            held[v][4] = _checkT16Atomicity(v);
        }

        console.log("check                 SpendPartition  M1  M2  M3   (1 = property held)");
        for (uint256 c = 0; c < N_CHECKS; ++c) {
            console.log(
                string.concat(
                    _pad(checkName[c], 22),
                    "      ",
                    held[0][c] ? "1" : "0",
                    "         ",
                    held[1][c] ? "1" : "0",
                    "   ",
                    held[2][c] ? "1" : "0",
                    "   ",
                    held[3][c] ? "1" : "0"
                )
            );
        }

        for (uint256 c = 0; c < N_CHECKS; ++c) {
            assertTrue(held[0][c], string.concat("check failed on the real contract: ", checkName[c]));
        }
        for (uint256 v = 1; v < N_VARIANTS; ++v) {
            bool survived = true;
            for (uint256 c = 0; c < N_CHECKS; ++c) {
                if (!held[v][c]) survived = false;
            }
            assertFalse(survived, string.concat("mutant survived every check: ", variantName[v]));
        }
    }

    // ---------------------------------------------------------------------
    // checks
    // ---------------------------------------------------------------------

    /// T6: B_G = 100, N = 3, rho = 1 gives r = (34, 33, 33), S = 0; one unit past the reservation is refused.
    function _checkT6Apportionment(uint256 v) internal returns (bool) {
        address[] memory ag = _agents(3);
        ISpendPartition sp = _deploy(v, ag, 100, 1, 1);
        if (sp.reservedTotal() != 100 || sp.surplusCap() != 0) return false;
        if (sp.reservationOf(ag[0]) != 34 || sp.reservationOf(ag[1]) != 33 || sp.reservationOf(ag[2]) != 33) {
            return false;
        }
        if (!_pay(sp, ag[0], 34)) return false;
        if (_pay(sp, ag[0], 1)) return false;
        return true;
    }

    /// T18: a payment that fits inside the delegate's own remaining reservation consumes no surplus.
    function _checkT18DebitOrder(uint256 v) internal returns (bool) {
        address[] memory ag = _agents(2);
        ISpendPartition sp = _deploy(v, ag, 100, 1, 2); // r = 25, S = 50
        if (!_pay(sp, ag[0], 20)) return false;
        if (sp.spentOf(ag[0]) != 20) return false;
        if (sp.surplusUsed() != 0) return false;
        // the next 5 still fit the reservation; the 6th unit is the first to spill
        if (!_pay(sp, ag[0], 5)) return false;
        if (sp.surplusUsed() != 0) return false;
        if (!_pay(sp, ag[0], 1)) return false;
        if (sp.surplusUsed() != 1) return false;
        return true;
    }

    /// T5 / T9: after a window boundary the same capacity is available again.
    function _checkT5WindowReset(uint256 v) internal returns (bool) {
        address[] memory ag = _agents(2);
        ISpendPartition sp = _deploy(v, ag, 100, 1, 2);
        if (!_pay(sp, ag[0], 75)) return false; // 25 reservation + 50 surplus
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        if (sp.spentOf(ag[0]) != 0 || sp.surplusUsed() != 0) return false;
        if (!_pay(sp, ag[0], 75)) return false;
        if (sp.spentOf(ag[0]) != 75) return false;
        return true;
    }

    /// T12: under rho = 0 with requests 60, 60, 40 every ordering ends at 100 with one request refused.
    function _checkT12Ordering(uint256 v) internal returns (bool) {
        address[] memory ag = _agents(3);
        uint256[3] memory req = [uint256(60), 60, 40];
        uint8[3][6] memory orders =
            [[uint8(0), 1, 2], [uint8(0), 2, 1], [uint8(1), 0, 2], [uint8(1), 2, 0], [uint8(2), 0, 1], [uint8(2), 1, 0]];

        for (uint256 k = 0; k < 6; ++k) {
            ISpendPartition sp = _deploy(v, ag, 100, 0, 1);
            for (uint256 j = 0; j < 3; ++j) {
                uint8 who = orders[k][j];
                _pay(sp, ag[who], req[who]);
            }
            uint256 a = sp.spentOf(ag[0]);
            uint256 b = sp.spentOf(ag[1]);
            uint256 c = sp.spentOf(ag[2]);
            if (a + b + c != 100) return false;
            if (sp.surplusUsed() != 100) return false;
            bool allowed = (a == 60 && b == 0 && c == 40) || (a == 0 && b == 60 && c == 40);
            if (!allowed) return false;
        }
        return true;
    }

    /// T16: a payment that cannot be served in full is refused and moves nothing.
    function _checkT16Atomicity(uint256 v) internal returns (bool) {
        address[] memory ag = _agents(2);
        ISpendPartition sp = _deploy(v, ag, 100, 1, 2);
        if (!_pay(sp, ag[0], 75)) return false;

        uint256 spentBefore = sp.spentOf(ag[0]);
        uint256 usedBefore = sp.surplusUsed();
        uint256 merchantBefore = usdc.balanceOf(MERCHANT);

        if (_pay(sp, ag[0], 1)) return false; // nothing left for this delegate
        if (sp.spentOf(ag[0]) != spentBefore) return false;
        if (sp.surplusUsed() != usedBefore) return false;
        if (usdc.balanceOf(MERCHANT) != merchantBefore) return false;
        return true;
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _deploy(uint256 v, address[] memory ag, uint256 budget, uint256 rhoNum, uint256 rhoDen)
        internal
        returns (ISpendPartition)
    {
        IERC20 t = IERC20(address(usdc));
        address a;
        if (v == 0) a = address(new SpendPartition(t, ag, budget, rhoNum, rhoDen, WINDOW));
        else if (v == 1) a = address(new MutantM1DebitOrder(t, ag, budget, rhoNum, rhoDen, WINDOW));
        else if (v == 2) a = address(new MutantM2NoWindowTag(t, ag, budget, rhoNum, rhoDen, WINDOW));
        else a = address(new MutantM3PartialFill(t, ag, budget, rhoNum, rhoDen, WINDOW));
        usdc.mint(a, budget * 64);
        return ISpendPartition(a);
    }

    function _agents(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = address(uint160(0xA000 + i));
        }
    }

    function _pay(ISpendPartition sp, address who, uint256 amount) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = address(sp).call(abi.encodeCall(ISpendPartition.pay, (MERCHANT, amount)));
    }

    function _pad(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        bytes memory out = new bytes(width);
        for (uint256 i = 0; i < width; ++i) {
            out[i] = i < b.length ? b[i] : bytes1(" ");
        }
        return string(out);
    }
}
