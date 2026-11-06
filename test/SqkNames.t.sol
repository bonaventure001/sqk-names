// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SqkNames} from "../src/SqkNames.sol";

contract MockSQK is ERC20 {
    constructor() ERC20("SQK", "SQK") {
        _mint(msg.sender, 1_000_000e18);
    }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract SqkNamesTest is Test {
    MockSQK sqk;
    SqkNames names;
    address admin = address(0xA11CE);
    address treasury = address(0x7EA5);
    address bona = address(0xB0A);
    address mallory = address(0xBAD);
    bytes32 secret = keccak256("s3cret");

    function setUp() public {
        sqk = new MockSQK();
        names = new SqkNames(sqk, treasury, admin, [uint256(1000e18), 100e18, 10e18]);
        sqk.mint(bona, 10_000e18);
        sqk.mint(mallory, 10_000e18);
    }

    function _register(address who, string memory label) internal {
        bytes32 c = names.makeCommitment(label, who, secret);
        vm.prank(who);
        names.commit(c);
        vm.warp(block.timestamp + 61);
        vm.startPrank(who);
        sqk.approve(address(names), type(uint256).max);
        names.register(label, who, 365 days, secret);
        vm.stopPrank();
    }

    function test_registerAndResolve() public {
        _register(bona, "bona");
        assertEq(names.ownerOfLabel("bona"), bona);
        assertEq(sqk.balanceOf(treasury), 100e18); // 4-char tier
        vm.prank(bona);
        names.setAddr("bona", bona);
        assertEq(names.resolve("bona"), bona);
    }

    function test_cannotRegisterWithoutCommit() public {
        vm.startPrank(bona);
        sqk.approve(address(names), type(uint256).max);
        vm.expectRevert(SqkNames.CommitmentMissing.selector);
        names.register("bona", bona, 365 days, secret);
        vm.stopPrank();
    }

    function test_cannotRegisterTooSoon() public {
        bytes32 c = names.makeCommitment("bona", bona, secret);
        vm.prank(bona);
        names.commit(c);
        vm.startPrank(bona);
        sqk.approve(address(names), type(uint256).max);
        vm.expectRevert(SqkNames.CommitmentTooNew.selector);
        names.register("bona", bona, 365 days, secret);
        vm.stopPrank();
    }

    function test_frontRunnerCannotReuseCommitment() public {
        bytes32 c = names.makeCommitment("bona", bona, secret);
        vm.prank(bona);
        names.commit(c);
        vm.warp(block.timestamp + 61);
        vm.startPrank(mallory);
        sqk.approve(address(names), type(uint256).max);
        vm.expectRevert(SqkNames.CommitmentMissing.selector); // commitment binds the owner
        names.register("bona", mallory, 365 days, secret);
        vm.stopPrank();
    }

    function test_labelRules() public view {
        assertTrue(names.valid("bona"));
        assertTrue(names.valid("a-b"));
        assertTrue(names.valid("sq2k"));
        assertFalse(names.valid("ab"));          // too short
        assertFalse(names.valid("Bona"));        // uppercase
        assertFalse(names.valid("-bona"));
        assertFalse(names.valid("bona-"));
        assertFalse(names.valid("bo--na"));
        assertFalse(names.valid("bo.na"));       // no dots
        assertFalse(names.valid(unicode"bonа")); // Cyrillic 'а'
    }

    function test_transferResetsRecords() public {
        _register(bona, "bona");
        vm.prank(bona);
        names.setAddr("bona", bona);
        vm.prank(bona);
        names.setText("bona", "url", "https://bona.example");

        vm.prank(bona);
        names.transferFrom(bona, mallory, names.idOf("bona"));

        assertEq(names.resolve("bona"), address(0));
        assertEq(names.text("bona", "url"), "");
        assertEq(names.ownerOfLabel("bona"), mallory);
    }

    function test_reverseIsForwardConfirmed() public {
        _register(bona, "bona");
        vm.startPrank(bona);
        names.setPrimaryName("bona");
        assertEq(names.nameOf(bona), ""); // not pointing back yet
        names.setAddr("bona", bona);
        vm.stopPrank();
        assertEq(names.nameOf(bona), "bona");

        // mallory can't claim bona.sqk as her own primary name
        vm.prank(mallory);
        names.setPrimaryName("bona");
        assertEq(names.nameOf(mallory), "");
    }

    function test_expiryGraceAndReregister() public {
        _register(bona, "bona");
        vm.prank(bona);
        names.setAddr("bona", bona);

        vm.warp(block.timestamp + 365 days + 1);
        assertEq(names.resolve("bona"), address(0)); // expired
        assertFalse(names.available("bona"));        // still in grace

        vm.warp(block.timestamp + 30 days + 1);
        assertTrue(names.available("bona"));
        _register(mallory, "bona");
        assertEq(names.ownerOfLabel("bona"), mallory);
        assertEq(names.resolve("bona"), address(0)); // old records gone
    }

    function test_renewExtendsFromCurrentExpiry() public {
        _register(bona, "bona");
        uint256 before_ = names.expiries(names.idOf("bona"));
        vm.prank(bona);
        names.renew("bona", 365 days);
        assertEq(names.expiries(names.idOf("bona")), before_ + 365 days);
    }

    function test_onlyOwnerCanSetRecords() public {
        _register(bona, "bona");
        vm.prank(mallory);
        vm.expectRevert(SqkNames.NotNameOwner.selector);
        names.setAddr("bona", mallory);
    }

    function test_adminOnly() public {
        vm.prank(mallory);
        vm.expectRevert();
        names.setTreasury(mallory);
        vm.prank(admin);
        names.setTreasury(address(0x1234));
        assertEq(names.treasury(), address(0x1234));
    }
}
