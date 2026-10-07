// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ISpendPartition} from "../src/ISpendPartition.sol";
import {SpendPartitionWeighted} from "../src/SpendPartitionWeighted.sol";
import {SpendPartitionWeightedReference} from "../src/SpendPartitionWeightedReference.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Identical calls into independent systems, with separate tokens and identical recipient addresses.
/// No Hamilton or debit oracle: observations are compared directly, including complete revert data.
contract WeightedDiffHandler is Test {
    ISpendPartition public immutable opt;
    ISpendPartition public immutable ref;
    MockUSDC internal immutable optToken;
    MockUSDC internal immutable refToken;
    address[] internal agents;
    address[3] internal recipients = [address(0xBEEF), address(0xBEE1), address(0xBEE2)];
    bytes32 internal immutable initialOptFixed;
    bytes32 internal immutable initialRefFixed;
    uint256 internal window;
    bool internal primed;

    uint256 public calls;
    uint256 public paymentAttempts;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public reservationOnly;
    uint256 public surplusConsuming;
    uint256 public capacityRejected;
    uint256 public invalidAmountRejected;
    uint256 public rollovers;
    bool public mismatch;
    string public mismatchReason;

    struct Before {
        bytes32 optState;
        bytes32 refState;
        uint256 optRecipient;
        uint256 refRecipient;
        uint256 optBalance;
        uint256 refBalance;
        uint256 used;
    }

    constructor(
        ISpendPartition opt_,
        ISpendPartition ref_,
        MockUSDC optToken_,
        MockUSDC refToken_,
        address[] memory agents_
    ) {
        opt = opt_;
        ref = ref_;
        optToken = optToken_;
        refToken = refToken_;
        agents = agents_;
        initialOptFixed = _fixedState(opt_);
        initialRefFixed = _fixedState(ref_);
    }

    function pay(uint256 agentSeed, uint256 amountSeed, uint256 recipientSeed) external {
        ++calls;
        _compare();
        if (mismatch) return;
        address recipient = recipients[bound(recipientSeed, 0, recipients.length - 1)];
        // Construct coverage within the first payment action, not in deployment or extra campaigns.
        // Every paired payment below receives the same input and is checked immediately.
        if (!primed) {
            primed = true;
            _prime(agentSeed, amountSeed, recipient);
            if (mismatch) return;
        }
        uint256 i = bound(agentSeed, 0, agents.length - 1);
        uint256 amount;
        if (amountSeed % 8 == 0) {
            amount = (amountSeed >> 3) & 1 == 0 ? 0 : opt.budget() + 1;
        } else {
            uint256 remaining = _remaining(i);
            uint256 hi = amountSeed & 1 == 0 && remaining > 0 ? remaining : opt.budget();
            amount = bound(amountSeed >> 3, 1, hi);
        }
        _payment(i, recipient, amount);
    }

    function reject(uint256 agentSeed, uint256 recipientSeed) external {
        ++calls;
        _compare();
        if (mismatch) return;
        _overCapacity(
            bound(agentSeed, 0, agents.length - 1), recipients[bound(recipientSeed, 0, recipients.length - 1)]
        );
    }

    function warp(uint256 timeSeed) external {
        ++calls;
        _compare();
        if (mismatch) return;
        uint256 d = opt.windowDuration();
        // First warp crosses a boundary; later warps mix short movements and one-to-three windows.
        uint256 dt =
            rollovers == 0 || timeSeed & 3 == 0 ? bound(timeSeed >> 2, d, 3 * d) : bound(timeSeed >> 2, 0, d / 8);
        vm.warp(vm.getBlockTimestamp() + dt);
        uint256 next = (vm.getBlockTimestamp() - opt.startTime()) / d;
        if (next != window) {
            ++rollovers;
            window = next;
            for (uint256 i = 0; i < agents.length; ++i) {
                if (opt.spentOf(agents[i]) != 0 || ref.spentOf(agents[i]) != 0) _flag("fresh-window spend");
            }
            if (opt.surplusUsed() != 0 || ref.surplusUsed() != 0) _flag("fresh-window surplus");
        }
        if (opt.currentWindowId() != next || ref.currentWindowId() != next) _flag("window clock");
        _compare();
    }

    function _prime(uint256 agentSeed, uint256 amountSeed, address recipient) internal {
        uint256 i = bound(agentSeed, 0, agents.length - 1);
        if (opt.reservedTotal() > 0) {
            // No Hamilton calculation: find a positive reservation in the already-agreed vector.
            for (uint256 offset = 0; offset < agents.length; ++offset) {
                uint256 j = (i + offset) % agents.length;
                uint256 remaining = _remaining(j);
                if (remaining > 0) {
                    i = j;
                    _payment(i, recipient, bound(amountSeed, 1, remaining));
                    break;
                }
            }
        }
        if (mismatch) return;
        if (opt.surplusCap() > 0) {
            // Choose a successful spill using common observed headroom, not an allocation oracle.
            uint256 available = opt.surplusCap() - opt.surplusUsed();
            _payment(i, recipient, _remaining(i) + bound(amountSeed, 1, available));
        }
        if (!mismatch) _overCapacity(i, recipient);
    }

    function _remaining(uint256 i) internal view returns (uint256) {
        uint256 reservation = opt.reservationOf(agents[i]);
        uint256 spent = opt.spentOf(agents[i]);
        return reservation > spent ? reservation - spent : 0;
    }

    function _overCapacity(uint256 i, address recipient) internal {
        // One above current headroom. This is within [1,B_G+1]; the first rho=0 attempt may
        // hit InvalidAmount, while the primed attempt is in-range and hits SurplusExhausted.
        uint256 amount = _remaining(i) + opt.surplusCap() - opt.surplusUsed() + 1;
        _payment(i, recipient, amount);
    }

    function _payment(uint256 i, address recipient, uint256 amount) internal {
        ++paymentAttempts;
        Before memory before_ = Before({
            optState: stateHash(false),
            refState: stateHash(true),
            optRecipient: optToken.balanceOf(recipient),
            refRecipient: refToken.balanceOf(recipient),
            optBalance: optToken.balanceOf(address(opt)),
            refBalance: refToken.balanceOf(address(ref)),
            used: opt.surplusUsed()
        });
        bytes memory input = abi.encodeCall(ISpendPartition.pay, (recipient, amount));
        vm.prank(agents[i]);
        (bool okOpt, bytes memory dataOpt) = address(opt).call(input);
        vm.prank(agents[i]);
        (bool okRef, bytes memory dataRef) = address(ref).call(input);

        if (okOpt != okRef) {
            _flag("payment success/revert outcome");
            return;
        }
        if (!okOpt && keccak256(dataOpt) != keccak256(dataRef)) {
            _flag("raw revert data");
            return;
        }
        _compare();
        if (mismatch) return;
        _checkPayment(
            opt, optToken, recipient, amount, okOpt, before_.optState, before_.optRecipient, before_.optBalance
        );
        _checkPayment(
            ref, refToken, recipient, amount, okRef, before_.refState, before_.refRecipient, before_.refBalance
        );
        if (okOpt && okRef) {
            ++accepted;
            uint256 used = opt.surplusUsed();
            if (used == before_.used) ++reservationOnly;
            else if (used > before_.used) ++surplusConsuming;
            else _flag("surplus decreased during payment");
        } else if (!okOpt && !okRef) {
            ++rejected;
            if (bytes4(dataOpt) == SpendPartitionWeighted.SurplusExhausted.selector) ++capacityRejected;
            if (bytes4(dataOpt) == SpendPartitionWeighted.InvalidAmount.selector) ++invalidAmountRejected;
        }
    }

    function _checkPayment(
        ISpendPartition sp,
        MockUSDC token,
        address recipient,
        uint256 amount,
        bool ok,
        bytes32 previousState,
        uint256 previousRecipient,
        uint256 previousBalance
    ) internal {
        if (!ok) {
            if (_stateHash(sp, token) != previousState) _flag("rejected payment changed observable state");
        } else {
            if (token.balanceOf(recipient) != previousRecipient + amount) _flag("recipient token delta");
            if (amount > previousBalance || token.balanceOf(address(sp)) != previousBalance - amount) {
                _flag("contract token delta");
            }
        }
    }

    function stateHash(bool reference_) public view returns (bytes32) {
        return reference_ ? _stateHash(ref, refToken) : _stateHash(opt, optToken);
    }

    function fixedStateUnchanged() public view returns (bool) {
        return _fixedState(opt) == initialOptFixed && _fixedState(ref) == initialRefFixed;
    }

    function _fixedState(ISpendPartition sp) internal view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                sp.budget(),
                sp.agentCount(),
                sp.rhoNum(),
                sp.rhoDen(),
                sp.windowDuration(),
                sp.startTime(),
                sp.reservedTotal(),
                sp.surplusCap()
            )
        );
        for (uint256 i = 0; i < agents.length; ++i) {
            digest = keccak256(
                abi.encode(digest, sp.isAgent(agents[i]), sp.indexOf(agents[i]), sp.reservationOf(agents[i]))
            );
        }
    }

    /// Hash only observable values, never raw storage or intentionally different token addresses.
    function _stateHash(ISpendPartition sp, MockUSDC token) internal view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(_fixedState(sp), sp.currentWindowId(), sp.surplusUsed(), token.balanceOf(address(sp)))
        );
        for (uint256 i = 0; i < agents.length; ++i) {
            digest = keccak256(abi.encode(digest, sp.spentOf(agents[i])));
        }
        for (uint256 i = 0; i < recipients.length; ++i) {
            digest = keccak256(abi.encode(digest, token.balanceOf(recipients[i])));
        }
    }

    function _compare() internal {
        // Catch unexpected view failures too, so fail_on_revert=false cannot discard the flag.
        (bool okOpt, bytes memory dataOpt) = address(this).staticcall(abi.encodeCall(this.stateHash, (false)));
        (bool okRef, bytes memory dataRef) = address(this).staticcall(abi.encodeCall(this.stateHash, (true)));
        if (!okOpt || !okRef) {
            _flag("observable view reverted");
            return;
        }
        if (!fixedStateUnchanged()) _flag("configuration or reservation changed");
        if (keccak256(dataOpt) != keccak256(dataRef)) _flag("observable post-state");
    }

    function _flag(string memory reason) internal {
        if (!mismatch) {
            mismatch = true;
            mismatchReason = reason;
        }
    }
}

