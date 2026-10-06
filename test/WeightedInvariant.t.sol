// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpendPartitionWeighted} from "../src/SpendPartitionWeighted.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Weighted state machine. Ghost spending records only accepted amounts, never contract spend.
/// Failures are sticky flags: fail_on_revert=false must not discard an assertion in the handler.
contract WeightedInvariantHandler is Test {
    SpendPartitionWeighted public immutable sp;
    MockUSDC internal immutable token;
    address internal constant MERCHANT = address(0xBEEF);
    address[] internal agents;
    uint256[] internal reservations;
    uint256[] internal gSpent;
    uint256 public gWindowId;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public protectedPayments;
    uint256 public protectedAfterExhaustion;
    uint256 public rollovers;
    bool public violation;
    string public violationReason;

    constructor(SpendPartitionWeighted sp_, MockUSDC token_, address[] memory agents_) {
        sp = sp_;
        token = token_;
        agents = agents_;
        gSpent = new uint256[](agents_.length);
        for (uint256 i = 0; i < agents_.length; ++i) {
            reservations.push(sp_.reservationOf(agents_[i]));
        }
    }

    function pay(uint256 agentSeed, uint256 amountSeed) external {
        _syncWindow();
        uint256 i = bound(agentSeed, 0, agents.length - 1);
        uint256 remaining = _remaining(i);
        // Half the draws deliberately fit inside protection, when available; the rest can spill
        // or exhaust the shared pool. No assumptions, discarded inputs, or zero-amount requests.
        uint256 hi = amountSeed & 1 == 0 && remaining > 0 ? remaining : sp.budget();
        _pay(i, bound(amountSeed >> 1, 1, hi));
    }

    /// I2 transition: another delegate consumes all available surplus before a protected payment.
    /// Rho=0 has no positive entitlement; rho=1 starts with the surplus already exhausted.
    function protectedPayment(uint256 agentSeed, uint256 amountSeed) external {
        _syncWindow();
        uint256 first = bound(agentSeed, 0, agents.length - 1);
        for (uint256 offset = 0; offset < agents.length; ++offset) {
            uint256 i = (first + offset) % agents.length;
            uint256 remaining = _remaining(i);
            if (remaining == 0) continue;
            uint256 used = sp.surplusUsed();
            if (used > sp.surplusCap()) {
                _flag("I3: surplus already above cap");
                return;
            }
            uint256 available = sp.surplusCap() - used;
            if (available > 0) {
                uint256 other = (i + 1) % agents.length;
                // The full remaining reservation plus available surplus fits inside B_G.
                if (!_pay(other, _remaining(other) + available)) {
                    _flag("I2: surplus exhaustion setup rejected");
                    return;
                }
            }
            if (sp.surplusUsed() != sp.surplusCap()) _flag("I2: surplus not exhausted");
            if (_pay(i, bound(amountSeed, 1, remaining))) ++protectedAfterExhaustion;
            return;
        }
    }

    function warp(uint256 timeSeed) external {
        uint256 d = sp.windowDuration();
        // The first warp always crosses a boundary, constructively guaranteeing I5 coverage.
        // Later draws mostly stay near the current window, with occasional multi-window gaps.
        uint256 dt =
            rollovers == 0 || timeSeed & 3 == 0 ? bound(timeSeed >> 2, d, 3 * d) : bound(timeSeed >> 2, 0, d / 8);
        vm.warp(vm.getBlockTimestamp() + dt);
        _syncWindow();
    }

    function ghostSpent(uint256 i) external view returns (uint256) {
        return gSpent[i];
    }

    function originalReservation(uint256 i) external view returns (uint256) {
        return reservations[i];
    }

    function _remaining(uint256 i) internal view returns (uint256) {
        return reservations[i] > gSpent[i] ? reservations[i] - gSpent[i] : 0;
    }

    function _pay(uint256 i, uint256 amount) internal returns (bool ok) {
        uint256 remaining = _remaining(i);
        uint256 usedBefore = sp.surplusUsed();
        uint256 balanceBefore = token.balanceOf(MERCHANT);
        vm.prank(agents[i]);
        try sp.pay(MERCHANT, amount) {
            ++accepted;
            gSpent[i] += amount;
            if (amount <= remaining) ++protectedPayments;
            if (token.balanceOf(MERCHANT) != balanceBefore + amount) _flag("accepted transfer mismatch");
            ok = true;
        } catch {
            ++rejected;
            if (amount <= remaining) _flag("I2: protected payment rejected");
            if (sp.surplusUsed() != usedBefore || token.balanceOf(MERCHANT) != balanceBefore) {
                _flag("rejected payment changed surplus or token balance");
            }
        }
        // Check the whole vector, including untouched delegates and rejected transitions.
        for (uint256 j = 0; j < agents.length; ++j) {
            if (sp.spentOf(agents[j]) != gSpent[j]) _flag("accepted/rejected spending disagrees with ghost");
        }
    }

    function _syncWindow() internal {
        // Independent specification clock. Monotonic warps never revisit a previous window.
        uint256 w = (vm.getBlockTimestamp() - sp.startTime()) / sp.windowDuration();
        if (w == gWindowId) return;
        // I5: observe the new window BEFORE a payment can write. Historical slots may remain.
        for (uint256 i = 0; i < agents.length; ++i) {
            if (sp.spentOf(agents[i]) != 0) _flag("I5: new-window spending nonzero");
            gSpent[i] = 0;
        }
        if (sp.surplusUsed() != 0) _flag("I5: new-window surplus nonzero");
        gWindowId = w;
        ++rollovers;
    }

    function _flag(string memory reason) internal {
        if (!violation) {
            violation = true;
            violationReason = reason;
        }
    }
}

