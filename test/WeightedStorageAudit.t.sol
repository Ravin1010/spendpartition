// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SPBase} from "./Base.t.sol";
import {SpendPartitionWeighted} from "../src/SpendPartitionWeighted.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Narrow storage-write audit, with callee gas logged for fixed payment cases.
/// Values include the token transfer; --isolate also includes transaction intrinsic gas.
/// These are observations rather than gas thresholds or baseline measurements.
contract WeightedStorageAuditTest is SPBase {
    SpendPartitionWeighted internal sp;
    address internal agent;

    function setUp() public {
        usdc = new MockUSDC();
        address[] memory ag = _agents(3);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 1;
        weights[1] = 2;
        weights[2] = 3;
        sp = new SpendPartitionWeighted(usdc, ag, weights, 200, 1, 2, WINDOW);
        usdc.mint(address(sp), 2000);
        agent = ag[0]; // reservation = 17
    }

    function test_ReservationOnly_FirstPayment() public {
        _auditPayment(10, false);
    }

    function test_ReservationOnly_RepeatPayment() public {
        vm.prank(agent);
        sp.pay(MERCHANT, 10);
        _auditPayment(1, false);
    }

    function test_ReservationOnly_WindowRollover() public {
        vm.prank(agent);
        sp.pay(MERCHANT, 10);
        vm.warp(sp.startTime() + WINDOW);
        _auditPayment(1, false);
        assertEq(sp.spentOf(agent), 1);
    }

    function test_SurplusPayment_ReservationSlotNotWritten() public {
        _auditPayment(20, true);
    }

    function _auditPayment(uint256 amount, bool usesSurplus) internal {
        bytes32 packedKey = _agentKey(agent);
        bytes32 reservationKey = bytes32(uint256(packedKey) + 1);
        bytes32 reservationBefore = vm.load(address(sp), reservationKey);
        // Cool both contracts to avoid setup/deployment or prior reads warming measured accesses.
        vm.cool(address(sp));
        vm.cool(address(usdc));
        vm.record();
        vm.prank(agent);
        sp.pay(MERCHANT, amount);
        uint256 paymentGas = vm.lastCallGas().gasTotalUsed;
        (, bytes32[] memory writes) = vm.accesses(address(sp));
        emit log_named_uint("pay lastCallGas (cold storage, includes token transfer)", paymentGas);
        emit log_named_uint("packed agent slot write count", _count(writes, packedKey));
        assertEq(_count(writes, packedKey), 1, "packed agent slot written once");
        assertEq(_count(writes, reservationKey), 0, "reservation must never be written by pay");
        assertEq(_count(writes, SURPLUS_SLOT), usesSurplus ? 1 : 0, "surplus write count");
        assertEq(vm.load(address(sp), reservationKey), reservationBefore);
        assertEq(writes.length, _count(writes, packedKey) + (usesSurplus ? 1 : 0), "only accounting slots written");
    }

    function _count(bytes32[] memory slots, bytes32 target) private pure returns (uint256 count) {
        for (uint256 i = 0; i < slots.length; ++i) {
            if (slots[i] == target) ++count;
        }
    }
}
