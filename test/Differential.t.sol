// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpendPartition} from "../src/ISpendPartition.sol";
import {SpendPartition} from "../src/SpendPartition.sol";
import {SpendPartitionReference} from "../src/SpendPartitionReference.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Drives one call sequence into both implementations. Each payment is issued twice, from the
/// same caller with the same amount, once per implementation, and the two outcomes are compared
/// immediately: the success flag, and on rejection the raw return data. Both implementations
/// declare the same error signatures, so identical rejections produce identical selectors and
/// arguments. Payments go to a different merchant per implementation so the two token balances
/// can also be compared.
contract DiffHandler is Test {
    ISpendPartition public immutable opt;
    ISpendPartition public immutable ref;
    address[] internal agents;

    address public constant MERCHANT_OPT = address(0xBEE1);
    address public constant MERCHANT_REF = address(0xBEE2);
    address internal constant STRANGER = address(0xDEAD);

    uint256 public calls;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public rollovers;
    uint256 public strangerCalls;
    uint256 public outOfRangeAmounts;
    bool public mismatch;
    string public mismatchReason;

    uint256 internal _window;

    constructor(ISpendPartition opt_, ISpendPartition ref_, address[] memory agents_) {
        opt = opt_;
        ref = ref_;
        agents = agents_;
    }

    function pay(uint256 callerSeed, uint256 amountSeed) external {
        ++calls;
        address caller = _caller(callerSeed);
        uint256 amount = _amount(amountSeed);

        bytes memory callOpt = abi.encodeCall(ISpendPartition.pay, (MERCHANT_OPT, amount));
        bytes memory callRef = abi.encodeCall(ISpendPartition.pay, (MERCHANT_REF, amount));

        vm.prank(caller);
        (bool okOpt, bytes memory dataOpt) = address(opt).call(callOpt);
        vm.prank(caller);
        (bool okRef, bytes memory dataRef) = address(ref).call(callRef);

        if (okOpt != okRef) {
            _flag(okOpt ? "optimized accepted, reference rejected" : "reference accepted, optimized rejected");
            return;
        }
        if (!okOpt && keccak256(dataOpt) != keccak256(dataRef)) {
            _flag("rejected by both, different revert data");
            return;
        }
        if (okOpt) ++accepted;
        else ++rejected;
    }

    function warp(uint256 timeSeed) external {
        ++calls;
        uint256 d = opt.windowDuration();
        uint256 dt = (timeSeed & 3 != 0) ? bound(timeSeed >> 2, 0, d / 8) : bound(timeSeed >> 2, 0, 3 * d);
        vm.warp(vm.getBlockTimestamp() + dt);

        uint256 w = (vm.getBlockTimestamp() - opt.startTime()) / d;
        if (w != _window) {
            _window = w;
            ++rollovers;
        }
    }

    function agentAt(uint256 i) external view returns (address) {
        return agents[i];
    }

    /// One draw in sixteen comes from an address that was never registered.
    function _caller(uint256 seed) internal returns (address) {
        if (seed % 16 == 0) {
            ++strangerCalls;
            return STRANGER;
        }
        return agents[bound(seed >> 4, 0, agents.length - 1)];
    }

    /// One draw in eight lands outside [1, B_G]; the rest alternate between sub-share and full range.
    function _amount(uint256 seed) internal returns (uint256) {
        uint256 b = opt.budget();
        if (seed % 8 == 0) {
            ++outOfRangeAmounts;
            return (seed >> 3) % 2 == 0 ? 0 : b + 1;
        }
        uint256 hi = (seed & 1 == 0) ? _max(1, b / agents.length) : b;
        return bound(seed >> 3, 1, hi);
    }

    function _flag(string memory reason) internal {
        if (!mismatch) {
            mismatch = true;
            mismatchReason = reason;
        }
    }

    function _max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x : y;
    }
}

abstract contract DifferentialBase is Test {
    MockUSDC internal usdc;
    SpendPartition internal opt;
    SpendPartitionReference internal ref;
    DiffHandler internal handler;
    address[] internal ag;

    uint256 internal constant WINDOW = 7 days;

    function _config() internal pure virtual returns (uint256 n, uint256 budget, uint256 rhoNum, uint256 rhoDen);

    function setUp() public {
        usdc = new MockUSDC();
        (uint256 n, uint256 b, uint256 num, uint256 den) = _config();

        ag = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            ag[i] = address(uint160(0xA000 + i));
        }

        // Both deployed in the same block, so t0 and every window boundary coincide.
        opt = new SpendPartition(IERC20(address(usdc)), ag, b, num, den, WINDOW);
        ref = new SpendPartitionReference(IERC20(address(usdc)), ag, b, num, den, WINDOW);
        usdc.mint(address(opt), b * 1000);
        usdc.mint(address(ref), b * 1000);

        handler = new DiffHandler(ISpendPartition(address(opt)), ISpendPartition(address(ref)), ag);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = DiffHandler.pay.selector;
        selectors[1] = DiffHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function afterInvariant() public {
        string memory row = string.concat(
            vm.toString(ag.length),
            ",",
            vm.toString(opt.budget()),
            ",",
            vm.toString(opt.rhoNum()),
            "/",
            vm.toString(opt.rhoDen()),
            ",",
            vm.toString(handler.calls()),
            ",",
            vm.toString(handler.accepted()),
            ",",
            vm.toString(handler.rejected()),
            ",",
            vm.toString(handler.rollovers()),
            ",",
            vm.toString(handler.strangerCalls()),
            ",",
            vm.toString(handler.outOfRangeAmounts())
        );
        vm.writeLine("results/differential_coverage.csv", row);
    }

    /// Every externally observable value of the two implementations, after every handler call.
    function invariant_ImplementationsAgree() public view {
        assertFalse(handler.mismatch(), handler.mismatchReason());

        ISpendPartition o = ISpendPartition(address(opt));
        ISpendPartition r = ISpendPartition(address(ref));

        assertEq(o.currentWindowId(), r.currentWindowId(), "currentWindowId");
        assertEq(o.surplusUsed(), r.surplusUsed(), "surplusUsed");
        assertEq(o.reservedTotal(), r.reservedTotal(), "reservedTotal");
        assertEq(o.surplusCap(), r.surplusCap(), "surplusCap");

        for (uint256 i = 0; i < ag.length; ++i) {
            assertEq(o.spentOf(ag[i]), r.spentOf(ag[i]), "spentOf");
            assertEq(o.reservationOf(ag[i]), r.reservationOf(ag[i]), "reservationOf");
            assertEq(o.indexOf(ag[i]), r.indexOf(ag[i]), "indexOf");
        }

        assertEq(
            usdc.balanceOf(handler.MERCHANT_OPT()),
            usdc.balanceOf(handler.MERCHANT_REF()),
            "value transferred out"
        );
    }
}

contract Differential_N2_B1000_Rho0 is DifferentialBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (2, 1000, 0, 1);
    }
}

contract Differential_N3_B100_Rho1over2 is DifferentialBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (3, 100, 1, 2);
    }
}

contract Differential_N3_B100_Rho1 is DifferentialBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (3, 100, 1, 1);
    }
}

contract Differential_N5_B101_Rho1over4 is DifferentialBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (5, 101, 1, 4);
    }
}

contract Differential_N10_B2pow64_Rho3over4 is DifferentialBase {
    function _config() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (10, type(uint64).max, 3, 4);
    }
}
