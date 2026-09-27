// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LotteryTestBase} from "./helpers/LotteryTestBase.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {BlockhashLottery} from "../src/BlockhashLottery.sol";

contract LotteryHandler is Test {
    LaunchToken internal immutable token;
    BlockhashLottery internal immutable lottery;
    address[3] internal actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    uint256 internal constant PRICE = 1_000e18;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public totalRefunded;
    // These records come from successful inputs, independently of the lottery's ticket counters.
    mapping(uint256 => uint256) public bought;
    mapping(uint256 => mapping(address => uint256)) public boughtBy;
    mapping(uint256 => uint256) public settlements;
    mapping(uint256 => bool) public expired;
    mapping(uint256 => bytes32) public finalizedInfo;
    mapping(uint256 => mapping(address => uint256)) public refundCredits;

    constructor(LaunchToken draw, BlockhashLottery app) {
        token = draw;
        lottery = app;
    }

    function buy(uint256 actorSeed, uint256 countSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 affordable = token.balanceOf(actor) / PRICE;
        if (affordable == 0) return;
        uint256 count = bound(countSeed, 1, affordable < 100 ? affordable : 100);
        vm.prank(actor);
        lottery.buy(count);
        deposited += count * PRICE;
        uint256 r = (block.number - lottery.deploymentBlock()) / 300;
        bought[r] += count;
        boughtBy[r][actor] += count;
    }

    function invalidBuy(uint256 actorSeed, uint256 countSeed) external {
        uint256 count = countSeed % 2 == 0 ? 0 : bound(countSeed, 101, type(uint256).max);
        vm.prank(actors[actorSeed % 3]);
        vm.expectRevert(BlockhashLottery.InvalidTicketCount.selector);
        lottery.buy(count);
    }

    function advance(uint256 delta) external {
        vm.roll(block.number + bound(delta, 1, 600));
    }

    function settle(uint256 roundSeed, bytes32 hash, bool zeroHash) external {
        uint256 r = roundSeed % (lottery.currentRound() + 1);
        uint256 draw = lottery.deploymentBlock() + 300 * r + 304;
        if (settlements[r] != 0) {
            vm.expectRevert(BlockhashLottery.AlreadySettled.selector);
            lottery.settle(r);
            return;
        }
        if (block.number <= draw) {
            vm.expectRevert(BlockhashLottery.TooEarly.selector);
            lottery.settle(r);
            return;
        }
        if (bought[r] != 0 && block.number <= draw + 256) {
            if (zeroHash) {
                vm.setBlockhash(draw, bytes32(0));
                vm.expectRevert(BlockhashLottery.HashUnavailable.selector);
                lottery.settle(r);
                return;
            }
            vm.setBlockhash(draw, hash == bytes32(0) ? bytes32(uint256(1)) : hash);
        }
        lottery.settle(r);
        settlements[r] += 1;
        expired[r] = bought[r] != 0 && block.number > draw + 256;
        finalizedInfo[r] = roundDigest(r);
        // Retry immediately as well as through randomly generated later calls.
        vm.expectRevert(BlockhashLottery.AlreadySettled.selector);
        lottery.settle(r);
    }

    function refund(uint256 roundSeed, uint256 actorSeed) external {
        uint256 r = roundSeed % (lottery.currentRound() + 1);
        address actor = actors[actorSeed % 3];
        bytes4 expectedError;
        if (!expired[r]) expectedError = BlockhashLottery.NotExpired.selector;
        else if (refundCredits[r][actor] != 0) expectedError = BlockhashLottery.AlreadyRefunded.selector;
        else if (boughtBy[r][actor] == 0) expectedError = BlockhashLottery.NothingToRefund.selector;
        if (expectedError != bytes4(0)) {
            vm.prank(actor);
            vm.expectRevert(expectedError);
            lottery.refund(r);
            return;
        }
        uint256 amount = boughtBy[r][actor] * PRICE;
        uint256 creditBefore = lottery.claimable(actor);
        uint256 balanceBefore = token.balanceOf(address(lottery));
        vm.prank(actor);
        lottery.refund(r);
        assertEq(lottery.claimable(actor), creditBefore + amount, "refund must credit every purchased ticket");
        assertEq(token.balanceOf(address(lottery)), balanceBefore, "refund credits without transferring");
        refundCredits[r][actor] = amount;
        totalRefunded += amount;
        vm.prank(actor);
        vm.expectRevert(BlockhashLottery.AlreadyRefunded.selector);
        lottery.refund(r);
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = lottery.claimable(actor);
        if (amount == 0) {
            vm.prank(actor);
            vm.expectRevert(BlockhashLottery.NothingToClaim.selector);
            lottery.claim();
            return;
        }
        uint256 beforeBalance = token.balanceOf(actor);
        vm.prank(actor);
        lottery.claim();
        assertEq(token.balanceOf(actor), beforeBalance + amount);
        withdrawn += amount;
        assertEq(lottery.claimable(actor), 0);
        vm.prank(actor);
        vm.expectRevert(BlockhashLottery.NothingToClaim.selector);
        lottery.claim();
    }

    function roundDigest(uint256 r) public view returns (bytes32) {
        (uint256 tickets, uint256 carry, BlockhashLottery.State state, address winner, uint256 prize) =
            lottery.roundInfo(r);
        return keccak256(abi.encode(tickets, carry, state, winner, prize));
    }
}

