// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { AquaRouter } from "../src/AquaRouter.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

contract DeployAquaRouter is Script {
    function run() external {
        vm.startBroadcast();
        AquaRouter aquaRouter = new AquaRouter();
        vm.stopBroadcast();

        console2.log("AquaRouter deployed at: ", address(aquaRouter));
    }
}
// solhint-enable no-console
