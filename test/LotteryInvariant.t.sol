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
    }

    function advance(uint256 delta) external {
        vm.roll(block.number + bound(delta, 1, 600));
    }

    function settle(uint256 roundSeed, bytes32 hash, bool zeroHash) external {
        uint256 r = roundSeed % (lottery.currentRound() + 1);
        (uint256 tickets,, BlockhashLottery.State state,,) = lottery.roundInfo(r);
        uint256 draw = lottery.drawBlock(r);
        if (state != BlockhashLottery.State.Unsettled || block.number <= draw) return;
        if (tickets != 0 && block.number <= draw + 256) {
            if (zeroHash) {
                vm.setBlockhash(draw, bytes32(0));
                vm.expectRevert(BlockhashLottery.HashUnavailable.selector);
                lottery.settle(r);
                return;
            }
            vm.setBlockhash(draw, hash == bytes32(0) ? bytes32(uint256(1)) : hash);
        }
        lottery.settle(r);
    }

    function refund(uint256 roundSeed, uint256 actorSeed) external {
        uint256 r = roundSeed % (lottery.currentRound() + 1);
        address actor = actors[actorSeed % 3];
        (,, BlockhashLottery.State state,,) = lottery.roundInfo(r);
        if (state != BlockhashLottery.State.Expired || lottery.refunded(r, actor) || lottery.ticketsOf(r, actor) == 0) {
            return;
        }
        vm.prank(actor);
        lottery.refund(r);
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = lottery.claimable(actor);
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(actor);
        vm.prank(actor);
        lottery.claim();
        assertEq(token.balanceOf(actor), beforeBalance + amount);
        withdrawn += amount;
    }
}

contract LotteryInvariantTest is LotteryTestBase {
    LotteryHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LotteryHandler(token, lottery);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.refund.selector;
        selectors[4] = handler.claim.selector;
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

    /// @dev Every generated sequence can still finish: settle outstanding rounds, refund, and claim.
    function afterInvariant() public {
        uint256 lastRound = lottery.currentRound();
        vm.roll(lottery.drawBlock(lastRound) + 257);
        address[3] memory actors = [ALICE, BOB, CAROL];
        for (uint256 r; r <= lastRound; ++r) {
            (,, BlockhashLottery.State state,,) = lottery.roundInfo(r);
            if (state == BlockhashLottery.State.Unsettled) lottery.settle(r);
            (,, state,,) = lottery.roundInfo(r);
            for (uint256 i; i < actors.length; ++i) {
                if (
                    state == BlockhashLottery.State.Expired && lottery.ticketsOf(r, actors[i]) != 0
                        && !lottery.refunded(r, actors[i])
                ) {
                    _refund(r, actors[i]);
                }
            }
        }
        for (uint256 i; i < actors.length; ++i) {
            if (lottery.claimable(actors[i]) != 0) _claim(actors[i]);
        }
        _assertConserved();
        (, uint256 carry,,,) = lottery.roundInfo(lottery.currentRound());
        assertEq(lottery.totalClaimable(), 0);
        assertEq(token.balanceOf(address(lottery)), carry);
    }
}
