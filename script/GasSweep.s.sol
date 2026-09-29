// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {SpendPartitionReference} from "../src/SpendPartitionReference.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {BatchDelegate} from "../test/mocks/BatchDelegate.sol";
import {ISpendPartition} from "../src/ISpendPartition.sol";

/// Gas sweep over N (Layout v1.1 H2/H7 matrix) and rho in {0, 1/2, 1}.
/// Every deployment and every payment is its own broadcast transaction, so storage warmth
/// follows real per-transaction EIP-2929 access lists. gasUsed is read from the receipts
/// by analysis/gas_sweep.py. Accounts come from anvil's default mnemonic; start anvil with
/// at least 51 accounts (see run_gas_sweep.sh).
///
/// Phase 1, per configuration, in order: deploy; prefund; delegate idx N-1 pays three times;
/// delegate idx 0 pays once.
/// Phase 2 repeats the same shape on SpendPartitionReference (H6).
/// Phase 3 uses a one-second window so that consecutive transactions land in different windows and
/// the first write of a new window is measured on a live chain (H1 third regime); anvil advances
/// the block timestamp by one second per block.
/// Phase 4 sends a payment of exactly r_i + 1 so that one payment straddles the reservation
/// boundary (H4).
/// Every payment is 1 USDC (1e6) to the same merchant, whose token balance is made non-zero
/// before the sweep so that the recipient-side token write is the same kind in every payment.
contract GasSweep is Script {
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";
    uint256 internal constant BUDGET = 1e12; // 1,000,000 USDC at 6 decimals (Layout v1.1 performance matrix)
    uint256 internal constant WINDOW = 1 days;
    uint256 internal constant AMOUNT = 1e6;
    address internal constant MERCHANT = address(0xBEEF);
    string internal constant TOKEN_FILE = "results/sweep_token.txt";
    string internal constant ROLLOVER_FILE = "results/rollover_targets.txt";

    function run() external {
        uint256 deployerKey = vm.deriveKey(MNEMONIC, 0);

        vm.startBroadcast(deployerKey);
        MockUSDC usdc = new MockUSDC();
        usdc.mint(MERCHANT, 1);
        vm.stopBroadcast();
        vm.writeFile(TOKEN_FILE, string.concat(vm.toString(address(usdc)), "\n"));

        uint256[5] memory ns = [uint256(2), 5, 10, 20, 50];
        uint256[3] memory rhoNums = [uint256(0), 1, 2]; // rho = rhoNum / 2

        // Phase 1: optimised implementation.
        for (uint256 a = 0; a < ns.length; ++a) {
            for (uint256 b = 0; b < rhoNums.length; ++b) {
                _runConfig(usdc, deployerKey, ns[a], rhoNums[b], WINDOW);
            }
        }

        // Phase 2: reference implementation, same shape.
        for (uint256 a = 0; a < ns.length; ++a) {
            _runReferenceConfig(usdc, deployerKey, ns[a], 1);
            _runReferenceConfig(usdc, deployerKey, ns[a], 0);
        }

        // Phase 4: payments that straddle the reservation boundary.
        _runSpillConfig(usdc, deployerKey, 2);
        _runSpillConfig(usdc, deployerKey, 10);

        // Phase 5: k payments in one transaction against the same k as separate transactions.
        _runBatchConfig(usdc, deployerKey, 0);
        _runBatchConfig(usdc, deployerKey, 2);
    }

    function _runConfig(MockUSDC usdc, uint256 deployerKey, uint256 n, uint256 rhoNum, uint256 window) internal {
        (address[] memory agents, uint256[] memory keys) = _delegates(n);

        vm.startBroadcast(deployerKey);
        SpendPartition sp = new SpendPartition(IERC20(address(usdc)), agents, BUDGET, rhoNum, 2, window);
        usdc.mint(address(sp), BUDGET);
        vm.stopBroadcast();

        for (uint256 k = 0; k < 3; ++k) {
            vm.broadcast(keys[n - 1]);
            sp.pay(MERCHANT, AMOUNT);
        }
        vm.broadcast(keys[0]);
        sp.pay(MERCHANT, AMOUNT);
    }

    function _runReferenceConfig(MockUSDC usdc, uint256 deployerKey, uint256 n, uint256 rhoNum) internal {
        (address[] memory agents, uint256[] memory keys) = _delegates(n);

        vm.startBroadcast(deployerKey);
        SpendPartitionReference sp =
            new SpendPartitionReference(IERC20(address(usdc)), agents, BUDGET, rhoNum, 2, WINDOW);
        usdc.mint(address(sp), BUDGET);
        vm.stopBroadcast();

        for (uint256 k = 0; k < 3; ++k) {
            vm.broadcast(keys[n - 1]);
            sp.pay(MERCHANT, AMOUNT);
        }
        vm.broadcast(keys[0]);
        sp.pay(MERCHANT, AMOUNT);
    }

    /// Phase 3 is driven from run_gas_sweep.sh, which advances the chain clock between calls:
    /// `rolloverDeploy` creates two one-second-window contracts and records their addresses,
    /// `rolloverPay` sends one payment to each. Every payment therefore lands in a window of its
    /// own, and the first write of a new window is measured on a live chain.
    function rolloverDeploy() external {
        uint256 deployerKey = vm.deriveKey(MNEMONIC, 0);
        MockUSDC usdc = MockUSDC(vm.parseAddress(vm.readLine(TOKEN_FILE)));

        string memory out = "";
        uint256[2] memory ns = [uint256(2), 10];
        for (uint256 i = 0; i < ns.length; ++i) {
            (address[] memory agents,) = _delegates(ns[i]);
            vm.startBroadcast(deployerKey);
            SpendPartition sp = new SpendPartition(IERC20(address(usdc)), agents, BUDGET, 0, 2, 1);
            usdc.mint(address(sp), BUDGET);
            vm.stopBroadcast();
            out = string.concat(out, vm.toString(address(sp)), "\n");
        }
        vm.writeFile(ROLLOVER_FILE, out);
    }

    function rolloverPay() external {
        uint256[2] memory ns = [uint256(2), 10];
        for (uint256 i = 0; i < ns.length; ++i) {
            address target = vm.parseAddress(vm.readLine(ROLLOVER_FILE));
            (, uint256[] memory keys) = _delegates(ns[i]);
            vm.broadcast(keys[ns[i] - 1]);
            SpendPartition(target).pay(MERCHANT, AMOUNT);
        }
        vm.closeFile(ROLLOVER_FILE);
    }

    /// rho = 1/2, and the payment is one unit past the payer's reservation.
    function _runSpillConfig(MockUSDC usdc, uint256 deployerKey, uint256 n) internal {
        (address[] memory agents, uint256[] memory keys) = _delegates(n);

        vm.startBroadcast(deployerKey);
        SpendPartition sp = new SpendPartition(IERC20(address(usdc)), agents, BUDGET, 1, 2, WINDOW);
        usdc.mint(address(sp), BUDGET);
        vm.stopBroadcast();

        uint256 straddling = sp.reservationOf(agents[n - 1]) + 1;
        vm.broadcast(keys[n - 1]);
        sp.pay(MERCHANT, straddling); // reservation exhausted, one unit from the surplus

        vm.broadcast(keys[n - 1]);
        sp.pay(MERCHANT, AMOUNT); // entirely from the surplus now
    }

    /// N = 10, one delegate being a contract that loops over pay(). Each k is measured twice: once
    /// as a single transaction issuing k payments, once as k transactions issuing one payment each.
    /// A warm-up payment runs first so that the contract's first surplus write, which is the only
    /// zero-to-non-zero write it ever does, does not land inside a measured group.
    function _runBatchConfig(MockUSDC usdc, uint256 deployerKey, uint256 rhoNum) internal {
        uint256 n = 10;
        (address[] memory eoas, uint256[] memory keys) = _delegates(n);

        vm.broadcast(deployerKey);
        BatchDelegate batcher = new BatchDelegate();

        address[] memory agents = new address[](n);
        agents[0] = address(batcher);
        for (uint256 i = 1; i < n; ++i) {
            agents[i] = eoas[i];
        }

        vm.startBroadcast(deployerKey);
        SpendPartition sp = new SpendPartition(IERC20(address(usdc)), agents, BUDGET, rhoNum, 2, WINDOW);
        usdc.mint(address(sp), BUDGET);
        vm.stopBroadcast();

        vm.broadcast(keys[1]);
        sp.pay(MERCHANT, AMOUNT); // warm-up

        uint256[5] memory ks = [uint256(1), 2, 4, 8, 16];
        for (uint256 j = 0; j < ks.length; ++j) {
            vm.broadcast(keys[0]);
            batcher.payMany(ISpendPartition(address(sp)), MERCHANT, AMOUNT, ks[j]);

            for (uint256 i = 0; i < ks[j]; ++i) {
                vm.broadcast(keys[1]);
                sp.pay(MERCHANT, AMOUNT);
            }
        }
    }

    function _delegates(uint256 n) internal returns (address[] memory agents, uint256[] memory keys) {
        agents = new address[](n);
        keys = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            keys[i] = vm.deriveKey(MNEMONIC, uint32(1 + i));
            agents[i] = vm.addr(keys[i]);
        }
    }
}
