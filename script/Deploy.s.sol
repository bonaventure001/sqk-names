// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SqkNames} from "../src/SqkNames.sol";

/// forge script script/Deploy.s.sol --rpc-url sepolia --broadcast
/// Required env: ADMIN (use the admin Timelock or a Safe), TREASURY
contract Deploy is Script {
    // $SQK on Sepolia, release core-sepolia-20261103
    address constant SQK = 0xd78a3956cF63164d1Fa1C622ad3c66623162Fa1e;

    function run() external {
        address admin = vm.envAddress("ADMIN");
        address treasury = vm.envAddress("TREASURY");
        require(block.chainid == 11155111, "not Sepolia");

        // Placeholder prices (per year, 18 decimals assumed). Check SqueekToken.decimals() and tune.
        uint256[3] memory prices = [uint256(1000e18), 100e18, 10e18];

        vm.startBroadcast();
        SqkNames names = new SqkNames(IERC20(SQK), treasury, admin, prices);
        vm.stopBroadcast();

        console.log("SqkNames:", address(names));
    }
}
