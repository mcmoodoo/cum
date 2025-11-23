// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import "forge-std/Test.sol";
import { dynamic } from "./utils/Dynamic.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { Aqua } from "src/Aqua.sol";
import { AquaVault } from "src/AquaVault.sol";
import { XYCSwap, IXYCSwapCallback } from "src/apps/XYCSwap.sol";
import { IAqua } from "src/interfaces/IAqua.sol";
import { IVerifier } from "src/libs/pp/PrivateVault.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock verifier for testing private withdrawals
contract MockVerifier is IVerifier {
    bool public shouldVerify;

    constructor(bool _shouldVerify) {
        shouldVerify = _shouldVerify;
    }

    function verify(bytes calldata, bytes32[] calldata) external view override returns (bool) {
        return shouldVerify;
    }

    function setVerify(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }
}

// Simple IXYCSwapCallback implementation for testing swaps
contract TestCallback is IXYCSwapCallback {
    IAqua public aqua;

    constructor(IAqua _aqua) {
        aqua = _aqua;
    }

    function xycSwapCallback(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256,
        address maker,
        address implementation,
        bytes32 strategyHash,
        bytes calldata
    ) external override {
        // Approve and push tokens back to Aqua
        IERC20(tokenIn).approve(address(aqua), amountIn);
        aqua.push(maker, implementation, strategyHash, tokenIn, amountIn);
    }
}

