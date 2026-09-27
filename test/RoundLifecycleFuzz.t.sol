// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LotteryTestBase} from "./helpers/LotteryTestBase.sol";
import {BlockhashLottery} from "../src/BlockhashLottery.sol";

contract RoundLifecycleFuzzTest is LotteryTestBase {
    mapping(uint256 => mapping(address => uint256)) internal purchased;
    mapping(uint256 => uint256) internal roundTickets;

    function testFuzzBuysAtOpeningInteriorAndClosingBlocks(uint256 startSeed, uint8[12] memory counts) public {
        uint256 firstRound = bound(startSeed, 0, 8);
        address[3] memory actors = [ALICE, BOB, CAROL];
        uint256[3] memory spent;
        for (uint256 i; i < 4; ++i) {
            uint256 r = firstRound + i;
            uint256 opening = genesis + 300 * r;
            uint256[3] memory offsets = [uint256(0), uint256(counts[3 * i + 1]) + 1, uint256(299)];
            for (uint256 j; j < 3; ++j) {
                vm.roll(opening + offsets[j]);
                assertEq(lottery.currentRound(), r);
                uint256 count = uint256(counts[3 * i + j]) % 100 + 1;
                _recordBuy(r, actors[j], count);
                spent[j] += count * PRICE;
                assertEq(token.balanceOf(actors[j]), 1_000_000e18 - spent[j]);
                _assertRound(r, roundTickets[r], 0, BlockhashLottery.State.Unsettled);
                _assertConserved();
            }
            // The next iteration buys at close + 1; no old round's ticket count may change.
            for (uint256 prior = firstRound; prior <= r; ++prior) {
                _assertRound(prior, roundTickets[prior], 0, BlockhashLottery.State.Unsettled);
                for (uint256 j; j < 3; ++j) {
                    assertEq(lottery.ticketsOf(prior, actors[j]), purchased[prior][actors[j]]);
                }
            }
        }
    }

    function testFuzzSettleTimingAndRepeatedBuyerRefunds(
        uint256 roundSeed,
        uint8[3] memory counts,
        uint256 offsetSeed,
        bytes32 hash
    ) public {
        uint256 r = bound(roundSeed, 0, 12);
        vm.roll(genesis + 300 * r + 299);
        uint256 a = uint256(counts[0]) % 100 + 1;
        uint256 b = uint256(counts[1]) % 100 + 1;
        uint256 c = uint256(counts[2]) % 100 + 1;
        _recordBuy(r, ALICE, a);
        _recordBuy(r, BOB, b);
        _recordBuy(r, ALICE, c);
        uint256 offset = bound(offsetSeed, 0, 600);
        uint256 draw = genesis + 300 * r + 304;
        vm.roll(draw + offset);
        if (offset == 0) {
            vm.expectRevert(BlockhashLottery.TooEarly.selector);
            lottery.settle(r);
            _assertRound(r, a + b + c, 0, BlockhashLottery.State.Unsettled);
            _assertConserved();
            vm.roll(draw + 1);
            offset = 1;
        }

        if (offset <= 256) {
            if (hash == bytes32(0)) hash = bytes32(uint256(1));
            vm.setBlockhash(draw, hash);
            uint256 index = uint256(keccak256(abi.encode(hash, r))) % (a + b + c);
            address expectedWinner = index < a || index >= a + b ? ALICE : BOB;
            uint256 pot = (a + b + c) * PRICE;
            vm.prank(CAROL); // Settlement is permissionless even for a non-buyer.
            lottery.settle(r);
            (,,, address winner, uint256 prize) = lottery.roundInfo(r);
            assertEq(winner, expectedWinner);
            assertEq(prize, pot * 95 / 100);
            assertEq(lottery.claimable(expectedWinner), prize);
            _assertRound(r, a + b + c, 0, BlockhashLottery.State.Settled);
            _assertRound(r + 1, 0, pot - prize, BlockhashLottery.State.Unsettled);
            vm.expectRevert(BlockhashLottery.NotExpired.selector);
            _refund(r, ALICE);
            vm.expectRevert(BlockhashLottery.NotExpired.selector);
            _refund(r, BOB);
            _claim(expectedWinner);
        } else {
            // Refunds need explicit expiry, including well after the hash window.
            vm.expectRevert(BlockhashLottery.NotExpired.selector);
            _refund(r, ALICE);
            vm.prank(CAROL);
            lottery.settle(r);
            _assertRound(r, a + b + c, 0, BlockhashLottery.State.Expired);
            _refundRecorded(r, ALICE);
            _refundRecorded(r, BOB);
            vm.expectRevert(BlockhashLottery.NothingToRefund.selector);
            _refund(r, CAROL);
            _claim(ALICE);
            _claim(BOB);
            assertEq(token.balanceOf(ALICE), 1_000_000e18);
            assertEq(token.balanceOf(BOB), 1_000_000e18);
            assertEq(token.balanceOf(address(lottery)), 0);
        }
        _assertConserved();
        vm.expectRevert(BlockhashLottery.AlreadySettled.selector);
        lottery.settle(r);
        vm.roll(block.number + 1_000);
        vm.expectRevert(BlockhashLottery.AlreadySettled.selector);
        lottery.settle(r);
        _assertConserved();
    }

    function testFuzzZeroHashPreservesCarryAndFullRefunds(uint8 seedCount, uint8 count, uint256 offsetSeed) public {
        uint256 originalTickets = uint256(seedCount) % 100 + 1;
        _recordBuy(0, ALICE, originalTickets);
        _draw(0, 1, bytes32(uint256(17)));
        uint256 carry = originalTickets * PRICE / 20;
        uint256 refundTickets = uint256(count) % 100 + 1;
        _recordBuy(1, BOB, refundTickets);
        vm.roll(genesis + 300 + 304 + bound(offsetSeed, 1, 256));
        vm.setBlockhash(genesis + 300 + 304, bytes32(0));
        vm.expectRevert(BlockhashLottery.HashUnavailable.selector);
        lottery.settle(1);
        _assertRound(1, refundTickets, carry, BlockhashLottery.State.Unsettled);
        assertEq(lottery.claimable(BOB), 0);
        vm.expectRevert(BlockhashLottery.NotExpired.selector);
        _refund(1, BOB);
        _assertConserved();

        vm.roll(genesis + 300 + 304 + 257);
        lottery.settle(1);
        _assertRound(1, refundTickets, 0, BlockhashLottery.State.Expired);
        _assertRound(2, 0, carry, BlockhashLottery.State.Unsettled);
        _refundRecorded(1, BOB);
        _claim(BOB);
        _claim(ALICE);
        assertEq(token.balanceOf(BOB), 1_000_000e18);
        assertEq(token.balanceOf(address(lottery)), carry);
        _assertConserved();
    }

    function testFuzzMixedSettlementsAndRefundsInAnyOrder(
        uint256 orderSeed,
        uint8[8] memory counts,
        uint256 offsetSeed,
        bytes32 hash
    ) public {
        uint256[8] memory n;
        for (uint256 i; i < n.length; ++i) {
            n[i] = uint256(counts[i]) % 100 + 1;
        }
        _recordBuy(0, ALICE, n[0]);
        _draw(0, 1, bytes32(uint256(11)));
        uint256 carry = n[0] * PRICE / 20;
        _recordBuy(1, ALICE, n[1]);
        _recordBuy(1, BOB, n[2]);
        _recordBuy(1, ALICE, n[3]);
        vm.roll(genesis + 600);
        _recordBuy(2, CAROL, n[4]);
        // Round 3 stays empty. Older rounds expire while round 4 can still draw.
        vm.roll(genesis + 1_200);
        _recordBuy(4, ALICE, n[5]);
        _recordBuy(4, BOB, n[6]);
        _recordBuy(4, ALICE, n[7]);
        vm.roll(genesis + 1_200 + 304 + bound(offsetSeed, 1, 256));
        if (hash == bytes32(0)) hash = bytes32(uint256(1));
        vm.setBlockhash(genesis + 1_200 + 304, hash);

        uint256[4] memory order = _permutation(orderSeed);
        for (uint256 i; i < order.length; ++i) {
            uint256 r = order[i];
            vm.prank(CAROL);
            lottery.settle(r);
            BlockhashLottery.State expected = r <= 2 ? BlockhashLottery.State.Expired : BlockhashLottery.State.Settled;
            _assertRound(r, roundTickets[r], 0, expected);
            vm.expectRevert(BlockhashLottery.AlreadySettled.selector);
            lottery.settle(r);
            _assertConserved();
        }
        uint256 index = uint256(keccak256(abi.encode(hash, uint256(4)))) % roundTickets[4];
        address expectedWinner = index < n[5] || index >= n[5] + n[6] ? ALICE : BOB;
        (,,, address winner, uint256 prize) = lottery.roundInfo(4);
        assertEq(winner, expectedWinner);
        assertEq(prize, roundTickets[4] * PRICE * 95 / 100);
        carry += roundTickets[4] * PRICE - prize;
        _assertRound(5, 0, carry, BlockhashLottery.State.Unsettled);

        // Reverse the settlement order and interleave refunds with withdrawals.
        for (uint256 i = order.length; i != 0; --i) {
            uint256 r = order[i - 1];
            if (r == 1) {
                _refundRecorded(r, ALICE);
                _claim(ALICE); // May aggregate the round 0 and round 4 prizes with this refund.
                _refundRecorded(r, BOB);
            } else if (r == 2) {
                _refundRecorded(r, CAROL);
                _claim(CAROL);
            }
            _assertConserved();
        }
        address[3] memory actors = [ALICE, BOB, CAROL];
        for (uint256 i; i < actors.length; ++i) {
            if (lottery.claimable(actors[i]) != 0) _claim(actors[i]);
            vm.expectRevert(BlockhashLottery.NothingToClaim.selector);
            _claim(actors[i]);
        }
        // A carry-only round forwards its entire balance after an arbitrary skipped window.
        uint256 destination = 7 + orderSeed % 8;
        vm.roll(genesis + 300 * destination);
        lottery.settle(5);
        _assertRound(5, 0, 0, BlockhashLottery.State.Settled);
        _assertRound(destination, 0, carry, BlockhashLottery.State.Unsettled);
        assertEq(token.balanceOf(address(lottery)), carry);
        assertEq(lottery.totalClaimable(), 0);
        _assertConserved();
    }

    function _recordBuy(uint256 r, address actor, uint256 count) internal {
        assertEq(lottery.currentRound(), r);
        _buy(actor, count);
        purchased[r][actor] += count;
        roundTickets[r] += count;
        assertEq(lottery.ticketsOf(r, actor), purchased[r][actor]);
    }

    function _refundRecorded(uint256 r, address actor) internal {
        uint256 creditBefore = lottery.claimable(actor);
        uint256 balanceBefore = token.balanceOf(actor);
        _refund(r, actor);
        assertEq(lottery.claimable(actor), creditBefore + purchased[r][actor] * PRICE);
        assertEq(token.balanceOf(actor), balanceBefore);
        assertTrue(lottery.refunded(r, actor));
        vm.expectRevert(BlockhashLottery.AlreadyRefunded.selector);
        _refund(r, actor);
        _assertConserved();
    }

    function _permutation(uint256 seed) internal pure returns (uint256[4] memory order) {
        order = [uint256(1), uint256(2), uint256(3), uint256(4)];
        for (uint256 remaining = 4; remaining > 1; --remaining) {
            uint256 selected = seed % remaining;
            seed /= remaining;
            (order[remaining - 1], order[selected]) = (order[selected], order[remaining - 1]);
        }
    }
}
