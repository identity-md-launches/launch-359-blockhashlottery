// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BlockhashLottery} from "../src/BlockhashLottery.sol";
import {AdversarialToken} from "./helpers/AdversarialToken.sol";

contract TransferSafetyTest is Test {
    AdversarialToken internal token;
    BlockhashLottery internal lottery;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant PRICE = 1_000e18;

    function setUp() public {
        vm.roll(100);
        token = new AdversarialToken();
        lottery = new BlockhashLottery(address(token));
        token.transfer(ALICE, 100 * PRICE);
        token.transfer(BOB, 100 * PRICE);
        vm.prank(ALICE);
        token.approve(address(lottery), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(lottery), type(uint256).max);
    }

    function _win() internal {
        vm.prank(ALICE);
        lottery.buy(1);
        uint256 draw = lottery.drawBlock(0);
        vm.roll(draw + 1);
        vm.setBlockhash(draw, bytes32(uint256(123)));
        lottery.settle(0);
    }

    function testFalseReturningDepositCreatesNoTicketsOrLiabilities() public {
        token.configure(AdversarialToken.Failure.FalseReturn, AdversarialToken.Failure.None, address(0), false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        lottery.buy(1);
        assertEq(lottery.ticketsOf(0, ALICE), 0);
        (uint256 tickets,,,,) = lottery.roundInfo(0);
        assertEq(tickets, 0);
        assertEq(lottery.totalReserved(), 0);
        assertEq(token.balanceOf(address(lottery)), 0);
    }

    function testRevertingDepositRollsBack() public {
        token.configure(AdversarialToken.Failure.Revert, AdversarialToken.Failure.None, address(0), false);
        vm.prank(ALICE);
        vm.expectRevert(AdversarialToken.MockFailure.selector);
        lottery.buy(1);
        assertEq(lottery.ticketsOf(0, ALICE), 0);
        assertEq(lottery.totalReserved(), 0);
    }

    function testFalseReturningClaimPreservesCreditAndCanRetry() public {
        _win();
        token.configure(AdversarialToken.Failure.None, AdversarialToken.Failure.FalseReturn, address(0), false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        lottery.claim();
        assertEq(lottery.claimable(ALICE), 950e18);
        assertEq(lottery.totalClaimable(), 950e18);
        assertEq(token.balanceOf(address(lottery)), PRICE);
        token.configure(AdversarialToken.Failure.None, AdversarialToken.Failure.None, address(0), false);
        vm.prank(ALICE);
        lottery.claim();
        assertEq(lottery.claimable(ALICE), 0);
        assertEq(token.balanceOf(address(lottery)), 50e18);
    }

    function testRevertingClaimPreservesCredit() public {
        _win();
        token.configure(AdversarialToken.Failure.None, AdversarialToken.Failure.Revert, address(0), false);
        vm.prank(ALICE);
        vm.expectRevert(AdversarialToken.MockFailure.selector);
        lottery.claim();
        assertEq(lottery.claimable(ALICE), 950e18);
        assertEq(lottery.totalClaimable(), 950e18);
        assertEq(token.balanceOf(address(lottery)), PRICE);
    }

    function testSettlementAndOtherClaimsDoNotDependOnBlockedWinner() public {
        vm.prank(ALICE);
        lottery.buy(1);
        token.configure(AdversarialToken.Failure.None, AdversarialToken.Failure.None, ALICE, false);
        uint256 draw = lottery.drawBlock(0);
        vm.roll(draw + 1);
        vm.setBlockhash(draw, bytes32(uint256(1)));
        lottery.settle(0);
        vm.prank(BOB);
        lottery.buy(1);
        vm.roll(lottery.drawBlock(1) + 257);
        lottery.settle(1);
        vm.prank(BOB);
        lottery.refund(1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        lottery.claim();
        vm.prank(BOB);
        lottery.claim();
        assertEq(token.balanceOf(BOB), 100 * PRICE);
        assertEq(lottery.claimable(ALICE), 950e18);
        assertEq(token.balanceOf(address(lottery)), lottery.totalClaimable() + lottery.totalReserved());
    }

    function testSafeTransfersAcceptEmptyReturnData() public {
        token.configure(AdversarialToken.Failure.None, AdversarialToken.Failure.None, address(0), true);
        _win();
        vm.prank(ALICE);
        lottery.claim();
        assertEq(token.balanceOf(ALICE), 100 * PRICE - 50e18);
        assertEq(lottery.claimable(ALICE), 0);
    }

    function testCallbacksCannotReenterAnyMutationDuringBuy() public {
        bytes[4] memory calls = [
            abi.encodeCall(lottery.buy, (1)),
            abi.encodeCall(lottery.settle, (0)),
            abi.encodeCall(lottery.refund, (0)),
            abi.encodeCall(lottery.claim, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            token.configureCallback(lottery, calls[i]);
            vm.prank(ALICE);
            lottery.buy(1);
            assertFalse(token.callbackSucceeded());
            assertEq(
                token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
        }
        assertEq(lottery.ticketsOf(0, ALICE), 4);
        assertEq(token.balanceOf(address(lottery)), 4 * PRICE);
        assertEq(lottery.totalReserved(), 4 * PRICE);
    }

    function testClaimClearsCreditBeforeTransferAndBlocksReentry() public {
        _win();
        token.configureCallback(lottery, abi.encodeCall(lottery.claim, ()));
        vm.prank(ALICE);
        lottery.claim();
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(token.creditObservedDuringTransfer(), 0);
        assertEq(lottery.claimable(ALICE), 0);
        assertEq(lottery.totalClaimable(), 0);
        assertEq(token.balanceOf(address(lottery)), 50e18);
        assertEq(token.balanceOf(ALICE), 100 * PRICE - 50e18);
    }
}