abstract contract WeightedDifferentialBase is Test {
    ISpendPartition internal opt;
    ISpendPartition internal ref;
    WeightedDiffHandler internal handler;
    address[] internal agents;
    uint256 internal constant WINDOW = 7 days;

    function _config() internal pure virtual returns (uint256[] memory, uint256, uint256, uint256);

    function setUp() public {
        (uint256[] memory weights, uint256 budget, uint256 num, uint256 den) = _config();
        for (uint256 i = 0; i < weights.length; ++i) {
            agents.push(address(uint160(0xA000 + i)));
        }
        MockUSDC optToken = new MockUSDC();
        MockUSDC refToken = new MockUSDC();
        // No warp between deployments: both start at this same block timestamp.
        opt = ISpendPartition(address(new SpendPartitionWeighted(optToken, agents, weights, budget, num, den, WINDOW)));
        ref = ISpendPartition(
            address(new SpendPartitionWeightedReference(refToken, agents, weights, budget, num, den, WINDOW))
        );
        _assertDeployment(budget, num, den);
        // At most four paired payments per action, depth 128: 1024*B_G exceeds 512*B_G.
        optToken.mint(address(opt), budget * 1024);
        refToken.mint(address(ref), budget * 1024);
        handler = new WeightedDiffHandler(opt, ref, optToken, refToken, agents);
        assertEq(handler.stateHash(false), handler.stateHash(true), "initial funded state");

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = WeightedDiffHandler.pay.selector;
        selectors[1] = WeightedDiffHandler.reject.selector;
        selectors[2] = WeightedDiffHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _assertDeployment(uint256 budget, uint256 num, uint256 den) internal view {
        assertEq(opt.budget(), ref.budget(), "initial budget");
        assertEq(opt.budget(), budget);
        assertEq(opt.agentCount(), ref.agentCount(), "initial agentCount");
        assertEq(opt.agentCount(), agents.length);
        assertEq(opt.rhoNum(), ref.rhoNum(), "initial rhoNum");
        assertEq(opt.rhoNum(), num);
        assertEq(opt.rhoDen(), ref.rhoDen(), "initial rhoDen");
        assertEq(opt.rhoDen(), den);
        assertEq(opt.windowDuration(), ref.windowDuration(), "initial duration");
        assertEq(opt.windowDuration(), WINDOW);
        assertEq(opt.startTime(), ref.startTime(), "initial startTime");
        assertEq(opt.startTime(), vm.getBlockTimestamp());
        assertEq(opt.reservedTotal(), ref.reservedTotal(), "initial reservedTotal");
        assertEq(opt.surplusCap(), ref.surplusCap(), "initial surplusCap");
        assertEq(opt.currentWindowId(), 0);
        assertEq(ref.currentWindowId(), 0);
        assertEq(opt.surplusUsed(), 0);
        assertEq(ref.surplusUsed(), 0);
        for (uint256 i = 0; i < agents.length; ++i) {
            assertTrue(opt.isAgent(agents[i]));
            assertTrue(ref.isAgent(agents[i]));
            assertEq(opt.indexOf(agents[i]), i);
            assertEq(ref.indexOf(agents[i]), i);
            assertEq(opt.reservationOf(agents[i]), ref.reservationOf(agents[i]), "initial reservation vector");
            assertEq(opt.spentOf(agents[i]), 0);
            assertEq(ref.spentOf(agents[i]), 0);
        }
    }

    /// A single invariant per configuration preserves exactly 64*128 handler calls.
    function invariant_WeightedImplementationsAgree() public view {
        assertFalse(handler.mismatch(), handler.mismatchReason());
        assertTrue(handler.fixedStateUnchanged(), "fixed configuration");
        assertEq(handler.stateHash(false), handler.stateHash(true), "complete observable state");
    }

    function afterInvariant() public {
        assertGt(handler.accepted(), 0, "coverage: accepted");
        assertGt(handler.rejected(), 0, "coverage: rejected");
        assertGt(handler.capacityRejected(), 0, "coverage: in-range capacity rejection");
        assertGt(handler.rollovers(), 0, "coverage: rollover");
        if (opt.reservedTotal() > 0) assertGt(handler.reservationOnly(), 0, "coverage: protected success");
        if (opt.surplusCap() > 0) assertGt(handler.surplusConsuming(), 0, "coverage: surplus success");
        uint256[] memory counts = new uint256[](7);
        counts[0] = handler.calls();
        counts[1] = handler.paymentAttempts();
        counts[2] = handler.accepted();
        counts[3] = handler.rejected();
        counts[4] = handler.reservationOnly();
        counts[5] = handler.surplusConsuming();
        counts[6] = handler.rollovers();
        emit log_named_array("coverage [actions, payments, accepted, rejected, protected, surplus, rollovers]", counts);
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

contract WeightedDifferential_Equal is WeightedDifferentialBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(3, 3, 3, 3, 3), 101, 2, 3);
    }
}

contract WeightedDifferential_Skewed is WeightedDifferentialBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(1, 2, 7, 19, 31), 137, 3, 5);
    }
}

contract WeightedDifferential_Zeros is WeightedDifferentialBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(0, 1, 0, 3, 7), 103, 2, 3);
    }
}

contract WeightedDifferential_RhoZero is WeightedDifferentialBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(0, 1, 2, 5, 11), 109, 0, 1);
    }
}

contract WeightedDifferential_RhoOne is WeightedDifferentialBase {
    function _config() internal pure override returns (uint256[] memory, uint256, uint256, uint256) {
        return (_weights(1, 1, 2, 5, 13), 107, 1, 1);
    }
}
