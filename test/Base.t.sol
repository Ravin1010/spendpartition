// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

abstract contract SPBase is Test {
    MockUSDC internal usdc;

    address internal constant MERCHANT = address(0xBEEF);
    uint256 internal constant WINDOW = 7 days;

    /// Storage slot of `_agentState` (mapping) and `_surplus` in SpendPartition.
    uint256 internal constant AGENT_MAPPING_SLOT = 0;
    bytes32 internal constant SURPLUS_SLOT = bytes32(uint256(1));

    function _agents(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = address(uint160(0xA000 + i));
        }
    }

    /// Deploys with a fixed window and prefunds the contract so that liquidity never binds
    /// (the I2 premise "principal-controlled balance is sufficient", Layout v1.1 Part 5).
    function _deploy(address[] memory ag, uint256 budget, uint256 rhoNum, uint256 rhoDen)
        internal
        returns (SpendPartition sp)
    {
        sp = new SpendPartition(IERC20(address(usdc)), ag, budget, rhoNum, rhoDen, WINDOW);
        usdc.mint(address(sp), budget * 64);
    }

    /// Payment by `agent`; returns whether the call was accepted.
    function _pay(SpendPartition sp, address agent, uint256 amount) internal returns (bool ok) {
        vm.prank(agent);
        try sp.pay(MERCHANT, amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _sumSpent(SpendPartition sp, address[] memory ag) internal view returns (uint256 s) {
        for (uint256 i = 0; i < ag.length; ++i) {
            s += sp.spentOf(ag[i]);
        }
    }

    function _agentKey(address agent) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, AGENT_MAPPING_SLOT));
    }

    /// AgentSlot packing: indexPlusOne bits [0,16), windowId [16,64), spent [64,256).
    function _rawAgent(SpendPartition sp, address agent)
        internal
        view
        returns (uint16 indexPlusOne, uint48 windowId, uint192 spent)
    {
        uint256 v = uint256(vm.load(address(sp), _agentKey(agent)));
        indexPlusOne = uint16(v);
        windowId = uint48(v >> 16);
        spent = uint192(v >> 64);
    }

    /// SurplusSlot packing: windowId bits [0,48), used [48,256).
    function _rawSurplus(SpendPartition sp) internal view returns (uint48 windowId, uint208 used) {
        uint256 v = uint256(vm.load(address(sp), SURPLUS_SLOT));
        windowId = uint48(v);
        used = uint208(v >> 48);
    }
}
