// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LotteryTestBase} from "./helpers/LotteryTestBase.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {BlockhashLottery} from "../src/BlockhashLottery.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract FactoryHarness {
    function deploy() external returns (LaunchToken token, BlockhashLottery lottery) {
        token = new LaunchToken();
        lottery = new BlockhashLottery(address(token));
    }
}

contract BlockhashLotteryTest is LotteryTestBase {
    event Bought(uint256 indexed r, address indexed buyer, uint256 count, uint256 endIndex);
    event Settled(uint256 indexed r, address indexed winner, uint256 prize, uint256 carryOut);
    event Expired(uint256 indexed r);
    event Claimed(address indexed account, uint256 amount);

    function testFactoryDeploymentNeedsNoFundingAndPreservesSupply() public {
        FactoryHarness factory = new FactoryHarness();
        (LaunchToken deployedToken, BlockhashLottery deployedLottery) = factory.deploy();
        assertEq(deployedToken.balanceOf(address(factory)), 1e27);
        assertEq(deployedToken.totalSupply(), 1e27);
        assertEq(deployedToken.balanceOf(address(deployedLottery)), 0);
        assertEq(address(deployedLottery.token()), address(deployedToken));
        assertEq(deployedLottery.deploymentBlock(), block.number);
        _assertRuntime(address(deployedToken));
        _assertRuntime(address(deployedLottery));
    }

    function testConstructorRejectsMissingTokenCode() public {
        vm.expectRevert(BlockhashLottery.InvalidToken.selector);
        new BlockhashLottery(address(0));
        vm.expectRevert(BlockhashLottery.InvalidToken.selector);
        new BlockhashLottery(ALICE);
    }

    function testRoundWindowsAndBuysAfterCloseGoToNextRound() public {
        assertEq(lottery.currentRound(), 0);
        assertEq(lottery.closeBlock(0), genesis + 299);
        assertEq(lottery.drawBlock(0), genesis + 304);
        _buy(ALICE, 1);
        vm.roll(genesis + 299);
        _buy(BOB, 2);
        vm.roll(genesis + 300);
        assertEq(lottery.currentRound(), 1);
        _buy(ALICE, 3);
        assertEq(lottery.ticketsOf(0, ALICE), 1);
        assertEq(lottery.ticketsOf(0, BOB), 2);
        assertEq(lottery.ticketsOf(1, ALICE), 3);
        _assertRound(0, 3, 0, BlockhashLottery.State.Unsettled);
        _assertRound(1, 3, 0, BlockhashLottery.State.Unsettled);
        _assertConserved();
    }

    function testBoughtEventAndCumulativePurchases() public {
        vm.expectEmit(true, true, false, true, address(lottery));
        emit Bought(0, ALICE, 2, 2);
        _buy(ALICE, 2);
        _buy(BOB, 3);
        vm.expectEmit(true, true, false, true, address(lottery));
        emit Bought(0, ALICE, 4, 9);
        _buy(ALICE, 4);
        assertEq(lottery.ticketsOf(0, ALICE), 6);
        _assertRound(0, 9, 0, BlockhashLottery.State.Unsettled);
        _assertConserved();
    }

    function testFuzzBuyWithinBounds(uint256 count) public {
        count = bound(count, 1, 100);
        uint256 beforeBalance = token.balanceOf(ALICE);
        _buy(ALICE, count);
        assertEq(token.balanceOf(ALICE), beforeBalance - count * PRICE);
        assertEq(lottery.ticketsOf(0, ALICE), count);
        _assertConserved();
    }

    function testRejectsInvalidCount() public {
        vm.expectRevert(BlockhashLottery.InvalidTicketCount.selector);
        lottery.buy(0);
        vm.expectRevert(BlockhashLottery.InvalidTicketCount.selector);
        lottery.buy(101);
        vm.expectRevert(BlockhashLottery.InvalidTicketCount.selector);
        lottery.buy(type(uint256).max);
        _assertConserved();
    }

    function testInsufficientAllowanceRollsBackPurchase() public {
        vm.prank(ALICE);
        token.approve(address(lottery), PRICE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(lottery), PRICE - 1, PRICE)
        );
        _buy(ALICE, 1);
        assertEq(lottery.ticketsOf(0, ALICE), 0);
        _assertRound(0, 0, 0, BlockhashLottery.State.Unsettled);
        _assertConserved();
    }

    function testInsufficientBalanceRollsBackPurchase() public {
        uint256 balance = token.balanceOf(ALICE);
        vm.prank(ALICE);
        token.transfer(BOB, balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, PRICE));
        _buy(ALICE, 1);
        assertEq(lottery.ticketsOf(0, ALICE), 0);
        _assertConserved();
    }

    function testCannotSettleBeforeOrAtDrawBlock() public {
        _buy(ALICE, 1);
        vm.expectRevert(BlockhashLottery.TooEarly.selector);
        lottery.settle(0);
        vm.roll(lottery.drawBlock(0) - 1);
        vm.expectRevert(BlockhashLottery.TooEarly.selector);
        lottery.settle(0);
        vm.roll(lottery.drawBlock(0));
        vm.expectRevert(BlockhashLottery.TooEarly.selector);
        lottery.settle(0);
        vm.expectRevert(BlockhashLottery.TooEarly.selector);
        lottery.settle(1);
        _assertConserved();
    }

    function testDrawAtFirstValidBlockAndOneTicketWins() public {
        _buy(ALICE, 1);
        vm.expectEmit(true, true, false, true, address(lottery));
        emit Settled(0, ALICE, 950e18, 50e18);
        _draw(0, 1, bytes32(uint256(123)));
        (,,, address winner, uint256 prize) = lottery.roundInfo(0);
        assertEq(winner, ALICE);
        assertEq(prize, 950e18);
        assertEq(lottery.claimable(ALICE), prize);
        _assertRound(1, 0, 50e18, BlockhashLottery.State.Unsettled);
        _assertConserved();
        vm.expectEmit(true, false, false, true, address(lottery));
        emit Claimed(ALICE, prize);
        _claim(ALICE);
        assertEq(token.balanceOf(ALICE), 1_000_000e18 - 50e18);
        _assertConserved();
    }

    function testDrawAtLastValidBlock() public {
        _buy(BOB, 1);
        _draw(0, 256, bytes32(uint256(987)));
        _assertRound(0, 1, 0, BlockhashLottery.State.Settled);
        assertEq(lottery.claimable(BOB), 950e18);
        _assertConserved();
    }

    function testZeroHashDoesNotDrawOrExpireBeforeTimeout() public {
        _buy(ALICE, 1);
        uint256 draw = lottery.drawBlock(0);
        vm.roll(draw + 1);
        vm.setBlockhash(draw, bytes32(0));
        vm.expectRevert(BlockhashLottery.HashUnavailable.selector);
        lottery.settle(0);
        vm.roll(draw + 256);
        vm.setBlockhash(draw, bytes32(0));
        vm.expectRevert(BlockhashLottery.HashUnavailable.selector);
        lottery.settle(0);
        _assertRound(0, 1, 0, BlockhashLottery.State.Unsettled);
        vm.expectRevert(BlockhashLottery.NotExpired.selector);
        _refund(0, ALICE);
        vm.roll(draw + 257);
        lottery.settle(0);
        _refund(0, ALICE);
        assertEq(lottery.claimable(ALICE), PRICE);
        _assertConserved();
    }

    function testZeroHashCanBeRetriedWithAvailableHash() public {
        _buy(ALICE, 1);
        vm.roll(lottery.drawBlock(0) + 1);
        vm.setBlockhash(lottery.drawBlock(0), bytes32(0));
        vm.expectRevert(BlockhashLottery.HashUnavailable.selector);
        lottery.settle(0);
        vm.setBlockhash(lottery.drawBlock(0), bytes32(uint256(1)));
        lottery.settle(0);
        assertEq(lottery.claimable(ALICE), 950e18);
        _assertConserved();
    }

    function testExpiresAt257AndRefundsAllPurchasesOnce() public {
        _buy(ALICE, 2);
        _buy(BOB, 4);
        _buy(ALICE, 3);
        vm.roll(lottery.drawBlock(0) + 257);
        vm.expectEmit(true, false, false, true, address(lottery));
        emit Expired(0);
        lottery.settle(0);
        _assertRound(0, 9, 0, BlockhashLottery.State.Expired);
        _assertConserved();
        _refund(0, ALICE);
        assertEq(lottery.claimable(ALICE), 5 * PRICE);
        assertEq(lottery.ticketsOf(0, ALICE), 5);
        _assertConserved();
        vm.expectRevert(BlockhashLottery.AlreadyRefunded.selector);
        _refund(0, ALICE);
        vm.expectRevert(BlockhashLottery.NothingToRefund.selector);
        _refund(0, CAROL);
        _refund(0, BOB);
        _claim(ALICE);
        _claim(BOB);
        assertEq(token.balanceOf(ALICE), 1_000_000e18);
        assertEq(token.balanceOf(BOB), 1_000_000e18);
        assertEq(token.balanceOf(address(lottery)), 0);
        _assertConserved();
    }

    function testRefundRequiresExpiredStateEvenAfterDeadline() public {
        _buy(ALICE, 1);
        vm.expectRevert(BlockhashLottery.NotExpired.selector);
        _refund(0, ALICE);
        vm.roll(lottery.drawBlock(0) + 257);
        vm.expectRevert(BlockhashLottery.NotExpired.selector);
        _refund(0, ALICE);
        lottery.settle(0);
        _refund(0, ALICE);
        _assertConserved();
    }

    function testCannotRefundWinningOrLosingTicketsAfterDraw() public {
        _buy(ALICE, 1);
        _buy(BOB, 1);
        _draw(0, 1, bytes32(uint256(456)));
        vm.expectRevert(BlockhashLottery.NotExpired.selector);
        _refund(0, ALICE);
        vm.expectRevert(BlockhashLottery.NotExpired.selector);
        _refund(0, BOB);
        _assertConserved();
    }

    function testDoubleSettlementRevertsForDrawnExpiredAndEmptyRounds() public {
        _buy(ALICE, 1);
        _draw(0, 1, bytes32(uint256(789)));
        vm.expectRevert(BlockhashLottery.AlreadySettled.selector);
        lottery.settle(0);
        _buy(BOB, 1);
        vm.roll(lottery.drawBlock(1) + 257);
        lottery.settle(1);
        vm.expectRevert(BlockhashLottery.AlreadySettled.selector);
        lottery.settle(1);
        vm.roll(lottery.drawBlock(2) + 1);
        lottery.settle(2);
        vm.expectRevert(BlockhashLottery.AlreadySettled.selector);
        lottery.settle(2);
        _assertConserved();
    }

    function testEmptyRoundForwardsCarryWithoutHashToOpenRound() public {
        _buy(ALICE, 1);
        _draw(0, 1, bytes32(uint256(321)));
        vm.roll(lottery.drawBlock(1) + 1);
        lottery.settle(1);
        _assertRound(1, 0, 0, BlockhashLottery.State.Settled);
        _assertRound(2, 0, 50e18, BlockhashLottery.State.Unsettled);
        vm.roll(genesis + 1_500);
        lottery.settle(2);
        _assertRound(5, 0, 50e18, BlockhashLottery.State.Unsettled);
        _assertConserved();
    }

    function testCarryIncludedInNextPrize() public {
        _buy(ALICE, 1);
        _draw(0, 1, bytes32(uint256(111)));
        _buy(BOB, 1);
        _draw(1, 1, bytes32(uint256(222)));
        assertEq(lottery.claimable(BOB), 9975e17);
        _assertRound(2, 0, 525e17, BlockhashLottery.State.Unsettled);
        _assertConserved();
    }

    function testFuzzCarryAndRefundAccountingAcrossSettlementOrder(bool reverse) public {
        _buy(ALICE, 1);
        _draw(0, 1, bytes32(uint256(1)));
        _buy(BOB, 2);
        vm.roll(genesis + 600);
        _buy(CAROL, 3);
        vm.roll(lottery.drawBlock(2) + 1);
        vm.setBlockhash(lottery.drawBlock(2), bytes32(uint256(2)));
        lottery.settle(reverse ? 2 : 1);
        _assertConserved();
        lottery.settle(reverse ? 1 : 2);
        _assertConserved();
        _assertRound(3, 0, 200e18, BlockhashLottery.State.Unsettled);
        assertEq(lottery.claimable(CAROL), 2850e18);
        _refund(1, BOB);
        assertEq(lottery.claimable(BOB), 2 * PRICE);
        _claim(ALICE);
        _claim(BOB);
        _claim(CAROL);
        _assertConserved();
        assertEq(token.balanceOf(address(lottery)), 200e18);
    }

    function testClaimAggregatesRefundsAndWinningsAndCannotRepeat() public {
        _buy(ALICE, 1);
        _draw(0, 1, bytes32(uint256(100)));
        _buy(ALICE, 2);
        vm.roll(lottery.drawBlock(1) + 257);
        lottery.settle(1);
        _refund(1, ALICE);
        assertEq(lottery.claimable(ALICE), 2950e18);
        _claim(ALICE);
        vm.expectRevert(BlockhashLottery.NothingToClaim.selector);
        _claim(ALICE);
        vm.expectRevert(BlockhashLottery.NothingToClaim.selector);
        _claim(BOB);
        _assertConserved();
    }

    function testCannotBuyOldRoundAfterSeeingHash() public {
        _buy(ALICE, 1);
        vm.roll(lottery.drawBlock(0) + 1);
        vm.setBlockhash(lottery.drawBlock(0), bytes32(uint256(123)));
        _buy(BOB, 100);
        lottery.settle(0);
        assertEq(lottery.ticketsOf(0, BOB), 0);
        assertEq(lottery.ticketsOf(1, BOB), 100);
        assertEq(lottery.claimable(ALICE), 950e18);
        _assertConserved();
    }

    function testRejectsETHAndUnknownCalls() public {
        vm.deal(address(this), 10);
        (bool receiveSuccess,) = address(lottery).call{value: 1}("");
        (bool payableBuy,) = address(lottery).call{value: 1}(abi.encodeCall(lottery.buy, (1)));
        (bool fallbackSuccess,) = address(lottery).call(hex"12345678");
        (bool adminSuccess,) = address(lottery).call(abi.encodeWithSignature("transferOwnership(address)", ALICE));
        assertFalse(receiveSuccess);
        assertFalse(payableBuy);
        assertFalse(fallbackSuccess);
        assertFalse(adminSuccess);
        assertEq(address(lottery).balance, 0);
    }

    function testUnsolicitedTokensAreSurplusNotTicketsOrPrize() public {
        _buy(ALICE, 1);
        token.transfer(address(lottery), 7);
        _draw(0, 1, bytes32(uint256(8)));
        assertEq(lottery.claimable(ALICE), 950e18);
        assertEq(token.balanceOf(address(lottery)), lottery.totalClaimable() + lottery.totalReserved() + 7);
    }
}
