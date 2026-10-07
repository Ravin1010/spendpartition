// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {SpendPartitionWeighted} from "../src/SpendPartitionWeighted.sol";
import {SpendPartitionWeightedReference} from "../src/SpendPartitionWeightedReference.sol";
import {ISpendPartition} from "../src/ISpendPartition.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// Every creation, funding call and payment is its own broadcast transaction.
/// Receipt parsing validates Paid events and token transfers on the actual Anvil chain.
contract WeightedGasSweep is Script {
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";
    uint256 internal constant BUDGET = 1e12;
    uint256 internal constant AMOUNT = 1e6;
    uint256 internal constant WINDOW = 1 days;
    address internal constant MERCHANT = address(0xBEEF);

    function run() external {
        uint256 key = vm.deriveKey(MNEMONIC, 0);
        vm.startBroadcast(key);
        MockUSDC token = new MockUSDC();
        token.mint(MERCHANT, 1); // Match the frozen baseline's nonzero recipient balance.
        vm.stopBroadcast();
        uint256[5] memory ns = [uint256(2), 5, 10, 20, 50];
        for (uint256 k = 0; k < ns.length; ++k) {
            uint256 n = ns[k];
            address[] memory agents = new address[](n);
            for (uint256 i = 0; i < n; ++i) {
                agents[i] = vm.addr(vm.deriveKey(MNEMONIC, uint32(i + 1)));
            }
            uint256 payerKey = vm.deriveKey(MNEMONIC, uint32(n));
            vm.broadcast(key);
            ISpendPartition baseline = ISpendPartition(address(new SpendPartition(token, agents, BUDGET, 1, 2, WINDOW)));
            _measure(token, baseline, key, payerKey, agents[n - 1]);
            for (uint256 profile = 0; profile < 4; ++profile) {
                uint256[] memory weights = _weights(n, profile);
                vm.broadcast(key);
                ISpendPartition opt =
                    ISpendPartition(address(new SpendPartitionWeighted(token, agents, weights, BUDGET, 1, 2, WINDOW)));
                _measure(token, opt, key, payerKey, agents[n - 1]);
                vm.broadcast(key);
                ISpendPartition ref = ISpendPartition(
                    address(new SpendPartitionWeightedReference(token, agents, weights, BUDGET, 1, 2, WINDOW))
                );
                _measure(token, ref, key, payerKey, agents[n - 1]);
            }
        }
    }

    function _measure(MockUSDC token, ISpendPartition sp, uint256 key, uint256 payerKey, address payer) internal {
        vm.broadcast(key);
        token.mint(address(sp), BUDGET);
        uint256 reservation = sp.reservationOf(payer);
        require(reservation >= 2 * AMOUNT, "fixed payments do not fit reservation");
        vm.broadcast(payerKey);
        sp.pay(MERCHANT, AMOUNT);
        require(sp.spentOf(payer) == AMOUNT && sp.surplusUsed() == 0, "first reservation path");
        vm.broadcast(payerKey);
        sp.pay(MERCHANT, AMOUNT);
        require(sp.spentOf(payer) == 2 * AMOUNT && sp.surplusUsed() == 0, "repeat reservation path");
        uint256 boundary = reservation - sp.spentOf(payer) + 1;
        vm.broadcast(payerKey);
        sp.pay(MERCHANT, boundary);
        require(sp.spentOf(payer) == reservation + 1 && sp.surplusUsed() == 1, "first surplus path");
        vm.broadcast(payerKey);
        sp.pay(MERCHANT, AMOUNT);
        require(sp.surplusUsed() == 1 + AMOUNT && sp.currentWindowId() == 0, "repeat surplus path/window");
    }

    function _weights(uint256 n, uint256 profile) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (profile == 0) weights[i] = 1;
            else if (profile == 1) weights[i] = i % 2 == 0 ? 1 : 2;
            else if (profile == 2) weights[i] = i + 1;
            else weights[i] = i == n - 1 ? 100 * n : 1;
        }
    }
}
