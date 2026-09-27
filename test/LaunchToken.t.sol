// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function testMetadataAndFixedSupply() public view {
        assertEq(token.name(), "Draw");
        assertEq(token.symbol(), "DRAW");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzzTransferHasNoFee(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function testTransferFromAndAllowance() public {
        token.transfer(ALICE, 1_000e18);
        vm.prank(ALICE);
        token.approve(BOB, 700e18);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 600e18));
        assertEq(token.balanceOf(ALICE), 400e18);
        assertEq(token.balanceOf(BOB), 600e18);
        assertEq(token.allowance(ALICE, BOB), 100e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 100e18, 101e18));
        token.transferFrom(ALICE, BOB, 101e18);
    }

    function testInfiniteAllowanceAndSelfTransfer() public {
        token.transfer(ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, ALICE, 100e18);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
        assertEq(token.balanceOf(ALICE), 100e18);
    }

    function testRejectsZeroRecipientAndInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    function testDeadAddressTransferDoesNotChangeSupply() public {
        token.transfer(address(0xdead), 123e18);
        assertEq(token.balanceOf(address(0xdead)), 123e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function testNoAdminMintOrUpgradeSelectors() public {
        string[12] memory calls = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)"
        ];
        for (uint256 i; i < calls.length; ++i) {
            bytes memory data = abi.encodeWithSignature(calls[i], ALICE, uint256(1));
            (bool asDeployer,) = address(token).call(data);
            assertFalse(asDeployer);
            vm.prank(ALICE);
            (bool asAttacker,) = address(token).call(data);
            assertFalse(asAttacker);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
