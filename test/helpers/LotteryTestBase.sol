// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BlockhashLottery} from "../../src/BlockhashLottery.sol";

abstract contract LotteryTestBase is Test {
    LaunchToken internal token;
    BlockhashLottery internal lottery;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    uint256 internal constant PRICE = 1_000e18;
    uint256 internal genesis;

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.roll(10_000);
        token = new LaunchToken();
        lottery = new BlockhashLottery(address(token));
        genesis = block.number;
        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
    }

    function _fund(address buyer) internal {
        token.transfer(buyer, 1_000_000e18);
        vm.prank(buyer);
        token.approve(address(lottery), type(uint256).max);
    }

    function _buy(address buyer, uint256 count) internal {
        vm.prank(buyer);
        lottery.buy(count);
    }

    function _draw(uint256 r, uint256 offset, bytes32 hash) internal {
        uint256 draw = lottery.drawBlock(r);
        vm.roll(draw + offset);
        vm.setBlockhash(draw, hash);
        lottery.settle(r);
    }

    function _claim(address account) internal {
        vm.prank(account);
        lottery.claim();
    }

    function _refund(uint256 r, address account) internal {
        vm.prank(account);
        lottery.refund(r);
    }

    function _assertRound(uint256 r, uint256 tickets, uint256 carry, BlockhashLottery.State state) internal view {
        (uint256 actualTickets, uint256 actualCarry, BlockhashLottery.State actualState,,) = lottery.roundInfo(r);
        assertEq(actualTickets, tickets);
        assertEq(actualCarry, carry);
        assertEq(uint256(actualState), uint256(state));
    }

    /// @dev Reconstruct liabilities independently of the contract's accounting counters.
    function _assertConserved() internal view {
        address[3] memory buyers = [ALICE, BOB, CAROL];
        uint256 credit;
        uint256 reserved;
        for (uint256 i; i < buyers.length; ++i) {
            credit += lottery.claimable(buyers[i]);
        }
        for (uint256 r; r <= lottery.currentRound(); ++r) {
            (uint256 tickets, uint256 carry, BlockhashLottery.State state,,) = lottery.roundInfo(r);
            if (state == BlockhashLottery.State.Unsettled) {
                reserved += tickets * PRICE + carry;
            } else if (state == BlockhashLottery.State.Expired) {
                for (uint256 i; i < buyers.length; ++i) {
                    if (!lottery.refunded(r, buyers[i])) reserved += lottery.ticketsOf(r, buyers[i]) * PRICE;
                }
            }
        }
        assertEq(lottery.totalClaimable(), credit);
        assertEq(lottery.totalReserved(), reserved);
        assertEq(token.balanceOf(address(lottery)), credit + reserved);
    }

    function _assertRuntime(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
