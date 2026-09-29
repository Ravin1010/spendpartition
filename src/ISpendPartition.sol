// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Entry point and views common to every implementation of Technical Spec v1.1.
/// @dev SpendPartition does not inherit this interface. Leaving that file untouched keeps its
///      bytecode, and with it the gas numbers already measured and published, unchanged.
///      Harnesses reach an implementation by casting its address to this type, which Solidity
///      allows for any address whose function signatures match.
interface ISpendPartition {
    function pay(address recipient, uint256 amount) external;

    function currentWindowId() external view returns (uint48);
    function isAgent(address agent) external view returns (bool);
    function indexOf(address agent) external view returns (uint256);
    function reservationOf(address agent) external view returns (uint256);
    function spentOf(address agent) external view returns (uint256);
    function surplusUsed() external view returns (uint256);

    function budget() external view returns (uint256);
    function agentCount() external view returns (uint256);
    function rhoNum() external view returns (uint256);
    function rhoDen() external view returns (uint256);
    function windowDuration() external view returns (uint256);
    function startTime() external view returns (uint256);
    function reservedTotal() external view returns (uint256);
    function surplusCap() external view returns (uint256);
}
