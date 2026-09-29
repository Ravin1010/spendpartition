// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SpendPartitionReference
/// @notice Second implementation of Technical Spec v1.1 (errata 2026-08-08), written for the
///         differential harness. It is not deployed and not benchmarked.
/// @dev Where SpendPartition is organised for cost, this file is organised for reading. The two
///      differ in every structural choice that could hide a shared mistake:
///        - state is keyed by window id instead of carrying an epoch tag inside one packed slot,
///          so a new window starts empty with no lazy reset logic at all;
///        - the agent index comes from a linear scan of an array instead of a stored index;
///        - R, base and rem are recomputed from their definitions on every call instead of being
///          fixed at construction;
///        - configuration lives in ordinary storage, not in immutables;
///        - nothing is packed, downcast, or bit-shifted.
///      The observable behaviour it implements is the same: the payment entry point, the amount
///      guards exercised by T17, and the six views.
contract SpendPartitionReference {
    using SafeERC20 for IERC20;

    IERC20 public token;
    uint256 public budget; // B_G
    uint256 public agentCount; // N
    uint256 public rhoNum;
    uint256 public rhoDen;
    uint256 public windowDuration; // Delta
    uint256 public startTime; // t0

    address[] private _agentList;
    mapping(uint256 window => mapping(address agent => uint256)) private _spentIn;
    mapping(uint256 window => uint256) private _surplusUsedIn;
    bool private _entered;

    event AgentRegistered(address indexed agent, uint256 idx);
    event Paid(address indexed agent, address indexed recipient, uint256 amount, uint256 fromSurplus, uint48 windowId);

    error InvalidConfig();
    error ZeroAddress();
    error DuplicateAgent(address agent);
    error InvalidAmount();
    error NotAgent(address caller);
    error SurplusExhausted(uint256 fromSurplus, uint256 surplusAvailable);
    error Reentrancy();

    constructor(
        IERC20 token_,
        address[] memory agents,
        uint256 budget_,
        uint256 rhoNum_,
        uint256 rhoDen_,
        uint256 windowDuration_
    ) {
        if (address(token_) == address(0)) revert ZeroAddress();
        if (agents.length == 0 || agents.length > type(uint16).max) revert InvalidConfig(); // A1
        if (budget_ == 0 || budget_ > type(uint192).max) revert InvalidConfig(); // A3
        if (rhoDen_ == 0 || rhoDen_ > type(uint32).max || rhoNum_ > rhoDen_) revert InvalidConfig(); // A4
        if (windowDuration_ == 0) revert InvalidConfig();

        token = token_;
        budget = budget_;
        agentCount = agents.length;
        rhoNum = rhoNum_;
        rhoDen = rhoDen_;
        windowDuration = windowDuration_;
        startTime = block.timestamp;

        for (uint256 i = 0; i < agents.length; ++i) {
            if (agents[i] == address(0)) revert ZeroAddress();
            for (uint256 j = 0; j < i; ++j) {
                if (agents[j] == agents[i]) revert DuplicateAgent(agents[i]);
            }
            _agentList.push(agents[i]);
            emit AgentRegistered(agents[i], i);
        }
    }

    function pay(address recipient, uint256 amount) external {
        if (_entered) revert Reentrancy();
        _entered = true;

        if (amount == 0 || amount > budget) revert InvalidAmount();

        uint256 idx = indexOf(msg.sender);
        uint256 w = currentWindowId();

        uint256 spentSoFar = _spentIn[w][msg.sender];
        uint256 r = _reservationAt(idx);
        uint256 ownRemaining = r > spentSoFar ? r - spentSoFar : 0;

        uint256 fromReservation = amount < ownRemaining ? amount : ownRemaining;
        uint256 fromSurplus = amount - fromReservation;

        uint256 surplusAvailable = surplusCap() - _surplusUsedIn[w];
        if (fromSurplus > surplusAvailable) revert SurplusExhausted(fromSurplus, surplusAvailable);

        _spentIn[w][msg.sender] = spentSoFar + amount;
        _surplusUsedIn[w] = _surplusUsedIn[w] + fromSurplus;

        emit Paid(msg.sender, recipient, amount, fromSurplus, uint48(w));
        token.safeTransfer(recipient, amount);

        _entered = false;
    }

    function currentWindowId() public view returns (uint48) {
        return uint48((block.timestamp - startTime) / windowDuration);
    }

    function isAgent(address agent) public view returns (bool) {
        for (uint256 i = 0; i < _agentList.length; ++i) {
            if (_agentList[i] == agent) return true;
        }
        return false;
    }

    function indexOf(address agent) public view returns (uint256) {
        for (uint256 i = 0; i < _agentList.length; ++i) {
            if (_agentList[i] == agent) return i;
        }
        revert NotAgent(agent);
    }

    function reservationOf(address agent) external view returns (uint256) {
        return _reservationAt(indexOf(agent));
    }

    function spentOf(address agent) external view returns (uint256) {
        if (!isAgent(agent)) revert NotAgent(agent);
        return _spentIn[currentWindowId()][agent];
    }

    function surplusUsed() external view returns (uint256) {
        return _surplusUsedIn[currentWindowId()];
    }

    function reservedTotal() public view returns (uint256) {
        return (budget * rhoNum) / rhoDen;
    }

    function surplusCap() public view returns (uint256) {
        return budget - reservedTotal();
    }

    /// Spec 1.4: the first R mod N delegates hold one unit more than the rest.
    function _reservationAt(uint256 idx) private view returns (uint256) {
        uint256 R = reservedTotal();
        uint256 base = R / agentCount;
        uint256 rem = R % agentCount;
        return idx < rem ? base + 1 : base;
    }
}