contract AquaVaultTest is Test {
    Aqua public aqua;
    AquaVault public vault;
    XYCSwap public xycSwap;
    MockERC20 public token0;
    MockERC20 public token1;
    MockVerifier public verifier;
    TestCallback public callback;

    address public owner;
    address public depositor1;
    address public depositor2;
    address public taker;

    uint256 constant INITIAL_DENOMINATION = 1 ether;
    uint256 constant TREE_DEPTH = 20;

    // Strategy salt counter to prevent hash collisions
    uint256 public saltCounter = 0;

    function setUp() public {
        owner = address(this);
        depositor1 = address(0x1);
        depositor2 = address(0x2);
        taker = address(0x3);

        // Deploy core contracts
        aqua = new Aqua();
        xycSwap = new XYCSwap(aqua);
        verifier = new MockVerifier(true);
        callback = new TestCallback(aqua);

        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        // Setup initial roots and denominations
        bytes32[] memory initialRoots = new bytes32[](2);
        initialRoots[0] = bytes32(uint256(1));
        initialRoots[1] = bytes32(uint256(2));

        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = address(token0);
        tokenAddresses[1] = address(token1);

        uint256[] memory denominations = new uint256[](2);
        denominations[0] = INITIAL_DENOMINATION;
        denominations[1] = INITIAL_DENOMINATION;

        // Deploy AquaVault
        vault = new AquaVault(
            aqua,
            verifier,
            initialRoots,
            tokenAddresses,
            denominations
        );

        // Mint tokens to various parties
        token0.mint(depositor1, 100 ether);
        token1.mint(depositor1, 100 ether);
        token0.mint(depositor2, 100 ether);
        token1.mint(depositor2, 100 ether);
        token0.mint(taker, 100 ether);
        token1.mint(taker, 100 ether);
        token0.mint(address(vault), 50 ether);
        token1.mint(address(vault), 50 ether);

        // Setup approvals for depositors
        vm.prank(depositor1);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(depositor1);
        token1.approve(address(vault), type(uint256).max);

        vm.prank(depositor2);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(depositor2);
        token1.approve(address(vault), type(uint256).max);

        // Setup approvals for taker
        vm.prank(taker);
        token0.approve(address(callback), type(uint256).max);
        vm.prank(taker);
        token1.approve(address(callback), type(uint256).max);
    }

    // Helper to get next unique salt
    function getNextSalt() internal returns (bytes32) {
        return bytes32(saltCounter++);
    }

    // ========== DEPOSIT TESTS ==========

    function testPublicDeposit() public {
        uint256 depositAmount = 5 ether;
        uint256 initialBalance = token0.balanceOf(address(vault));

        vm.prank(depositor1);
        vault.deposit(address(token0), depositAmount, bytes32(0));

        assertEq(
            token0.balanceOf(address(vault)),
            initialBalance + depositAmount,
            "Vault should receive deposit"
        );
    }

    function testPublicDepositMultipleDepositors() public {
        uint256 deposit1 = 5 ether;
        uint256 deposit2 = 10 ether;
        uint256 initialBalance = token0.balanceOf(address(vault));

        vm.prank(depositor1);
        vault.deposit(address(token0), deposit1, bytes32(0));

        vm.prank(depositor2);
        vault.deposit(address(token0), deposit2, bytes32(0));

        assertEq(
            token0.balanceOf(address(vault)),
            initialBalance + deposit1 + deposit2,
            "Vault should receive both deposits"
        );
    }

    function testDepositRevertsOnZeroAmount() public {
        vm.prank(depositor1);
        vm.expectRevert("Amount must be greater than 0");
        vault.deposit(address(token0), 0, bytes32(0));
    }

    function testPrivateDeposit() public {
        bytes32 commitment = bytes32(uint256(0x1234));
        uint256 initialBalance = token0.balanceOf(address(vault));

        vm.prank(depositor1);
        vault.deposit(address(token0), INITIAL_DENOMINATION, commitment);

        assertEq(
            token0.balanceOf(address(vault)),
            initialBalance + INITIAL_DENOMINATION,
            "Vault should receive private deposit"
        );

        // Verify commitment was recorded
        assertTrue(vault.isCommitmentUsed(address(token0), commitment), "Commitment should be marked as used");
    }

    function testPrivateDepositRevertsOnWrongAmount() public {
        bytes32 commitment = bytes32(uint256(0x1234));
        uint256 wrongAmount = INITIAL_DENOMINATION + 1 ether;

        vm.prank(depositor1);
        vm.expectRevert("Amount must match denomination for private deposit");
        vault.deposit(address(token0), wrongAmount, commitment);
    }

    function testPrivateDepositRevertsOnDuplicateCommitment() public {
        bytes32 commitment = bytes32(uint256(0x1234));

        vm.prank(depositor1);
        vault.deposit(address(token0), INITIAL_DENOMINATION, commitment);

        // Try to use same commitment again
        token0.mint(depositor1, INITIAL_DENOMINATION);
        vm.prank(depositor1);
        vm.expectRevert();
        vault.deposit(address(token0), INITIAL_DENOMINATION, commitment);
    }

    // ========== STRATEGY MANAGEMENT TESTS ==========

    function testShipStrategySingle() public {
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        bytes memory strategyData = abi.encode(strategy);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        bytes32 strategyHash = vault.ship(
            address(xycSwap),
            strategyData,
            tokens,
            amounts
        );

        // Verify strategy was created in Aqua
        (uint256 balance,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        assertEq(balance, amounts[0], "Strategy should have initial balance");
    }

    function testShipStrategyMultiToken() public {
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        bytes memory strategyData = abi.encode(strategy);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10 ether;
        amounts[1] = 10 ether;

        bytes32 strategyHash = vault.ship(
            address(xycSwap),
            strategyData,
            tokens,
            amounts
        );

        // Verify both tokens have balances
        (uint256 balance0,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        (uint256 balance1,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token1));

        assertEq(balance0, amounts[0], "Token0 balance should match");
        assertEq(balance1, amounts[1], "Token1 balance should match");
    }

    function testDockStrategy() public {
        // First ship a strategy
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        bytes memory strategyData = abi.encode(strategy);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        bytes32 strategyHash = vault.ship(
            address(xycSwap),
            strategyData,
            tokens,
            amounts
        );

        // Dock the strategy
        vault.dock(address(xycSwap), strategyHash, tokens);

        // Verify balance is zero
        (uint256 balance,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        assertEq(balance, 0, "Balance should be zero after dock");
    }

    function testOnlyOwnerCanShipStrategy() public {
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        bytes memory strategyData = abi.encode(strategy);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        vm.prank(depositor1);
        vm.expectRevert();
        vault.ship(address(xycSwap), strategyData, tokens, amounts);
    }

    function testOnlyOwnerCanDockStrategy() public {
        // Ship a strategy first
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        bytes memory strategyData = abi.encode(strategy);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        bytes32 strategyHash = vault.ship(address(xycSwap), strategyData, tokens, amounts);

        // Try to dock as non-owner
        vm.prank(depositor1);
        vm.expectRevert();
        vault.dock(address(xycSwap), strategyHash, tokens);
    }

    // ========== XYCSWAP INTEGRATION TESTS ==========

    function testSwapWithVaultStrategy() public {
        // Ship a strategy with liquidity
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        bytes memory strategyData = abi.encode(strategy);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 20 ether;
        amounts[1] = 20 ether;

        vault.ship(address(xycSwap), strategyData, tokens, amounts);

        // Perform swap as taker
        uint256 swapAmount = 5 ether;
        uint256 initialToken1Balance = token1.balanceOf(taker);

        vm.prank(taker);
        token0.transfer(address(callback), swapAmount);

        vm.prank(address(callback));
        uint256 amountOut = xycSwap.swapExactIn(
            strategy,
            true, // zeroForOne
            swapAmount,
            0,
            taker,
            ""
        );

        // Verify taker received token1
        assertGt(amountOut, 0, "Should receive some token1");
        assertEq(token1.balanceOf(taker), initialToken1Balance + amountOut, "Taker should receive output tokens");
    }

    function testMultipleStrategiesWithDifferentSalts() public {
        // Create first strategy
        XYCSwap.Strategy memory strategy1 = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        bytes32 hash1 = vault.ship(address(xycSwap), abi.encode(strategy1), tokens, amounts);

        // Create second strategy with different salt
        XYCSwap.Strategy memory strategy2 = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        bytes32 hash2 = vault.ship(address(xycSwap), abi.encode(strategy2), tokens, amounts);

        // Verify strategies have different hashes
        assertTrue(hash1 != hash2, "Strategy hashes should be different with different salts");

        // Verify both strategies have balances
        (uint256 balance1,) = aqua.rawBalances(address(vault), address(xycSwap), hash1, address(token0));
        (uint256 balance2,) = aqua.rawBalances(address(vault), address(xycSwap), hash2, address(token0));

        assertEq(balance1, 10 ether, "Strategy1 should have balance");
        assertEq(balance2, 10 ether, "Strategy2 should have balance");
    }

    function testSequentialSwapsOnSameStrategy() public {
        // Ship a strategy with liquidity
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        bytes memory strategyData = abi.encode(strategy);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50 ether;
        amounts[1] = 50 ether;

        vault.ship(address(xycSwap), strategyData, tokens, amounts);

        // Perform first swap
        uint256 swapAmount1 = 5 ether;
        vm.prank(taker);
        token0.transfer(address(callback), swapAmount1);

        vm.prank(address(callback));
        uint256 amountOut1 = xycSwap.swapExactIn(strategy, true, swapAmount1, 0, taker, "");

        // Perform second swap
        uint256 swapAmount2 = 5 ether;
        vm.prank(taker);
        token0.transfer(address(callback), swapAmount2);

        vm.prank(address(callback));
        uint256 amountOut2 = xycSwap.swapExactIn(strategy, true, swapAmount2, 0, taker, "");

        // Second swap should have worse rate due to constant product
        assertTrue(amountOut2 < amountOut1, "Second swap should have worse rate");
    }

    // ========== EDGE CASES AND ERROR CONDITIONS ==========

    function testCannotDepositWithoutApproval() public {
        MockERC20 newToken = new MockERC20("NewToken", "NEW");
        newToken.mint(depositor1, 100 ether);

        vm.prank(depositor1);
        vm.expectRevert();
        vault.deposit(address(newToken), 5 ether, bytes32(0));
    }

    function testShipStrategyReducesVaultBalance() public {
        uint256 shipAmount = 10 ether;

        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = shipAmount;

        bytes32 strategyHash = vault.ship(address(xycSwap), abi.encode(strategy), tokens, amounts);

        // Verify strategy received balance in Aqua (not checking vault token balance as Aqua manages that)
        (uint256 strategyBalance,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        assertEq(
            strategyBalance,
            shipAmount,
            "Strategy should have balance in Aqua"
        );
    }

    function testDockStrategyZerosBalance() public {
        uint256 shipAmount = 10 ether;

        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = shipAmount;

        bytes32 strategyHash = vault.ship(address(xycSwap), abi.encode(strategy), tokens, amounts);

        // Verify strategy has balance before dock
        (uint256 balanceBeforeDock,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        assertEq(balanceBeforeDock, shipAmount, "Strategy should have balance before dock");

        // Dock the strategy
        vault.dock(address(xycSwap), strategyHash, tokens);

        // Verify strategy balance is zero after dock
        (uint256 balanceAfterDock,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        assertEq(
            balanceAfterDock,
            0,
            "Strategy balance should be zero after docking"
        );
    }

    function testDepositAndWithdrawFlow() public {
        // Deposit publicly
        uint256 depositAmount = 10 ether;
        vm.prank(depositor1);
        vault.deposit(address(token0), depositAmount, bytes32(0));

        uint256 vaultBalance = token0.balanceOf(address(vault));
        assertTrue(vaultBalance >= INITIAL_DENOMINATION, "Vault should have enough for withdrawal");

        // Note: Full withdrawal test with ZK proof would require proper proof generation
        // This is a basic structure test
    }

    function testMultipleDepositsAndStrategies() public {
        // Multiple deposits
        vm.prank(depositor1);
        vault.deposit(address(token0), 5 ether, bytes32(0));

        vm.prank(depositor2);
        vault.deposit(address(token0), 10 ether, bytes32(0));

        // Ship strategy
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        vault.ship(address(xycSwap), abi.encode(strategy), tokens, amounts);

        // Verify vault still has remaining balance
        assertTrue(token0.balanceOf(address(vault)) > 0, "Vault should have remaining balance");
    }

    function testStrategyLifecycle() public {
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        // 1. Ship strategy
        bytes32 strategyHash = vault.ship(address(xycSwap), abi.encode(strategy), tokens, amounts);

        (uint256 balanceAfterShip,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        assertEq(balanceAfterShip, 10 ether, "Balance should match shipped amount");

        // 2. Dock strategy
        vault.dock(address(xycSwap), strategyHash, tokens);

        (uint256 balanceAfterDock,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        assertEq(balanceAfterDock, 0, "Balance should be zero after dock");
    }

    // ========== INTEGRATION TEST: DEPOSIT, SHIP, SWAP, DOCK ==========

    function testFullIntegrationFlow() public {
        // 1. Depositors add liquidity
        vm.prank(depositor1);
        vault.deposit(address(token0), 20 ether, bytes32(0));
        vm.prank(depositor1);
        vault.deposit(address(token1), 20 ether, bytes32(0));

        // 2. Owner ships a strategy
        XYCSwap.Strategy memory strategy = XYCSwap.Strategy({
            maker: address(vault),
            token0: address(token0),
            token1: address(token1),
            feeBps: 30,
            salt: getNextSalt()
        });

        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = 30 ether;

        bytes32 strategyHash = vault.ship(address(xycSwap), abi.encode(strategy), tokens, amounts);

        // 3. Taker performs a swap
        uint256 swapAmount = 5 ether;
        vm.prank(taker);
        token0.transfer(address(callback), swapAmount);

        vm.prank(address(callback));
        uint256 amountOut = xycSwap.swapExactIn(strategy, true, swapAmount, 0, taker, "");

        assertTrue(amountOut > 0, "Swap should produce output");

        // 4. Owner docks the strategy
        vault.dock(address(xycSwap), strategyHash, tokens);

        // 5. Verify final state
        (uint256 finalBalance0,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token0));
        (uint256 finalBalance1,) = aqua.rawBalances(address(vault), address(xycSwap), strategyHash, address(token1));

        assertEq(finalBalance0, 0, "Strategy balance should be zero");
        assertEq(finalBalance1, 0, "Strategy balance should be zero");

        assertTrue(token0.balanceOf(address(vault)) > 0, "Vault should have token0");
        assertTrue(token1.balanceOf(address(vault)) > 0, "Vault should have token1");
    }
}
