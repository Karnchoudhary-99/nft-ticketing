// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/NftTicketing.sol";

/// @notice Deploys NftTicketing and prints its address.
///         Usage: forge script script/Deploy.s.sol --broadcast --rpc-url <url>
contract Deploy is Script {
    function run() external returns (NftTicketing ticketing) {
        vm.startBroadcast();
        ticketing = new NftTicketing();
        vm.stopBroadcast();
        console.log("NftTicketing deployed at:", address(ticketing));
    }
}
