// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title MutantM3PartialFill (mutant of SpendPartition, test fixture only)
/// @notice MUTATION: a payment that exceeds the remaining surplus is partially filled.
///         Spec 2 accepts the full amount or reverts; there is no partial grant.
/// @notice One principal budget B_G per time window, shared by N registered delegates.
///         Delegate i holds a reservation r_i; S = B_G - R is a shared surplus; rho = rhoNum / rhoDen.
/// @dev Semantics: Technical Spec v1.1 (errata 2026-08-08).
///      Storage and hot path: Storage Layout Design v1.1, Parts 2-5.
///      Configuration is fixed per deployment (Spec 1.3 "MVP realization"); there is no mutation path.
contract MutantM3PartialFill is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// Layout v1.1 2.1: 16 + 48 + 192 = 256 bits, one slot per delegate.
    struct AgentSlot {
        uint16 indexPlusOne; // 0 means "not registered"
        uint48 windowId;
        uint192 spent;
    }

    /// Layout v1.1 2.1: 48 + 208 = 256 bits, one slot in total.
    struct SurplusSlot {
        uint48 windowId;
        uint208 used;
    }

    // ---------------------------------------------------------------------
    // Configuration (immutable, read with PUSH on the hot path)
    // ---------------------------------------------------------------------

    IERC20 public immutable token;
    uint256 public immutable budget; // B_G
    uint256 public immutable agentCount; // N
    uint256 public immutable rhoNum;
    uint256 public immutable rhoDen;
    uint256 public immutable windowDuration; // Delta
    uint256 public immutable startTime; // t0 = deployment block.timestamp (Spec errata)
    uint256 public immutable reservedTotal; // R = floor(B_G * rhoNum / rhoDen)
    uint256 public immutable surplusCap; // S = B_G - R
    uint256 private immutable _base; // R / N
    uint256 private immutable _rem; // R % N

    // ---------------------------------------------------------------------
    // Mutable state (epoch-tagged, Spec 1.5)
    // ---------------------------------------------------------------------

    mapping(address agent => AgentSlot) private _agentState; // storage slot 0
    SurplusSlot private _surplus; // storage slot 1

    // ---------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------

    /// Layout v1.1 resolved decision 2: enumeration of delegates is recovered from these logs.
    event AgentRegistered(address indexed agent, uint256 idx);
    event Paid(address indexed agent, address indexed recipient, uint256 amount, uint256 fromSurplus, uint48 windowId);

    error InvalidConfig();
    error ZeroAddress();
    error DuplicateAgent(address agent);
    error InvalidAmount();
    error NotAgent(address caller);
    error SurplusExhausted(uint256 fromSurplus, uint256 surplusAvailable);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        IERC20 token_,
        address[] memory agents,
        uint256 budget_,
        uint256 rhoNum_,
        uint256 rhoDen_,
        uint256 windowDuration_
    ) {
        uint256 n = agents.length;
        if (address(token_) == address(0)) revert ZeroAddress();
        if (n == 0 || n > type(uint16).max) revert InvalidConfig(); // A1
        if (budget_ == 0 || budget_ > type(uint192).max) revert InvalidConfig(); // A3
        if (rhoDen_ == 0 || rhoDen_ > type(uint32).max || rhoNum_ > rhoDen_) revert InvalidConfig(); // A4
        if (windowDuration_ == 0) revert InvalidConfig(); // Spec errata: Delta > 0

        // Layout v1.1 2.4: B_G * rhoNum <= (2^192 - 1)(2^32 - 1) < 2^224 under A3 and A4,
        // so the product fits in uint256 and no mulDiv is required.
        uint256 r = (budget_ * rhoNum_) / rhoDen_;

        token = token_;
        budget = budget_;
        agentCount = n;
        rhoNum = rhoNum_;
        rhoDen = rhoDen_;
        windowDuration = windowDuration_;
        startTime = block.timestamp;
        reservedTotal = r;
        surplusCap = budget_ - r;
        _base = r / n;
        _rem = r % n;

        // Stable, dense index assignment over [0, N), assigned once.
        for (uint256 i = 0; i < n; ++i) {
            address a = agents[i];
            if (a == address(0)) revert ZeroAddress();
            if (_agentState[a].indexPlusOne != 0) revert DuplicateAgent(a);
            _agentState[a] = AgentSlot({indexPlusOne: SafeCast.toUint16(i + 1), windowId: 0, spent: 0});
            emit AgentRegistered(a, i);
        }
    }

    // ---------------------------------------------------------------------
    // Payment path (Layout v1.1 Part 3; Spec 2)
    // ---------------------------------------------------------------------

    /// @notice Debit `amount` from the caller's budget position and transfer it to `recipient`.
    ///         Accepts the full amount or reverts; there is no partial grant.
    function pay(address recipient, uint256 amount) external nonReentrant {
        // Layout v1.1 2.3: any amount > B_G already fails the Spec 2 surplus guard;
        // this check only moves that rejection to an earlier, named stage.
        if (amount == 0 || amount > budget) revert InvalidAmount();

        AgentSlot memory slot = _agentState[msg.sender]; // one SLOAD
        if (slot.indexPlusOne == 0) revert NotAgent(msg.sender);

        uint48 w = _currentWindowId();
        uint256 spentEff = slot.windowId == w ? slot.spent : 0; // Spec 1.5 effective value

        uint256 r = _reservation(slot.indexPlusOne - 1);
        uint256 ownRemaining = r > spentEff ? r - spentEff : 0;
        uint256 fromReservation = amount < ownRemaining ? amount : ownRemaining;
        uint256 fromSurplus = amount - fromReservation;

        // G2: the surplus slot is read only when the payment spills past the reservation.
        if (fromSurplus > 0) {
            SurplusSlot memory s = _surplus;
            uint256 usedEff = s.windowId == w ? s.used : 0;
            if (usedEff + fromSurplus > surplusCap) {
                // MUTATION: grant whatever surplus is left instead of rejecting the whole payment.
                fromSurplus = surplusCap - usedEff;
                amount = fromReservation + fromSurplus;
            }
            // G1: retag and value update in one write; no write when fromSurplus == 0.
            _surplus = SurplusSlot({windowId: w, used: SafeCast.toUint208(usedEff + fromSurplus)});
        }

        // Retag folded into the value write (Layout v1.1 Part 3, step 12).
        _agentState[msg.sender] =
            AgentSlot({indexPlusOne: slot.indexPlusOne, windowId: w, spent: SafeCast.toUint192(spentEff + amount)});

        emit Paid(msg.sender, recipient, amount, fromSurplus, w);

        // Interaction last (Layout v1.1 Part 5).
        token.safeTransfer(recipient, amount);
    }

    // ---------------------------------------------------------------------
    // Views: every value is the effective current-window value (Spec 1.5, T11)
    // ---------------------------------------------------------------------

    function currentWindowId() external view returns (uint48) {
        return _currentWindowId();
    }

    function isAgent(address agent) external view returns (bool) {
        return _agentState[agent].indexPlusOne != 0;
    }

    function indexOf(address agent) external view returns (uint256) {
        return _registered(agent).indexPlusOne - 1;
    }

    function reservationOf(address agent) external view returns (uint256) {
        return _reservation(_registered(agent).indexPlusOne - 1);
    }

    function spentOf(address agent) external view returns (uint256) {
        AgentSlot memory slot = _registered(agent);
        return slot.windowId == _currentWindowId() ? slot.spent : 0;
    }

    function surplusUsed() external view returns (uint256) {
        SurplusSlot memory s = _surplus;
        return s.windowId == _currentWindowId() ? s.used : 0;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _registered(address agent) private view returns (AgentSlot memory slot) {
        slot = _agentState[agent];
        if (slot.indexPlusOne == 0) revert NotAgent(agent);
    }

    /// Spec 1.4 equal-weight apportionment: r_i = base + 1 if idx < rem, else base.
    function _reservation(uint256 idx) private view returns (uint256) {
        return _base + (idx < _rem ? 1 : 0);
    }

    /// Spec 1.2: (block.timestamp - t0) / Delta. t0 is the deployment timestamp and block.timestamp is
    /// non-decreasing, so the subtraction cannot underflow. A2: checked uint48 cast.
    function _currentWindowId() private view returns (uint48) {
        return SafeCast.toUint48((block.timestamp - startTime) / windowDuration);
    }
}
