// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LotteryTestBase} from "./helpers/LotteryTestBase.sol";
import {BlockhashLottery} from "../src/BlockhashLottery.sol";

contract RangeLookupTest is LotteryTestBase {
    function testEveryIndexAcrossRepeatedBuyerRanges() public {
        // [A,A][B][A,A,A][C,C,C,C]: exercise the first and last index of every range.
        address[10] memory owners = [ALICE, ALICE, BOB, ALICE, ALICE, ALICE, CAROL, CAROL, CAROL, CAROL];
        _buy(ALICE, 2);
        _buy(BOB, 1);
        _buy(ALICE, 3);
        _buy(CAROL, 4);
        for (uint256 target; target < owners.length; ++target) {
            uint256 snapshot = vm.snapshotState();
            bytes32 hash;
            for (uint256 candidate = 1;; ++candidate) {
                hash = bytes32(candidate);
                if (uint256(keccak256(abi.encode(hash, uint256(0)))) % 10 == target) break;
            }
            _draw(0, 1, hash);
            (,,, address winner, uint256 prize) = lottery.roundInfo(0);
            assertEq(winner, owners[target]);
            assertEq(prize, 9500e18);
            _assertConserved();
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function testFuzzRangeSelectionAgainstLinearOwnership(uint256 a, uint256 b, uint256 c, bytes32 seed) public {
        a = bound(a, 1, 100);
        b = bound(b, 1, 100);
        c = bound(c, 1, 100);
        bytes32 hash = keccak256(abi.encode(seed));
        vm.assume(hash != bytes32(0));
        // A nonzero round also checks that the round number is part of the draw digest.
        vm.roll(genesis + 7 * 300);
        _buy(ALICE, a);
        _buy(BOB, b);
        _buy(CAROL, c);
        _buy(ALICE, 1);
        uint256 index = uint256(keccak256(abi.encode(hash, uint256(7)))) % (a + b + c + 1);
        address expected = index < a ? ALICE : index < a + b ? BOB : index < a + b + c ? CAROL : ALICE;
        _draw(7, 1, hash);
        (,,, address winner,) = lottery.roundInfo(7);
        assertEq(winner, expected);
        _assertConserved();
    }

    function testRoundingDustAlwaysStaysInCarry() public {
        uint256 carry;
        bool exercisedRounding;
        for (uint256 r; r < 20; ++r) {
            _buy(ALICE, 1);
            uint256 pot = PRICE + carry;
            uint256 prize = pot * 95 / 100;
            if (pot * 95 % 100 != 0) exercisedRounding = true;
            carry = pot - prize;
            _draw(r, 1, keccak256(abi.encode(r)));
            (,,,, uint256 actualPrize) = lottery.roundInfo(r);
            assertEq(actualPrize, prize);
            _assertRound(r + 1, 0, carry, BlockhashLottery.State.Unsettled);
            _assertConserved();
        }
        assertTrue(exercisedRounding);
        _claim(ALICE);
        assertEq(token.balanceOf(address(lottery)), carry);
        _assertConserved();
    }

    function testManyRangesRemainSettleable() public {
        for (uint256 i; i < 257; ++i) {
            _buy(i % 2 == 0 ? ALICE : BOB, 1);
        }
        bytes32 hash = bytes32(uint256(135));
        uint256 index = uint256(keccak256(abi.encode(hash, uint256(0)))) % 257;
        _draw(0, 1, hash);
        (,,, address winner,) = lottery.roundInfo(0);
        assertEq(winner, index % 2 == 0 ? ALICE : BOB);
        _assertConserved();
    }
}