contract LotteryInvariantTest is LotteryTestBase {
    LotteryHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LotteryHandler(token, lottery);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.refund.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.invalidBuy.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantBalanceEqualsCreditsAndUnsettledObligations() public view {
        _assertConserved();
        assertEq(token.balanceOf(address(lottery)), handler.deposited() - handler.withdrawn());
        uint256 allBalances = token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB)
            + token.balanceOf(CAROL) + token.balanceOf(address(lottery));
        assertEq(allBalances, 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function invariantEachRoundFinalizesOnceAndRefundsFullTicketPayments() public view {
        address[3] memory actors = [ALICE, BOB, CAROL];
        uint256 refunds;
        uint256 purchases;
        for (uint256 r; r <= lottery.currentRound(); ++r) {
            (uint256 tickets,, BlockhashLottery.State state,,) = lottery.roundInfo(r);
            assertEq(tickets, handler.bought(r), "ticket total must match successful buys");
            purchases += tickets * PRICE;
            uint256 count = handler.settlements(r);
            assertLe(count, 1, "a round may finalize only once");
            if (count == 0) {
                assertEq(uint256(state), uint256(BlockhashLottery.State.Unsettled));
            } else {
                BlockhashLottery.State expected =
                    handler.expired(r) ? BlockhashLottery.State.Expired : BlockhashLottery.State.Settled;
                assertEq(uint256(state), uint256(expected));
                assertEq(handler.roundDigest(r), handler.finalizedInfo(r), "finalized round changed");
            }
            for (uint256 i; i < actors.length; ++i) {
                address actor = actors[i];
                uint256 purchased = handler.boughtBy(r, actor);
                assertEq(lottery.ticketsOf(r, actor), purchased);
                uint256 credited = handler.refundCredits(r, actor);
                assertEq(lottery.refunded(r, actor), credited != 0);
                if (credited != 0) {
                    assertEq(uint256(state), uint256(BlockhashLottery.State.Expired));
                    assertEq(credited, purchased * PRICE, "refund must equal tickets bought times 1,000 DRAW");
                }
                refunds += credited;
            }
        }
        assertEq(purchases, handler.deposited());
        assertEq(refunds, handler.totalRefunded());
    }

    /// @dev Every generated sequence can still finish: settle outstanding rounds, refund, and claim.
    function afterInvariant() public {
        uint256 lastRound = lottery.currentRound();
        vm.roll(lottery.drawBlock(lastRound) + 257);
        address[3] memory actors = [ALICE, BOB, CAROL];
        for (uint256 r; r <= lastRound; ++r) {
            (,, BlockhashLottery.State state,,) = lottery.roundInfo(r);
            if (state == BlockhashLottery.State.Unsettled) handler.settle(r, bytes32(0), false);
            (,, state,,) = lottery.roundInfo(r);
            for (uint256 i; i < actors.length; ++i) {
                if (
                    state == BlockhashLottery.State.Expired && lottery.ticketsOf(r, actors[i]) != 0
                        && !lottery.refunded(r, actors[i])
                ) {
                    handler.refund(r, i);
                }
            }
        }
        for (uint256 i; i < actors.length; ++i) {
            if (lottery.claimable(actors[i]) != 0) handler.claim(i);
        }
        _assertConserved();
        invariantEachRoundFinalizesOnceAndRefundsFullTicketPayments();
        (, uint256 carry,,,) = lottery.roundInfo(lottery.currentRound());
        assertEq(lottery.totalClaimable(), 0);
        assertEq(token.balanceOf(address(lottery)), carry);
    }
}
