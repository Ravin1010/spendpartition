// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISpendPartition} from "../../src/ISpendPartition.sol";

/// A delegate that is a contract, so that k payments can be issued inside one transaction. Used by
/// the batching microbenchmark: the same k payments sent as k separate transactions pay the
/// intrinsic transaction cost k times and touch every storage slot cold each time.
contract BatchDelegate {
    function payMany(ISpendPartition sp, address to, uint256 amount, uint256 k) external {
        for (uint256 i = 0; i < k; ++i) {
            sp.pay(to, amount);
        }
    }
}