abstract contract WeightedInvariantBase is Test {
    SpendPartitionWeighted internal sp;
    WeightedInvariantHandler internal handler;
    address[] internal agents;
    uint256 internal constant WINDOW = 7 days;

    function _config() internal pure virtual returns (uint256[] memory, uint256, uint256, uint256);

    function setUp() public {
        (uint256[] memory weights, uint256 budget, uint256 num, uint256 den) = _config();
        MockUSDC token = new MockUSDC();
        for (uint256 i = 0; i < weights.length; ++i) {
            agents.push(address(uint160(0xA000 + i)));
        }
        sp = new SpendPartitionWeighted(token, agents, weights, budget, num, den, WINDOW);
        // At most two payments per handler call and 128 calls/run. This exceeds even the
        // conservative 256*B_G outflow bound; each invariant run restores its initial state.
        token.mint(address(sp), budget * 1024);
        handler = new WeightedInvariantHandler(sp, token, agents);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = WeightedInvariantHandler.pay.selector;
        selectors[1] = WeightedInvariantHandler.protectedPayment.selector;
        selectors[2] = WeightedInvariantHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// One invariant per configuration means 64*128=8192 handler calls, rather than five campaigns.
    /// I2 and I5 are transition flags; I1/I3/I4 are derived from current observable state.
    function invariant_WeightedI1ThroughI5() public view {
        uint256 sum;
        uint256 excess;
        for (uint256 i = 0; i < agents.length; ++i) {
            uint256 spent = sp.spentOf(agents[i]);
            uint256 reservation = sp.reservationOf(agents[i]);
            assertEq(spent, handler.ghostSpent(i), "independent ghost spending");
            assertEq(reservation, handler.originalReservation(i), "fixed reservation");
            sum += spent;
            if (spent > reservation) excess += spent - reservation;
        }
        assertEq(uint256(sp.currentWindowId()), handler.gWindowId(), "independent clock");
        assertLe(sum, sp.budget(), "I1 aggregate spending safety");
        assertLe(sp.surplusUsed(), sp.surplusCap(), "I3 surplus cap");
        assertEq(sp.surplusUsed(), excess, "I4 exact observable surplus accounting");
        assertFalse(handler.violation(), handler.violationReason());
    }

    /// Guard against vacuous transition coverage in each completed campaign sequence.
    /// Zero-reservation configurations have no positive I2 entitlement.
    function afterInvariant() public view {
        assertGt(handler.accepted(), 0, "coverage: successful payment");
        assertGt(handler.rollovers(), 0, "coverage: new-window observation");
        if (sp.reservedTotal() > 0) {
            assertGt(handler.protectedAfterExhaustion(), 0, "coverage: I2 with exhausted surplus");
        }
    }

    function _weights(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
        internal
        pure
        returns (uint256[] memory w)
    {
        w = new uint256[](5);
        w[0] = a;
        w[1] = b;
        w[2] = c;
        w[3] = d;
        w[4] = e;
    }
}

contract WeightedInvariant_Equal is WeightedInvariantBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(3, 3, 3, 3, 3), 101, 2, 3);
    }
}

contract WeightedInvariant_Skewed is WeightedInvariantBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(1, 2, 7, 19, 31), 137, 3, 5);
    }
}

contract WeightedInvariant_Zeros is WeightedInvariantBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(0, 1, 0, 3, 7), 103, 2, 3);
    }
}

contract WeightedInvariant_RhoZero is WeightedInvariantBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(0, 1, 2, 5, 11), 109, 0, 1);
    }
}

contract WeightedInvariant_RhoOne is WeightedInvariantBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(1, 1, 2, 5, 13), 107, 1, 1);
    }
}
