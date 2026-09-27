// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BlockhashLottery} from "../../src/BlockhashLottery.sol";

/// @dev Deliberately hostile test dependency, never a deployment artifact.
contract AdversarialToken is ERC20 {
    enum Failure {
        None,
        FalseReturn,
        Revert
    }

    Failure public incomingFailure;
    Failure public outgoingFailure;
    address public blockedRecipient;
    bool public omitReturn;
    BlockhashLottery public target;
    bytes public callback;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public creditObservedDuringTransfer;

    error MockFailure();

    constructor() ERC20("Test only", "TEST") {
        _mint(msg.sender, 1e27);
    }

    function configure(Failure incoming, Failure outgoing, address blocked, bool emptyReturn) external {
        incomingFailure = incoming;
        outgoingFailure = outgoing;
        blockedRecipient = blocked;
        omitReturn = emptyReturn;
    }

    function configureCallback(BlockhashLottery lottery, bytes memory data) external {
        target = lottery;
        callback = data;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (incomingFailure == Failure.Revert) revert MockFailure();
        if (incomingFailure == Failure.FalseReturn) return false;
        super.transferFrom(from, to, value);
        _callback();
        if (omitReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (outgoingFailure == Failure.Revert) revert MockFailure();
        if (outgoingFailure == Failure.FalseReturn || to == blockedRecipient) return false;
        super.transfer(to, value);
        if (address(target) != address(0)) creditObservedDuringTransfer = target.claimable(to);
        _callback();
        if (omitReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function _callback() internal {
        if (callback.length != 0) (callbackSucceeded, callbackResult) = address(target).call(callback);
    }
}
