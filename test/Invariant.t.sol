// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SPBase} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Bounded actor (Test Plan v1.1 section 0). Ghost values are maintained here and never read from
/// the contract; rejected payments are valid outcomes and do not abort the run.
contract Handler is Test {
    SpendPartition public immutable sp;
    address[] internal agents;
    address internal constant MERCHANT = address(0xBEEF);

    uint256 public gWindowId;
    uint256[] internal gSpent;
    uint256 public accepted;
    uint256 public acceptedWithSpill;
    uint256 public rejected;
    uint256 public rollovers;
    bool public violation;
    string public violationReason;

    constructor(SpendPartition sp_, address[] memory agents_) {
        sp = sp_;
        agents = agents_;
        gSpent = new uint256[](agents_.length);
    }

    function pay(uint256 agentSeed, uint256 amountSeed) external {
        _syncWindow();
        uint256 i = bound(agentSeed, 0, agents.length - 1);
        uint256 b = sp.budget();
        // Even seeds draw below an equal share, odd seeds over the full range; always within [1, B_G].
        uint256 hi = (amountSeed & 1 == 0) ? _max(1, b / agents.length) : b;
        uint256 a = bound(amountSeed >> 1, 1, hi);

        address x = agents[i];
        uint256 spent0 = sp.spentOf(x);
        uint256 used0 = sp.surplusUsed();
        uint256 r = sp.reservationOf(x);
        uint256 ownRemaining = r > spent0 ? r - spent0 : 0;

        vm.prank(x);
        try sp.pay(MERCHANT, a) {
            ++accepted;
            if (a > ownRemaining) ++acceptedWithSpill;
            gSpent[i] += a;
            if (sp.spentOf(x) - spent0 != a) _flag("T18: delta spent != a");
            uint256 dUsed = sp.surplusUsed() - used0;
            if (a <= ownRemaining ? dUsed != 0 : dUsed != a - ownRemaining) _flag("T18: delta surplusUsed");
        } catch {
            ++rejected;
            if (sp.spentOf(x) != spent0 || sp.surplusUsed() != used0) _flag("T16: state changed on reject");
            if (a <= ownRemaining) _flag("I2: request within own remaining reservation rejected");
        }
    }

    function warp(uint256 timeSeed) external {
        // Three of four draws stay within 1/8 of a window so several payments land in the same window;
        // the fourth ranges up to 3 windows so rollovers, including multi-window gaps, still occur.
        uint256 d = sp.windowDuration();
        uint256 dt = (timeSeed & 3 != 0) ? bound(timeSeed >> 2, 0, d / 8) : bound(timeSeed >> 2, 0, 3 * d);
        vm.warp(vm.getBlockTimestamp() + dt);
        uint256 before = gWindowId;
        _syncWindow();
        if (gWindowId != before) {
            // T5: first observation in a new window, before any write.
            for (uint256 i = 0; i < agents.length; ++i) {
                if (sp.spentOf(agents[i]) != 0) _flag("T5: spent nonzero at window start");
            }
            if (sp.surplusUsed() != 0) _flag("T5: surplusUsed nonzero at window start");
        }
    }

    function ghostSpent(uint256 i) external view returns (uint256) {
        return gSpent[i];
    }

    /// Spec 1.2 definition of the window id, evaluated independently of the contract.
    function _syncWindow() internal {
        uint256 w = (vm.getBlockTimestamp() - sp.startTime()) / sp.windowDuration();
        if (w != gWindowId) {
            gWindowId = w;
            ++rollovers;
            for (uint256 i = 0; i < gSpent.length; ++i) {
                gSpent[i] = 0;
            }
        }
    }

    function _flag(string memory reason) internal {
        if (!violation) {
            violation = true;
            violationReason = reason;
        }
    }

    function _max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x : y;
    }
}

abstract contract InvariantBase is SPBase {
    SpendPartition internal sp;
    Handler internal handler;
    address[] internal ag;

    function _config() internal pure virtual returns (uint256 n, uint256 budget, uint256 rhoNum, uint256 rhoDen);

    function setUp() public {
        usdc = new MockUSDC();
        (uint256 n, uint256 b, uint256 num, uint256 den) = _config();
        ag = _agents(n);
        sp = new SpendPartition(IERC20(address(usdc)), ag, b, num, den, WINDOW);
        usdc.mint(address(sp), b * 1000);
        handler = new Handler(sp, ag);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = Handler.pay.selector;
        selectors[1] = Handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Coverage counters for this run, appended to results/invariant_coverage.csv:
    /// accepted payments, accepted payments that spilled into surplus, rejected payments, window rollovers.
    function afterInvariant() public {
        (uint256 n, uint256 b, uint256 num, uint256 den) = _config();
        string memory cfg = string.concat(vm.toString(n), ",", vm.toString(b), ",", vm.toString(num), "/", vm.toString(den));
        string memory counts = string.concat(
            vm.toString(handler.accepted()),
            ",",
            vm.toString(handler.acceptedWithSpill()),
            ",",
            vm.toString(handler.rejected()),
            ",",
            vm.toString(handler.rollovers())
        );
        vm.writeLine("results/invariant_coverage.csv", string.concat(cfg, ",", counts));
    }

    /// I1, I3, I4, ghost agreement, handler-side T5/T16/T18/I2 flags, and the T2 probe.
    function invariant_SpecV11() public {
        uint256 sum;
        uint256 overReservation;
        for (uint256 i = 0; i < ag.length; ++i) {
            uint256 s = sp.spentOf(ag[i]);
            uint256 r = sp.reservationOf(ag[i]);
            assertEq(s, handler.ghostSpent(i), "ghost spent");
            sum += s;
            if (s > r) overReservation += s - r;
        }
        uint256 used = sp.surplusUsed();
        assertLe(sum, sp.budget(), "I1");
        assertLe(used, sp.surplusCap(), "I3");
        assertEq(used, overReservation, "I4");
        assertFalse(handler.violation(), handler.violationReason());

        // T2 probe: snapshot -> real entry point -> revert. No separate canPay predicate.
        for (uint256 i = 0; i < ag.length; ++i) {
            uint256 s = sp.spentOf(ag[i]);
            uint256 r = sp.reservationOf(ag[i]);
            if (s < r) {
                uint256 snap = vm.snapshotState();
                vm.prank(ag[i]);
                (bool ok,) = address(sp).call(abi.encodeCall(SpendPartition.pay, (MERCHANT, r - s)));
                vm.revertToStateAndDelete(snap);
                assertTrue(ok, "T2: protected probe rejected");
            }
        }
    }
}

contract Invariant_N3_B100_Rho1over2 is InvariantBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (3, 100, 1, 2);
    }
}

contract Invariant_N5_B101_Rho1over4 is InvariantBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (5, 101, 1, 4);
    }
}

contract Invariant_N2_B1000_Rho0 is InvariantBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (2, 1000, 0, 1);
    }
}

contract Invariant_N10_B2pow64_Rho3over4 is InvariantBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (10, type(uint64).max, 3, 4);
    }
}

contract Invariant_N3_B100_Rho1 is InvariantBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (3, 100, 1, 1);
    }
}

contract Invariant_N50_B1000_Rho1over3 is InvariantBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (50, 1000, 1, 3);
    }
}
