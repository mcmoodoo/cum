// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Aqua } from "src/Aqua.sol";
import { AquaVault4626 } from "src/AquaVault4626.sol";

contract MockToken is ERC20 {
    constructor(string memory name_) ERC20(name_, "MOCK") {
        _mint(msg.sender, 1_000_000e18);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AquaVault4626Test is Test {
    Aqua public aqua;
    MockToken public token;
    AquaVault4626 public vault;

    address public owner = address(this);
    address public lp = address(0xBEEF);
    address public app = address(0xAABB);

    function setUp() public {
        aqua = new Aqua();
        token = new MockToken("Underlying");

        vault = new AquaVault4626(IERC20(address(token)), aqua, "Aqua Vault Underlying", "avUNDER");

        // Fund LP and approve vault
        token.mint(lp, 10_000e18);
        vm.prank(lp);
        token.approve(address(vault), type(uint256).max);
    }

    function testDepositShipAndPull() public {
        // LP deposits 1000
        vm.prank(lp);
        vault.deposit(1_000e18, lp);
        assertEq(token.balanceOf(address(vault)), 1_000e18);
        assertEq(vault.totalAssets(), 1_000e18);
        assertEq(vault.balanceOf(lp), 1_000e18);

        // Owner ships 600 capacity to app
        bytes memory strategy = bytes("single-asset-strategy");
        bytes32 strategyHash = vault.shipStrategySingle(app, strategy, 600e18);

        // App pulls 200 to itself
        vm.prank(app);
        aqua.pull(address(vault), strategyHash, address(token), 200e18, app);

        // Vault assets decreased, app received tokens
        assertEq(token.balanceOf(address(vault)), 800e18);
        assertEq(token.balanceOf(app), 200e18);

        // Aqua balance tracking decreased
        (uint256 balanceAfter,) = aqua.rawBalances(address(vault), app, strategyHash, address(token));
        assertEq(balanceAfter, 400e18); // 600 - 200
    }

    function testPushMoreCapacityAndPullAll() public {
        vm.prank(lp);
        vault.deposit(500e18, lp);

        bytes memory strategy = bytes("cap-extend");
        bytes32 strategyHash = vault.shipStrategySingle(app, strategy, 100e18);

        // Add 50 more capacity
        vault.pushCapacitySingle(app, strategyHash, 50e18);
        (uint256 bal,) = aqua.rawBalances(address(vault), app, strategyHash, address(token));
        assertEq(bal, 150e18);

        // Pull full 150
        vm.prank(app);
        aqua.pull(address(vault), strategyHash, address(token), 150e18, app);

        (uint256 balAfter,) = aqua.rawBalances(address(vault), app, strategyHash, address(token));
        assertEq(balAfter, 0);
        assertEq(token.balanceOf(app), 150e18);
        assertEq(token.balanceOf(address(vault)), 350e18);
    }

    function testWithdrawAfterAppPull() public {
        vm.prank(lp);
        vault.deposit(1_000e18, lp);

        bytes32 strategyHash = vault.shipStrategySingle(app, bytes("pull-impact"), 400e18);

        // App pulls 100
        vm.prank(app);
        aqua.pull(address(vault), strategyHash, address(token), 100e18, app);
        assertEq(vault.totalAssets(), 900e18);

        // LP redeems all shares and should get 900 back
        vm.startPrank(lp);
        uint256 shares = vault.balanceOf(lp);
        token.approve(address(vault), type(uint256).max);
        vault.redeem(shares, lp, lp);
        vm.stopPrank();

        assertEq(token.balanceOf(lp), 9_900e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }
}

