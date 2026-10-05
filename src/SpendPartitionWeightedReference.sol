// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title SpendPartitionWeightedReference
/// @notice Plain weighted reference fixture, not a production or optimized implementation.
/// @dev Independent Hamilton selection, linear delegate lookup, uint256 reservation array,
///      and window-keyed uint256 accounting. No optimized contract or shared allocation helper.
contract SpendPartitionWeightedReference {
    using SafeERC20 for IERC20;

    IERC20 public token;
    uint256 public budget;
    uint256 public agentCount;
    uint256 public rhoNum;
    uint256 public rhoDen;
    uint256 public windowDuration;
    uint256 public startTime;
    uint256 public reservedTotal;
    uint256 public surplusCap;

    address[] private _delegates;
    uint256[] private _reservations;
    mapping(uint256 window => mapping(address agent => uint256 spent)) private _spending;
    mapping(uint256 window => uint256 used) private _surplusByWindow;
    bool private _entered;

    event AgentRegistered(address indexed agent, uint256 idx);
    event Paid(address indexed agent, address indexed recipient, uint256 amount, uint256 fromSurplus, uint48 windowId);

    error InvalidConfig();
    error ZeroAddress();
    error DuplicateAgent(address agent);
    error InvalidAmount();
    error NotAgent(address caller);
    error SurplusExhausted(uint256 fromSurplus, uint256 surplusAvailable);
    // Same observable selector as the optimized guard, with independent ordinary-storage logic.
    error ReentrancyGuardReentrantCall();

    constructor(
        IERC20 token_,
        address[] memory agents,
        uint256[] memory weights,
        uint256 budget_,
        uint256 rhoNum_,
        uint256 rhoDen_,
        uint256 windowDuration_
    ) {
        if (address(token_) == address(0)) revert ZeroAddress();
        if (agents.length == 0 || agents.length > type(uint16).max) revert InvalidConfig();
        if (budget_ == 0 || budget_ > type(uint192).max) revert InvalidConfig();
        if (rhoDen_ == 0 || rhoDen_ > type(uint32).max || rhoNum_ > rhoDen_) revert InvalidConfig();
        if (windowDuration_ == 0) revert InvalidConfig();
        if (agents.length != weights.length) revert InvalidConfig();

        token = token_;
        budget = budget_;
        agentCount = agents.length;
        rhoNum = rhoNum_;
        rhoDen = rhoDen_;
        windowDuration = windowDuration_;
        startTime = block.timestamp;
        // The inherited budget and ratio bounds make this product fit in uint256.
        reservedTotal = (budget_ * rhoNum_) / rhoDen_;
        surplusCap = budget_ - reservedTotal;
        _constructReservations(weights);

        for (uint256 i = 0; i < agents.length; ++i) {
            if (agents[i] == address(0)) revert ZeroAddress();
            if (isAgent(agents[i])) revert DuplicateAgent(agents[i]);
            _delegates.push(agents[i]);
            emit AgentRegistered(agents[i], i);
        }
    }

    /// @dev Select one winner for each leftover unit; scanning in registration order and
    ///      replacing the winner only for a strictly larger remainder gives stable tie-breaking.
    ///      Each delegate may win at most once. All apportionment work happens at deployment.
    function _constructReservations(uint256[] memory weights) private {
        uint256 totalWeight;
        for (uint256 i = 0; i < weights.length; ++i) {
            if (weights[i] > type(uint256).max - totalWeight) revert InvalidConfig();
            totalWeight += weights[i];
        }
        if (totalWeight == 0) revert InvalidConfig();

        uint256[] memory remainders = new uint256[](weights.length);
        bool[] memory awarded = new bool[](weights.length);
        uint256 allocated;
        for (uint256 i = 0; i < weights.length; ++i) {
            uint256 quotaFloor = Math.mulDiv(reservedTotal, weights[i], totalWeight);
            _reservations.push(quotaFloor);
            allocated += quotaFloor;
            remainders[i] = mulmod(reservedTotal, weights[i], totalWeight);
        }

        uint256 leftover = reservedTotal - allocated;
        for (uint256 unit = 0; unit < leftover; ++unit) {
            uint256 winner = weights.length;
            for (uint256 i = 0; i < weights.length; ++i) {
                if (!awarded[i] && (winner == weights.length || remainders[i] > remainders[winner])) {
                    winner = i;
                }
            }
            awarded[winner] = true;
            ++_reservations[winner];
        }
    }

    function pay(address recipient, uint256 amount) external {
        if (_entered) revert ReentrancyGuardReentrantCall();
        _entered = true;
        if (amount == 0 || amount > budget) revert InvalidAmount();

        uint256 reservation = _reservations[indexOf(msg.sender)];
        uint48 window = currentWindowId();
        uint256 previousSpent = _spending[window][msg.sender];
        uint256 nextSpent = previousSpent + amount;
        // Surplus is the increase in cumulative spending above this agent's reservation.
        // This gives reservation-first semantics without the optimized ownRemaining/min path.
        uint256 previousExcess = previousSpent > reservation ? previousSpent - reservation : 0;
        uint256 nextExcess = nextSpent > reservation ? nextSpent - reservation : 0;
        uint256 fromSurplus = nextExcess - previousExcess;
        uint256 available = surplusCap - _surplusByWindow[window];
        if (fromSurplus > available) revert SurplusExhausted(fromSurplus, available);

        _spending[window][msg.sender] = nextSpent;
        _surplusByWindow[window] += fromSurplus;
        emit Paid(msg.sender, recipient, amount, fromSurplus, window);
        token.safeTransfer(recipient, amount);
        _entered = false;
    }

    function currentWindowId() public view returns (uint48) {
        // Match the baseline's checked API window bound; accounting itself stays uint256.
        return SafeCast.toUint48((block.timestamp - startTime) / windowDuration);
    }

    function isAgent(address agent) public view returns (bool) {
        return _find(agent) < _delegates.length;
    }

    function indexOf(address agent) public view returns (uint256) {
        uint256 index = _find(agent);
        if (index == _delegates.length) revert NotAgent(agent);
        return index;
    }

    function reservationOf(address agent) external view returns (uint256) {
        return _reservations[indexOf(agent)];
    }

    function spentOf(address agent) external view returns (uint256) {
        indexOf(agent); // Reject unregistered callers consistently with the baseline views.
        return _spending[currentWindowId()][agent];
    }

    function surplusUsed() external view returns (uint256) {
        return _surplusByWindow[currentWindowId()];
    }

    function _find(address agent) private view returns (uint256) {
        for (uint256 i = 0; i < _delegates.length; ++i) {
            if (_delegates[i] == agent) return i;
        }
        return _delegates.length;
    }
}
