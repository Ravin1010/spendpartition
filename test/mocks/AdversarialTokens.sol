// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISpendPartition} from "../../src/ISpendPartition.sol";

/// Token whose `transfer` calls back into a target before the balances move. Layout v1.1 Part 5
/// keeps the payment contract's interaction last; these mocks are what tests that ordering.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public callbackData;
    bool public armed;

    /// Recorded during the callback, i.e. while the outer payment is still executing.
    bool public callbackRan;
    bool public callbackSucceeded;
    bytes public callbackReturnData;

    constructor() ERC20("Reentrant Token", "REENT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @param target_ contract the callback calls
    /// @param data calldata used for the callback
    /// @param bubble true reverts the transfer with the callback's revert data, false records it and continues
    function arm(address target_, bytes calldata data, bool bubble) external {
        target = target_;
        callbackData = data;
        armed = true;
        _bubble = bubble;
    }

    function disarm() external {
        armed = false;
    }

    bool private _bubble;

    function transfer(address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false; // one callback per armed transfer
            callbackRan = true;
            (bool ok, bytes memory ret) = target.call(callbackData);
            callbackSucceeded = ok;
            callbackReturnData = ret;
            if (!ok && _bubble) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return super.transfer(to, value);
    }
}

/// `transfer` always reverts.
contract RevertingToken is ERC20 {
    error TransferRefused();

    constructor() ERC20("Reverting Token", "REVERT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert TransferRefused();
    }
}

/// `transfer` moves nothing and returns false, the non-compliant pattern SafeERC20 exists for.
contract FalseReturningToken is ERC20 {
    constructor() ERC20("False Token", "FALSE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// A delegate that is itself a contract, so a token callback can re-enter the payment path under
/// the delegate's own authority. A token calling back on its own account cannot: it was never
/// registered, and the payment path rejects it.
contract ReentrantDelegate {
    function payOnce(ISpendPartition sp, address to, uint256 amount) external {
        sp.pay(to, amount);
    }

    /// Entry point the armed token calls while the outer transfer is in flight.
    function reenter(ISpendPartition sp, address to, uint256 amount) external {
        sp.pay(to, amount);
    }
}
