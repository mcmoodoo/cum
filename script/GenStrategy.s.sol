// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

// Run as forge script script/GenStrategy.s.sol
contract GenStrategy is Script {
    struct XYCSwapStrategy {
        address maker;
        address token0;
        address token1;
        uint256 feeBps;
        bytes32 salt;
    }

    function run() external view {
        // Example XYCSwap strategy parameters
        // Modify these values as needed
        XYCSwapStrategy memory strategy = XYCSwapStrategy({
            // AquaVault
            maker: address(0x3D4cFe8493c0a08EDA977CCF50A648151228aF69),
            token0: address(0x85024CA2797A551dAD5C1aC131617ffB59873338), // Example: USDC
            token1: address(0xC8751a67B2233fe63b687544B81149E09E183864), // Example: WETH
            feeBps: 30, // 0.3% fee
            salt: bytes32(uint256(1))
        });

        // Generate the encoded strategy bytes and hash
        bytes memory encodedStrategy = abi.encode(strategy);
        bytes32 strategyHash = keccak256(encodedStrategy);

        // Output the results
        console2.log("=== XYCSwap Strategy Hash Generator ===");
        console2.log("");
        console2.log("Strategy Parameters:");
        console2.log("  Maker:   ", strategy.maker);
        console2.log("  Token0:  ", strategy.token0);
        console2.log("  Token1:  ", strategy.token1);
        console2.log("  Fee (BPS):", strategy.feeBps);
        console2.log("  Salt:    ");
        console2.logBytes32(strategy.salt);
        console2.log("");
        console2.log("Encoded Strategy (bytes):");
        console2.logBytes(encodedStrategy);
        console2.log("");
        console2.log("Strategy Hash (bytes32):");
        console2.logBytes32(strategyHash);
    }
}
