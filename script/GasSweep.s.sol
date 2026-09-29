// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// Gas sweep over N (Layout v1.1 H2/H7 matrix) and rho in {0, 1/2, 1}.
/// Every deployment and every payment is its own broadcast transaction, so storage warmth
/// follows real per-transaction EIP-2929 access lists. gasUsed is read from the receipts
/// by analysis/gas_sweep.py. Accounts come from anvil's default mnemonic; start anvil with
/// at least 51 accounts (see run_gas_sweep.sh).
///
/// Per configuration, in order: deploy; prefund; delegate idx N-1 pays three times; delegate idx 0 pays once.
/// Every payment is 1 USDC (1e6) to the same merchant, whose token balance is made non-zero
/// before the sweep so that the recipient-side token write is the same kind in every payment.
contract GasSweep is Script {
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";
    uint256 internal constant BUDGET = 1e12; // 1,000,000 USDC at 6 decimals (Layout v1.1 performance matrix)
    uint256 internal constant WINDOW = 1 days;
    uint256 internal constant AMOUNT = 1e6;
    address internal constant MERCHANT = address(0xBEEF);

    function run() external {
        uint256 deployerKey = vm.deriveKey(MNEMONIC, 0);

        vm.startBroadcast(deployerKey);
        MockUSDC usdc = new MockUSDC();
        usdc.mint(MERCHANT, 1);
        vm.stopBroadcast();

        uint256[5] memory ns = [uint256(2), 5, 10, 20, 50];
        uint256[3] memory rhoNums = [uint256(0), 1, 2]; // rho = rhoNum / 2

        for (uint256 a = 0; a < ns.length; ++a) {
            for (uint256 b = 0; b < rhoNums.length; ++b) {
                _runConfig(usdc, deployerKey, ns[a], rhoNums[b]);
            }
        }
    }

    function _runConfig(MockUSDC usdc, uint256 deployerKey, uint256 n, uint256 rhoNum) internal {
        address[] memory agents = new address[](n);
        uint256[] memory keys = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            keys[i] = vm.deriveKey(MNEMONIC, uint32(1 + i));
            agents[i] = vm.addr(keys[i]);
        }

        vm.startBroadcast(deployerKey);
        SpendPartition sp = new SpendPartition(IERC20(address(usdc)), agents, BUDGET, rhoNum, 2, WINDOW);
        usdc.mint(address(sp), BUDGET);
        vm.stopBroadcast();

        for (uint256 k = 0; k < 3; ++k) {
            vm.broadcast(keys[n - 1]);
            sp.pay(MERCHANT, AMOUNT);
        }
        vm.broadcast(keys[0]);
        sp.pay(MERCHANT, AMOUNT);
    }
}
