// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { dynamic } from "./utils/Dynamic.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { Aqua } from "src/Aqua.sol";
import { AquaApp } from "src/AquaApp.sol";
import { ABCWeightedSwap, IAquaTakerCallback } from "src/apps/ABCWeightedSwap.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Simple IAquaTakerCallback implementation for testing
contract TestCallback is IAquaTakerCallback {
    function aquaTakerCallback(
        address,
        address,
        uint256,
        uint256,
        address,
        address,
        bytes32,
        bytes calldata
    )
        external
        virtual
        override
    {
        // Callback now must handle token transfers
        // This base implementation does nothing - derived contracts will override
    }
}

// Malicious aquaTakerCallback that doesn't deposit tokens
contract MaliciousCallback is IAquaTakerCallback {
    function aquaTakerCallback(
        address,
        address,
        uint256,
        uint256,
        address,
        address,
        bytes32,
        bytes calldata
    )
        external
        override
    {
        // Intentionally do nothing - don't deposit tokens
    }
}

contract ABCWeightedSwapTest is Test, TestCallback {
    Aqua public aqua;
    ABCWeightedSwap public abcWeightedSwapImpl;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public token2;

    address public maker = address(0x1);
    address public taker = address(0x2);

    uint256 constant INITIAL_AMOUNT_0 = 5000;
    uint256 constant INITIAL_AMOUNT_1 = 5000;
    uint256 constant INITIAL_AMOUNT_2 = 15_000;
    uint24 constant FEE_BPS = 30; // 0.3% fee

    function setUp() public {
        // Deploy contracts
        aqua = new Aqua();
        abcWeightedSwapImpl = new ABCWeightedSwap(aqua);

        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK_0");
        token1 = new MockERC20("Token1", "TK_1");
        token2 = new MockERC20("Token2", "TK_2");

        // Mint tokens
        token0.mint(maker, INITIAL_AMOUNT_0);
        token1.mint(maker, INITIAL_AMOUNT_1);
        token2.mint(maker, INITIAL_AMOUNT_2);
        token0.mint(taker, 100);
        token1.mint(taker, 100);
        token2.mint(taker, 100);

        // Setup approvals
        vm.prank(maker);
        token0.approve(address(aqua), type(uint256).max);

        vm.prank(maker);
        token1.approve(address(aqua), type(uint256).max);

        vm.prank(maker);
        token2.approve(address(aqua), type(uint256).max);

        vm.prank(taker);
        token0.approve(address(this), type(uint256).max);
        vm.prank(taker);
        token1.approve(address(this), type(uint256).max);
        vm.prank(taker);
        token2.approve(address(this), type(uint256).max);
    }

    function createStrategy() internal returns (address app, ABCWeightedSwap.Strategy memory strategy) {
        strategy = ABCWeightedSwap.Strategy({
            maker: maker,
            tokens: dynamic([address(token0), address(token1), address(token2)]),
            normalizedWeights: dynamic([uint256(1e16 * 20), uint256(1e16 * 20), uint256(1e16 * 60)]),
            feeBps: FEE_BPS,
            salt: bytes32(0)
        });

        vm.prank(maker);
        aqua.ship(
            address(abcWeightedSwapImpl),
            abi.encode(strategy),
            dynamic([address(token0), address(token1), address(token2)]),
            dynamic([INITIAL_AMOUNT_0, INITIAL_AMOUNT_1, INITIAL_AMOUNT_2])
        );
        app = address(abcWeightedSwapImpl);

        return (app, strategy);
    }

    function testSwapExactInCycle() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Initial amount to start with
        uint256 startAmount = 1000;
        token0.mint(address(this), startAmount);
        token0.approve(app, type(uint256).max);

        uint256 currentAmount = startAmount;
        console.log("=== SwapExactIn Cycle Test ===");
        console.log("Starting with %s token0", currentAmount);

        // Swap 1: token0 -> token1
        uint256 expectedOut1 = abcWeightedSwap.quoteExactIn(strategy, currentAmount, 0, 1);
        console.log("Expected token1 output: %s", expectedOut1);

        uint256 actualOut1 = abcWeightedSwap.swapExactIn(
            strategy,
            0,
            1, // token0 -> token1
            currentAmount,
            expectedOut1, // minimum expected
            address(this),
            ""
        );
        console.log("Actual token1 output: %s", actualOut1);
        assertEq(actualOut1, expectedOut1, "SwapExactIn 1: Quoted and actual amounts should match");
        assertTrue(actualOut1 > 0, "Should receive some token1");

        // Verify token1 balance
        assertEq(token1.balanceOf(address(this)), actualOut1, "Should receive token1");
        currentAmount = actualOut1;

        // Swap 2: token1 -> token2
        token1.approve(app, type(uint256).max);
        uint256 expectedOut2 = abcWeightedSwap.quoteExactIn(strategy, currentAmount, 1, 2);
        console.log("Expected token2 output: %s", expectedOut2);

        uint256 actualOut2 = abcWeightedSwap.swapExactIn(
            strategy,
            1,
            2, // token1 -> token2
            currentAmount,
            expectedOut2,
            address(this),
            ""
        );
        console.log("Actual token2 output: %s", actualOut2);
        assertEq(actualOut2, expectedOut2, "SwapExactIn 2: Quoted and actual amounts should match");
        assertTrue(actualOut2 > 0, "Should receive some token2");

        assertEq(token2.balanceOf(address(this)), actualOut2, "Should receive token2");
        currentAmount = actualOut2;

        // Swap 3: token2 -> token0 (completing the cycle)
        token2.approve(app, type(uint256).max);
        uint256 expectedOut3 = abcWeightedSwap.quoteExactIn(strategy, currentAmount, 2, 0);
        console.log("Expected token0 output: %s", expectedOut3);

        uint256 actualOut3 = abcWeightedSwap.swapExactIn(
            strategy,
            2,
            0, // token2 -> token0
            currentAmount,
            expectedOut3,
            address(this),
            ""
        );
        console.log("Actual token0 output: %s", actualOut3);
        assertEq(actualOut3, expectedOut3, "SwapExactIn 3: Quoted and actual amounts should match");
        assertTrue(actualOut3 > 0, "Should receive some token0");

        console.log("Final token0 amount: %s", actualOut3);
        console.log("Loss due to fees/slippage: %s", startAmount - actualOut3);

        // Due to fees and different weights, we should get back less than we started with
        assertTrue(actualOut3 < startAmount, "Should lose some value due to fees and weighted pool mechanics");

        // But we should still get a reasonable amount back (more than 50% of original due to low fees)
        assertTrue(actualOut3 > startAmount / 2, "Should retain significant value after full cycle");
    }

    function testSwapExactOutCycle() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Target amounts we want to receive at each step
        uint256 targetToken1 = 500;
        uint256 targetToken2 = 800;
        uint256 targetToken0 = 400;

        console.log("=== SwapExactOut Cycle Test ===");

        // Swap 1: ? token0 -> 500 token1
        uint256 requiredToken0_1 = abcWeightedSwap.quoteExactOut(strategy, targetToken1, 0, 1);
        console.log("Required token0 for %s token1: %s", targetToken1, requiredToken0_1);

        token0.mint(address(this), requiredToken0_1);
        token0.approve(app, type(uint256).max);

        uint256 actualIn1 = abcWeightedSwap.swapExactOut(
            strategy,
            0,
            1, // token0 -> token1
            targetToken1,
            requiredToken0_1, // maximum input
            address(this),
            ""
        );
        console.log("Actual token0 used: %s", actualIn1);
        assertEq(actualIn1, requiredToken0_1, "SwapExactOut 1: Quoted and actual input should match");
        assertEq(token1.balanceOf(address(this)), targetToken1, "Should receive exactly target token1 amount");

        // Swap 2: ? token1 -> 800 token2
        uint256 requiredToken1_2 = abcWeightedSwap.quoteExactOut(strategy, targetToken2, 1, 2);
        console.log("Required token1 for %s token2: %s", targetToken2, requiredToken1_2);

        // Ensure we have enough token1 (we should have exactly targetToken1 from previous swap)
        // But we might need more for the swap due to fees
        if (requiredToken1_2 > token1.balanceOf(address(this))) {
            uint256 additionalToken1Needed = requiredToken1_2 - token1.balanceOf(address(this));
            token1.mint(address(this), additionalToken1Needed);
        }
        token1.approve(app, type(uint256).max);

        uint256 actualIn2 = abcWeightedSwap.swapExactOut(
            strategy,
            1,
            2, // token1 -> token2
            targetToken2,
            requiredToken1_2,
            address(this),
            ""
        );
        console.log("Actual token1 used: %s", actualIn2);
        assertEq(actualIn2, requiredToken1_2, "SwapExactOut 2: Quoted and actual input should match");
        assertEq(token2.balanceOf(address(this)), targetToken2, "Should receive exactly target token2 amount");

        // Swap 3: ? token2 -> 400 token0
        uint256 requiredToken2_3 = abcWeightedSwap.quoteExactOut(strategy, targetToken0, 2, 0);
        console.log("Required token2 for %s token0: %s", targetToken0, requiredToken2_3);

        // Ensure we have enough token2 (we should have exactly targetToken2 from previous swap)
        // But we might need more for the swap due to fees
        if (requiredToken2_3 > token2.balanceOf(address(this))) {
            uint256 additionalToken2Needed = requiredToken2_3 - token2.balanceOf(address(this));
            token2.mint(address(this), additionalToken2Needed);
        }
        token2.approve(app, type(uint256).max);

        uint256 actualIn3 = abcWeightedSwap.swapExactOut(
            strategy,
            2,
            0, // token2 -> token0
            targetToken0,
            requiredToken2_3,
            address(this),
            ""
        );
        console.log("Actual token2 used: %s", actualIn3);
        assertEq(actualIn3, requiredToken2_3, "SwapExactOut 3: Quoted and actual input should match");
        assertEq(token0.balanceOf(address(this)), targetToken0, "Should receive exactly target token0 amount");

        // Summary
        uint256 totalToken0Used = requiredToken0_1;
        uint256 finalToken0Received = targetToken0;
        console.log("Total token0 invested: %s", totalToken0Used);
        console.log("Final token0 received: %s", finalToken0Received);
        console.log("Net loss: %s", totalToken0Used - finalToken0Received);

        // Verify that we used more than we got back (due to fees and weighted pool mechanics)
        assertTrue(totalToken0Used > finalToken0Received, "Should use more token0 than we get back due to fees");
    }

    function testWeightedPoolAsymmetryDemo() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        uint256 swapAmount = 1000; // Same input amount for all swaps

        console.log("=== WEIGHTED POOL ASYMMETRY DEMONSTRATION ===");
        console.log("Pool configuration:");
        console.log("  token0: 20%% weight, 5,000 balance  (Light weight)");
        console.log("  token1: 20%% weight, 5,000 balance  (Light weight)");
        console.log("  token2: 60%% weight, 15,000 balance (Heavy weight - 3x!)");
        console.log("");

        // KEY INSIGHT: Heavy-weight tokens act like "DEEP LIQUIDITY"
        // - Easier to buy heavy tokens (get more output)
        // - Harder to sell heavy tokens (get less output)
        console.log("--- Swapping %s tokens INTO heavy-weight token2 (60%%) ---", swapAmount);
        console.log("Heavy tokens = Deep liquidity = MORE output when buying");

        uint256 token0_to_token2 = abcWeightedSwap.quoteExactIn(strategy, swapAmount, 0, 2);
        uint256 token1_to_token2 = abcWeightedSwap.quoteExactIn(strategy, swapAmount, 1, 2);

        console.log("  1000 token0 -> token2: %s", token0_to_token2);
        console.log("  1000 token1 -> token2: %s", token1_to_token2);

        // KEY INSIGHT: Selling heavy tokens gives you LESS output
        // This is because heavy tokens resist price changes (stability)
        console.log("");
        console.log("--- Swapping %s token2 OUT OF heavy-weight token2 (60%%) ---", swapAmount);
        console.log("Heavy tokens resist price changes = LESS output when selling");

        uint256 token2_to_token0 = abcWeightedSwap.quoteExactIn(strategy, swapAmount, 2, 0);
        uint256 token2_to_token1 = abcWeightedSwap.quoteExactIn(strategy, swapAmount, 2, 1);

        console.log("  1000 token2 -> token0: %s", token2_to_token0);
        console.log("  1000 token2 -> token1: %s", token2_to_token1);

        // KEY INSIGHT: Equal-weight swaps are nearly symmetric
        // No weight advantage = similar exchange rates both ways
        console.log("");
        console.log("--- Swapping between equal-weight tokens (both 20%%) ---");
        console.log("Equal weights = Nearly symmetric exchange rates");

        uint256 token0_to_token1 = abcWeightedSwap.quoteExactIn(strategy, swapAmount, 0, 1);
        uint256 token1_to_token0 = abcWeightedSwap.quoteExactIn(strategy, swapAmount, 1, 0);

        console.log("  1000 token0 -> token1: %s", token0_to_token1);
        console.log("  1000 token1 -> token0: %s", token1_to_token0);

        console.log("");
        console.log("=== WEIGHTED POOL INSIGHTS ===");
        console.log("1. BUYING heavy tokens is 'cheap' - you get more output");
        console.log("2. SELLING heavy tokens is 'expensive' - you get less output");
        console.log("3. This creates PRICE STABILITY for heavy-weight tokens");
        console.log("4. Equal-weight swaps behave like traditional 50/50 AMM pools");

        // Mathematical verification of weighted pool properties
        assertTrue(token0_to_token2 > token2_to_token0, "Buying heavy token should give more than selling it");
        assertTrue(token1_to_token2 > token2_to_token1, "Buying heavy token should give more than selling it");

        // Equal weight swaps should be more symmetric (smaller difference)
        uint256 equalWeightDiff = token0_to_token1 > token1_to_token0 ?
            token0_to_token1 - token1_to_token0 : token1_to_token0 - token0_to_token1;
        uint256 heavyWeightDiff = token0_to_token2 > token2_to_token0 ?
            token0_to_token2 - token2_to_token0 : token2_to_token0 - token0_to_token2;

        assertTrue(heavyWeightDiff > equalWeightDiff * 2, "Weight asymmetry creates larger differences than equal weights");
    }

    function testWeightedPoolPriceStabilityDemo() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        console.log("=== PRICE STABILITY DEMONSTRATION ===");
        console.log("Testing how different weights affect PRICE IMPACT and SLIPPAGE");
        console.log("Heavy tokens should have LESS slippage (more stability)");
        console.log("");

        // Test progressive swap sizes to demonstrate slippage differences
        // Max safe swap is 30% of balance = 1500 for token0/token1, 4500 for token2
        uint256[] memory swapSizes = new uint256[](4);
        swapSizes[0] = 300;   // Small trade (6% of balance)
        swapSizes[1] = 600;   // Medium trade (12% of balance)
        swapSizes[2] = 900;   // Large trade (18% of balance)
        swapSizes[3] = 1200;  // Very large trade (24% of balance)

        console.log("Trade Size | Light->Heavy | Heavy->Light | Light->Light | Observations");
        console.log("           | (20%->60%)   | (60%->20%)   | (20%->20%)   |");
        console.log("-----------|--------------|--------------|--------------|---------------");

        uint256 prevLightToHeavyRate = 0;
        uint256 prevHeavyToLightRate = 0;
        uint256 prevLightToLightRate = 0;

        for(uint256 i = 0; i < swapSizes.length; i++) {
            uint256 size = swapSizes[i];

            uint256 lightToHeavy = abcWeightedSwap.quoteExactIn(strategy, size, 0, 2);
            uint256 heavyToLight = abcWeightedSwap.quoteExactIn(strategy, size, 2, 0);
            uint256 lightToLight = abcWeightedSwap.quoteExactIn(strategy, size, 0, 1);

            // Calculate rates (output per 1000 input for comparison)
            uint256 lightToHeavyRate = (lightToHeavy * 1000) / size;
            uint256 heavyToLightRate = (heavyToLight * 1000) / size;
            uint256 lightToLightRate = (lightToLight * 1000) / size;

            console.log("Trade size %s:", size);
            console.log("  Light->Heavy: %s (rate: %s)", lightToHeavy, lightToHeavyRate);
            console.log("  Heavy->Light: %s (rate: %s)", heavyToLight, heavyToLightRate);
            console.log("  Light->Light: %s (rate: %s)", lightToLight, lightToLightRate);

            if (i == 0) console.log("  >> Baseline rates established");
            else if (i == 1) console.log("  >> Notice different rates by weight");
            else if (i == 2) console.log("  >> Rate degradation begins");
            else console.log("  >> Heavy token shows most stability");

            // Track rate degradation (slippage) compared to previous trade
            if (i > 0) {
                uint256 lightToHeavySlippage = prevLightToHeavyRate > lightToHeavyRate ?
                    prevLightToHeavyRate - lightToHeavyRate : 0;
                uint256 heavyToLightSlippage = prevHeavyToLightRate > heavyToLightRate ?
                    prevHeavyToLightRate - heavyToLightRate : 0;
                uint256 lightToLightSlippage = prevLightToLightRate > lightToLightRate ?
                    prevLightToLightRate - lightToLightRate : 0;

                console.log("  Slippage - Light->Heavy: %s, Heavy->Light: %s, Light->Light: %s",
                    lightToHeavySlippage, heavyToLightSlippage, lightToLightSlippage);
            }

            prevLightToHeavyRate = lightToHeavyRate;
            prevHeavyToLightRate = heavyToLightRate;
            prevLightToLightRate = lightToLightRate;
        }

        console.log("");
        console.log("=== PRICE STABILITY INSIGHTS ===");
        console.log("1. HEAVY tokens (60%% weight) show LESS rate degradation = MORE STABLE");
        console.log("2. Large trades against heavy tokens have LOWER slippage");
        console.log("3. This is why weighted pools are perfect for STABLECOIN pools");
        console.log("4. Heavy weight = Price stability = Better for large trades");
    }

    function testWeightedPoolInvariantDemo() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);
        bytes32 strategyHash = keccak256(abi.encode(strategy));

        console.log("=== WEIGHTED POOL INVARIANT DEMONSTRATION ===");
        console.log("Mathematical formula: balance0^0.2 * balance1^0.2 * balance2^0.6 = CONSTANT");
        console.log("This shows how weights determine price relationships");
        console.log("");

        // Record initial balances and show the weighted invariant concept
        (uint256 initialBal0,) = aqua.rawBalances(strategy.maker, app, strategyHash, address(token0));
        (uint256 initialBal1,) = aqua.rawBalances(strategy.maker, app, strategyHash, address(token1));
        (uint256 initialBal2,) = aqua.rawBalances(strategy.maker, app, strategyHash, address(token2));

        console.log("INITIAL STATE (pool balances):");
        console.log("  token0: %s (weight: 20%% = 0.2 exponent)", initialBal0);
        console.log("  token1: %s (weight: 20%% = 0.2 exponent)", initialBal1);
        console.log("  token2: %s (weight: 60%% = 0.6 exponent)", initialBal2);
        console.log("  Weighted invariant =~ %s^0.2 * %s^0.2 * %s^0.6", initialBal0, initialBal1, initialBal2);
        console.log("");

        // Perform a substantial swap to show balance changes
        uint256 swapAmount = 1200; // Large but safe swap (24% of token0 balance)
        token0.mint(address(this), swapAmount);
        token0.approve(app, swapAmount);

        uint256 expectedOut = abcWeightedSwap.quoteExactIn(strategy, swapAmount, 0, 2);
        console.log("EXECUTING SWAP: %s token0 -> token2", swapAmount);
        console.log("Expected token2 output: %s", expectedOut);
        console.log("");
        console.log("Key insight: Watch how the HEAVY token (token2) balance");
        console.log("changes LESS proportionally than the light token (token0)!");
        console.log("");

        uint256 actualOut = abcWeightedSwap.swapExactIn(
            strategy, 0, 2, swapAmount, expectedOut, address(this), ""
        );

        // Show the new balances and explain the weighted invariant preservation
        (uint256 newBal0,) = aqua.rawBalances(strategy.maker, app, strategyHash, address(token0));
        (uint256 newBal1,) = aqua.rawBalances(strategy.maker, app, strategyHash, address(token1));
        (uint256 newBal2,) = aqua.rawBalances(strategy.maker, app, strategyHash, address(token2));

        console.log("AFTER SWAP (new pool balances):");
        console.log("  token0: %s (was %s, changed by +%s)", newBal0, initialBal0, newBal0 - initialBal0);
        console.log("  token1: %s (unchanged - not involved in swap)", newBal1);
        console.log("  token2: %s (was %s, changed by -%s)", newBal2, initialBal2, initialBal2 - newBal2);
        console.log("  Weighted invariant =~ %s^0.2 * %s^0.2 * %s^0.6", newBal0, newBal1, newBal2);
        console.log("");

        // Calculate percentage changes to show the weighted effect
        uint256 token0PercentChange = ((newBal0 - initialBal0) * 100) / initialBal0;
        uint256 token2PercentChange = ((initialBal2 - newBal2) * 100) / initialBal2;

        console.log("PERCENTAGE CHANGES:");
        console.log("  token0 balance: +%s%% (light weight = larger % change)", token0PercentChange);
        console.log("  token2 balance: -%s%% (heavy weight = smaller % change)", token2PercentChange);
        console.log("");

        console.log("=== WEIGHTED INVARIANT INSIGHTS ===");
        console.log("1. Heavy tokens (60%% weight) resist large balance changes");
        console.log("2. Light tokens (20%% weight) absorb more of the balance change");
        console.log("3. This creates PRICE STABILITY for the heavy token");
        console.log("4. The mathematical invariant is preserved despite unequal changes!");
        console.log("5. This is why 80/20 pools work better than 50/50 for some assets");

        // Verify the swap worked as expected
        assertEq(actualOut, expectedOut, "Actual output should match quoted output");
        assertTrue(newBal0 > initialBal0, "token0 balance should increase (we added token0)");
        assertTrue(newBal2 < initialBal2, "token2 balance should decrease (we removed token2)");
        assertEq(newBal1, initialBal1, "token1 balance should be unchanged (not part of swap)");

        // Verify weighted pool behavior - heavy token changes less proportionally
        assertTrue(token2PercentChange < token0PercentChange, "Heavy token should have smaller percentage change");
    }

    function testAllDirectionalSwapsDemo() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        console.log("=== ALL-DIRECTIONAL SWAPS DEMONSTRATION ===");
        console.log("Testing ALL 6 possible swap directions to show weight effects");
        console.log("Weights: token0=20%%, token1=20%%, token2=60%%");
        console.log("");

        uint256 testAmount = 1000;

        // Test all 6 possible swap directions
        console.log("From/To    | Amount Out | Rate      | Weight Effect");
        console.log("-----------|------------|-----------|------------------");

        // Light -> Light swaps (20% -> 20%)
        uint256 out_0_to_1 = abcWeightedSwap.quoteExactIn(strategy, testAmount, 0, 1);
        uint256 out_1_to_0 = abcWeightedSwap.quoteExactIn(strategy, testAmount, 1, 0);
        console.log("token0->1  | %s      | %s%%    | Light->Light (symmetric)", out_0_to_1, (out_0_to_1 * 100) / testAmount);
        console.log("token1->0  | %s      | %s%%    | Light->Light (symmetric)", out_1_to_0, (out_1_to_0 * 100) / testAmount);

        // Light -> Heavy swaps (20% -> 60%)
        uint256 out_0_to_2 = abcWeightedSwap.quoteExactIn(strategy, testAmount, 0, 2);
        uint256 out_1_to_2 = abcWeightedSwap.quoteExactIn(strategy, testAmount, 1, 2);
        console.log("token0->2  | %s      | %s%%   | Light->HEAVY (favorable)", out_0_to_2, (out_0_to_2 * 100) / testAmount);
        console.log("token1->2  | %s      | %s%%   | Light->HEAVY (favorable)", out_1_to_2, (out_1_to_2 * 100) / testAmount);

        // Heavy -> Light swaps (60% -> 20%)
        uint256 out_2_to_0 = abcWeightedSwap.quoteExactIn(strategy, testAmount, 2, 0);
        uint256 out_2_to_1 = abcWeightedSwap.quoteExactIn(strategy, testAmount, 2, 1);
        console.log("token2->0  | %s       | %s%%     | HEAVY->Light (unfavorable)", out_2_to_0, (out_2_to_0 * 100) / testAmount);
        console.log("token2->1  | %s       | %s%%     | HEAVY->Light (unfavorable)", out_2_to_1, (out_2_to_1 * 100) / testAmount);

        console.log("");
        console.log("=== DIRECTIONAL SWAP INSIGHTS ===");
        console.log("1. Light->Light: ~100%% rate (similar to 50/50 AMM)");
        console.log("2. Light->HEAVY: >100%% rate (FAVORABLE - get bonus output)");
        console.log("3. HEAVY->Light: <100%% rate (UNFAVORABLE - get penalty)");
        console.log("4. This creates natural REBALANCING pressure toward target weights");

        // Mathematical verification of weight effects
        uint256 avgLightToLight = (out_0_to_1 + out_1_to_0) / 2;
        uint256 avgLightToHeavy = (out_0_to_2 + out_1_to_2) / 2;
        uint256 avgHeavyToLight = (out_2_to_0 + out_2_to_1) / 2;

        // Light->Heavy should give more output than Light->Light
        assertTrue(avgLightToHeavy > avgLightToLight, "Swapping to heavy token should be more favorable");

        // Heavy->Light should be less favorable than Light->Heavy (key asymmetry)
        assertTrue(avgLightToHeavy >= avgHeavyToLight, "Light->Heavy should be at least as favorable as Heavy->Light");

        // The key insight is that Light->Heavy is more favorable than Light->Light
        // This demonstrates the weighted pool's rebalancing incentive
        assertTrue(avgLightToHeavy > avgLightToLight * 105 / 100, "Light->Heavy should be at least 5% more favorable");

        console.log("");
        console.log("SUMMARY RATES:");
        console.log("  Average Light->Light rate: %s%% (baseline)", (avgLightToLight * 100) / testAmount);
        console.log("  Average Light->Heavy rate: %s%% (favorable)", (avgLightToHeavy * 100) / testAmount);
        console.log("  Average Heavy->Light rate: %s%% (unfavorable)", (avgHeavyToLight * 100) / testAmount);
        console.log("");
        console.log("This demonstrates how weighted pools maintain target allocations!");
        console.log("High-weight tokens naturally accumulate, low-weight tokens get sold off.");
    }

    // Override aquaTakerCallback function from TestCallback
    function aquaTakerCallback(
        address tokenIn,
        address, /* tokenOut */
        uint256 amountIn,
        uint256, /* amountOut */
        address maker_,
        address implementation,
        bytes32 strategyHash,
        bytes calldata /* takerData */
    )
        external
        override
    {
        IERC20(tokenIn).approve(address(aqua), amountIn);
        aqua.push(maker_, implementation, strategyHash, tokenIn, amountIn);
    }

    /*

    // Helper to reduce repetitive token transfers and approvals
    function swap(
        address app,
        ABCWeightedSwap.Strategy memory strategy,
        bool zeroForOne,
        uint256 amountIn
    )
        internal
        returns (uint256)
    {
        address tokenIn = zeroForOne ? strategy.token0 : strategy.token1;
        vm.prank(taker);
        MockERC20(tokenIn).transfer(address(this), amountIn);
        MockERC20(tokenIn).approve(app, amountIn);

        // Pass the swap direction in takerData
        bytes memory takerData = abi.encode(zeroForOne);
        return ABCWeightedSwap(app).swapExactIn(strategy, zeroForOne, amountIn, 0, address(this), takerData);
    }

    function testSwapToken0ForToken1() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Swap: we want to give 10 token0 and receive token1
        uint256 amountIn = 10;
        uint256 expectedAmountOut = calculateAmountOut(amountIn, INITIAL_AMOUNT0, INITIAL_AMOUNT1, FEE_BPS);

        // Transfer token0 from taker to test contract
        vm.prank(taker);
        token0.transfer(address(this), amountIn);

        // Approve the ABCWeightedSwap app to spend token0
        token0.approve(app, type(uint256).max);

        uint256 initialBalance1 = token1.balanceOf(address(this));

        // Call with zeroForOne = true to swap token0 for token1
        bytes memory takerData = abi.encode(true); // Pass swap direction
        uint256 amountOut = abcWeightedSwap.swapExactIn(
            strategy,
            true, // zeroForOne
            amountIn,
            expectedAmountOut - 1,
            address(this),
            takerData
        );

        // Verify output amount
        assertEq(amountOut, expectedAmountOut, "Output amount should match calculation");
        assertEq(token1.balanceOf(address(this)), initialBalance1 + amountOut, "Should receive token1");

        // Verify pool balances
        uint256 newBalance0 = aqua.balances(maker, app, address(token0));
        uint256 newBalance1 = aqua.balances(maker, app, address(token1));

        // Pool should have more token0, less token1
        assertEq(newBalance0, INITIAL_AMOUNT0 + amountIn, "Pool should have more token0");
        assertEq(newBalance1, INITIAL_AMOUNT1 - amountOut, "Pool should have less token1");
    }

    function testSwapToken1ForToken0() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Swap: we want to give 10 token1 and receive token0
        uint256 amountIn = 10;
        uint256 expectedAmountOut = calculateAmountOut(amountIn, INITIAL_AMOUNT1, INITIAL_AMOUNT0, FEE_BPS);

        // Transfer token1 from taker to test contract
        vm.prank(taker);
        token1.transfer(address(this), amountIn);

        // Approve the ABCWeightedSwap app to spend token1
        token1.approve(app, type(uint256).max);

        uint256 initialBalance0 = token0.balanceOf(address(this));

        // Call with zeroForOne = false to swap token1 for token0
        bytes memory takerData = abi.encode(false); // Pass swap direction
        uint256 amountOut = abcWeightedSwap.swapExactIn(
            strategy,
            false, // zeroForOne
            amountIn,
            expectedAmountOut - 1,
            address(this),
            takerData
        );

        // Verify output amount
        assertEq(amountOut, expectedAmountOut, "Output amount should match calculation");
        assertEq(token0.balanceOf(address(this)), initialBalance0 + amountOut, "Should receive token0");
    }

    function testPriceImpact() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Transfer tokens from taker to test contract
        vm.prank(taker);
        token0.transfer(address(this), 25); // Enough for both swaps
        token0.approve(app, type(uint256).max);

        // Small swap: 5 token0 for token1
        uint256 smallAmountIn = 5;
        bytes memory takerData = abi.encode(true);
        uint256 smallAmountOut = abcWeightedSwap.swapExactIn(strategy, true, smallAmountIn, 0, address(this), takerData);

        // Reset for large swap
        setUp();
        (app, strategy) = createStrategy();
        abcWeightedSwap = ABCWeightedSwap(app);

        vm.prank(taker);
        token0.transfer(address(this), 20);
        token0.approve(app, type(uint256).max);

        // Large swap: 20 token0 for token1
        uint256 largeAmountIn = 20;
        bytes memory takerData2 = abi.encode(true);
        uint256 largeAmountOut = abcWeightedSwap.swapExactIn(strategy, true, largeAmountIn, 0, address(this), takerData2);

        // Calculate average price per token (scaled by 1000 to avoid rounding issues)
        uint256 smallPricePerToken = (smallAmountOut * 1000) / smallAmountIn;
        uint256 largePricePerToken = (largeAmountOut * 1000) / largeAmountIn;

        // Verify specific values
        assertEq(smallAmountOut, 3, "Small swap should output 3 tokens");
        assertEq(largeAmountOut, 13, "Large swap should output 13 tokens");

        // Larger swap should have worse price (less output per input)
        // Small: 3 * 1000 / 5 = 600
        // Large: 13 * 1000 / 20 = 650
        // Actually with these values, the large swap has a slightly better price per token
        // This is because the fee impact is proportionally less significant on larger amounts
        // Let's verify the actual price impact
        assertTrue(
            largePricePerToken < smallPricePerToken * 110 / 100, "Large swap price should not be more than 10% better"
        );
    }

    function testABCWeightedSwapInvariant() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Initial k value
        uint256 initialK = INITIAL_AMOUNT0 * INITIAL_AMOUNT1;

        // Perform swap: token0 for token1
        uint256 amountIn = 10;
        vm.prank(taker);
        token0.transfer(address(this), amountIn);
        token0.approve(app, type(uint256).max);

        bytes memory takerData = abi.encode(true);
        uint256 amountOut = abcWeightedSwap.swapExactIn(strategy, true, amountIn, 0, address(this), takerData);

        // Get new balances
        uint256 newBalance0 = aqua.balances(maker, app, address(token0));
        uint256 newBalance1 = aqua.balances(maker, app, address(token1));

        // Calculate new k (should be slightly higher due to fees)
        uint256 newK = newBalance0 * newBalance1;

        // New k should be greater than or equal to initial k (fees increase k)
        assertTrue(newK >= initialK, "Constant product should not decrease");

        // Verify the exact k value increase matches fee collection
        uint256 expectedNewBalance0 = INITIAL_AMOUNT0 + amountIn;
        uint256 expectedNewBalance1 = INITIAL_AMOUNT1 - amountOut;
        assertEq(newBalance0, expectedNewBalance0, "Balance0 should match expected");
        assertEq(newBalance1, expectedNewBalance1, "Balance1 should match expected");
    }

    function testSequentialSwaps() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();

        uint256 amountOut1 = swap(app, strategy, true, 10);
        uint256 balance0After1 = aqua.balances(maker, app, address(token0));
        uint256 balance1After1 = aqua.balances(maker, app, address(token1));

        uint256 expectedAmountOut2 = calculateAmountOut(10, balance0After1, balance1After1, FEE_BPS);
        uint256 amountOut2 = swap(app, strategy, true, 10);

        assertTrue(amountOut2 < amountOut1, "Second swap should have worse rate");
        assertEq(amountOut1, 7, "First swap should output 7 tokens");
        assertEq(amountOut2, 5, "Second swap should output 5 tokens");
        assertEq(amountOut2, expectedAmountOut2, "Second swap output should match calculation");
    }

    function testConsecutiveSwapsMatchCombined() public {
        // Test that swap(x) + swap(y) ≈ swap(x+y) (within rounding)

        // Path 1: Two consecutive swaps
        (address app1, ABCWeightedSwap.Strategy memory strategy1) = createStrategy();
        uint256 out1 = swap(app1, strategy1, true, 10);
        uint256 out2 = swap(app1, strategy1, true, 10);
        uint256 totalOut = out1 + out2;

        // Path 2: Single combined swap - need new setup for fresh state
        setUp();
        (address app2, ABCWeightedSwap.Strategy memory strategy2) = createStrategy();
        uint256 outCombined = swap(app2, strategy2, true, 20);

        // Allow for small rounding difference (up to 1 token)
        uint256 diff = totalOut > outCombined ? totalOut - outCombined : outCombined - totalOut;
        assertTrue(diff <= 1, "Consecutive swaps should approximately equal combined swap");
    }

    function testGasProfile() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();

        // Prepare tokens
        vm.prank(taker);
        token0.transfer(address(this), 30);
        token0.approve(app, type(uint256).max);

        // Measure first swap (cold storage)
        uint256 gasBefore = gasleft();
        bytes memory takerData = abi.encode(true);
        ABCWeightedSwap(app).swapExactIn(strategy, true, 10, 0, address(this), takerData);
        uint256 gasUsed1 = gasBefore - gasleft();

        // Measure second swap (warm storage)
        gasBefore = gasleft();
        ABCWeightedSwap(app).swapExactIn(strategy, true, 10, 0, address(this), takerData);
        uint256 gasUsed2 = gasBefore - gasleft();

        console.log("ABCWeightedSwap first swap gas:", gasUsed1);
        console.log("ABCWeightedSwap second swap gas:", gasUsed2);
        console.log("Gas reduction from warm storage:", gasUsed1 - gasUsed2);
    }

    function testNoValueLeakage() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();

        // Track initial total value (including taker's balance)
        uint256 initialTotal0 =
            aqua.balances(maker, app, address(token0)) + token0.balanceOf(address(this)) + token0.balanceOf(taker);
        uint256 initialTotal1 =
            aqua.balances(maker, app, address(token1)) + token1.balanceOf(address(this)) + token1.balanceOf(taker);

        // Perform multiple swaps
        swap(app, strategy, true, 10);
        swap(app, strategy, false, 5);
        swap(app, strategy, true, 15);

        // Track final total value (including taker's balance)
        uint256 finalTotal0 =
            aqua.balances(maker, app, address(token0)) + token0.balanceOf(address(this)) + token0.balanceOf(taker);
        uint256 finalTotal1 =
            aqua.balances(maker, app, address(token1)) + token1.balanceOf(address(this)) + token1.balanceOf(taker);

        // Total tokens should be conserved (no creation or destruction)
        assertEq(finalTotal0, initialTotal0, "Total token0 should be conserved");
        assertEq(finalTotal1, initialTotal1, "Total token1 should be conserved");
    }

    function testBidirectionalSwaps() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();

        uint256 token1Out = swap(app, strategy, true, 10);
        uint256 token0Out = swap(app, strategy, false, token1Out);

        assertTrue(token0Out < 10, "Should get back less due to fees");
        assertEq(token0Out, 7, "Should get back 7 tokens after round trip");
    }

    function testMinimumOutputRequirement() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        uint256 amountIn = 10;
        uint256 expectedOut = calculateAmountOut(amountIn, INITIAL_AMOUNT0, INITIAL_AMOUNT1, FEE_BPS);

        vm.prank(taker);
        token0.transfer(address(this), amountIn);
        token0.approve(app, type(uint256).max);

        // Should revert if minimum output is too high
        bytes memory takerData = abi.encode(true);
        vm.expectRevert(abi.encodeWithSelector(ABCWeightedSwap.InsufficientOutputAmount.selector, expectedOut, expectedOut + 1));
        abcWeightedSwap.swapExactIn(strategy, true, amountIn, expectedOut + 1, address(this), takerData);

        // Should succeed with correct minimum
        uint256 amountOut = abcWeightedSwap.swapExactIn(strategy, true, amountIn, expectedOut, address(this), takerData);
        assertEq(amountOut, expectedOut, "Should receive expected amount");
    }

    function testDifferentFeeRates() public {
        // Create strategy with higher fee (1%)
        ABCWeightedSwap.Strategy memory highFeeStrategy = ABCWeightedSwap.Strategy({
            maker: maker,
            token0: address(token0),
            token1: address(token1),
            feeBps: 100, // 1% fee
            salt: bytes32(uint256(1))
        });

        // Reset maker balances
        token0.mint(maker, INITIAL_AMOUNT0);
        token1.mint(maker, INITIAL_AMOUNT1);

        vm.prank(maker);
        aqua.ship(
            address(abcWeightedSwapImpl),
            abi.encode(highFeeStrategy),
            dynamic([address(token0), address(token1)]),
            dynamic([INITIAL_AMOUNT0, INITIAL_AMOUNT1])
        );

        // Compare outputs with different fees
        uint256 amountIn = 10;
        uint256 outputWithLowFee = calculateAmountOut(amountIn, INITIAL_AMOUNT0, INITIAL_AMOUNT1, FEE_BPS);
        uint256 outputWithHighFee = calculateAmountOut(amountIn, INITIAL_AMOUNT0, INITIAL_AMOUNT1, 100);

        // With these small amounts and fees, the difference might be minimal
        // Low fee (0.3%): amountInWithFee = 10 * 9970 / 10000 = 9.97
        // High fee (1%): amountInWithFee = 10 * 9900 / 10000 = 9.9
        // Both calculations might round to the same output with small amounts
        assertTrue(outputWithHighFee <= outputWithLowFee, "Higher fee should result in less or equal output");
        assertEq(outputWithLowFee, 7, "Low fee output should be 7");
        assertEq(outputWithHighFee, 7, "High fee output should be 7");
    }

    function testVerySmallAmounts() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Test with 1 token
        vm.prank(taker);
        token0.transfer(address(this), 1);
        token0.approve(app, type(uint256).max);

        bytes memory takerData = abi.encode(true);
        uint256 amountOut = abcWeightedSwap.swapExactIn(strategy, true, 1, 0, address(this), takerData);
        assertEq(amountOut, 0, "Very small swap should output 0 due to rounding");

        // Test with 2 tokens
        vm.prank(taker);
        token0.transfer(address(this), 2);
        uint256 amountOut2 = abcWeightedSwap.swapExactIn(strategy, true, 2, 0, address(this), takerData);
        assertEq(amountOut2, 0, "2 token swap should output 0 due to rounding");
    }

    // ========== Edge Cases & Error Conditions ==========

    function testZeroAmountSwap() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        bytes memory takerData = abi.encode(true);
        // Zero amount should result in zero output, but with minAmountOut > 0 should revert
        vm.expectRevert(abi.encodeWithSelector(ABCWeightedSwap.InsufficientOutputAmount.selector, 0, 1));
        abcWeightedSwap.swapExactIn(strategy, true, 0, 1, address(this), takerData);
    }

    function testSwapExceedingPoolBalance() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Try to swap amount that would require more output than pool has
        uint256 excessiveAmount = INITIAL_AMOUNT0 * 2;
        vm.prank(taker);
        token0.mint(address(this), excessiveAmount);
        token0.approve(app, type(uint256).max);

        bytes memory takerData = abi.encode(true);
        // This should succeed but output will be less than pool balance
        uint256 amountOut = abcWeightedSwap.swapExactIn(strategy, true, excessiveAmount, 0, address(this), takerData);

        // Output should be less than initial balance (can't drain pool completely due to constant product)
        assertTrue(amountOut < INITIAL_AMOUNT1, "Cannot drain pool completely");

        // Verify pool still has some token1
        uint256 remainingBalance1 = aqua.balances(maker, app, address(token1));
        assertTrue(remainingBalance1 > 0, "Pool should never be completely drained");
    }

    function testMissingTakerAquaPush() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Create a malicious aquaTakerCallback that doesn't deposit
        MaliciousCallback malicious = new MaliciousCallback();

        vm.prank(address(malicious));
        // The error includes parameters, so we need to expect the specific error with its values
        // Since we're trying to swap 10 token0, the expected balance would be 60 (50 initial + 10)
        // but the actual balance remains 50
        vm.expectRevert(abi.encodeWithSelector(AquaApp.MissingTakerAquaPush.selector, address(token0), 50, 60));
        abcWeightedSwap.swapExactIn(strategy, true, 10, 0, address(malicious), "");
    }

    function testInvalidStrategyVerification() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();
        ABCWeightedSwap abcWeightedSwap = ABCWeightedSwap(app);

        // Modify strategy to make it invalid
        strategy.maker = address(0xdead);

        vm.expectRevert(); // Should revert with strategy verification error
        abcWeightedSwap.swapExactIn(strategy, true, 10, 0, address(this), "");
    }

    // ========== Extreme Values ==========

    function testLargeAmountSwaps() public {
        // Create pool with large balances
        uint256 largeAmount = 1e36;
        token0.mint(maker, largeAmount);
        token1.mint(maker, largeAmount);

        ABCWeightedSwap.Strategy memory strategy = ABCWeightedSwap.Strategy({
            maker: maker,
            token0: address(token0),
            token1: address(token1),
            feeBps: FEE_BPS,
            salt: bytes32(uint256(1))
        });

        vm.prank(maker);
        address app = aqua.ship(
            address(abcWeightedSwapImpl),
            abi.encode(strategy),
            dynamic([address(token0), address(token1)]),
            dynamic([largeAmount, largeAmount])
        );

        // Swap a large amount
        uint256 swapAmount = largeAmount / 10;
        token0.mint(address(this), swapAmount);
        token0.approve(app, type(uint256).max);

        bytes memory takerData = abi.encode(true);
        uint256 amountOut = ABCWeightedSwap(app).swapExactIn(strategy, true, swapAmount, 0, address(this), takerData);

        // Verify output is reasonable and no overflow occurred
        assertTrue(amountOut > 0, "Should have positive output");
        assertTrue(amountOut < largeAmount, "Output should be less than pool balance");
    }

    function testMaxFeeScenario() public {
        // Create strategy with maximum possible fee (99.99%)
        ABCWeightedSwap.Strategy memory highFeeStrategy = ABCWeightedSwap.Strategy({
            maker: maker,
            token0: address(token0),
            token1: address(token1),
            feeBps: 9999, // 99.99% fee
            salt: bytes32(uint256(2))
        });

        token0.mint(maker, INITIAL_AMOUNT0);
        token1.mint(maker, INITIAL_AMOUNT1);

        vm.prank(maker);
        address app = aqua.ship(
            address(abcWeightedSwapImpl),
            abi.encode(highFeeStrategy),
            dynamic([address(token0), address(token1)]),
            dynamic([INITIAL_AMOUNT0, INITIAL_AMOUNT1])
        );

        // With 99.99% fee, output should be minimal
        vm.prank(taker);
        token0.transfer(address(this), 100);
        token0.approve(app, type(uint256).max);

        bytes memory takerData = abi.encode(true);
        uint256 amountOut = ABCWeightedSwap(app).swapExactIn(highFeeStrategy, true, 100, 0, address(this), takerData);

        // With 99.99% fee, effective input is only 0.01% of actual input
        assertTrue(amountOut < 1, "With maximum fee, output should be near zero");
    }

    // ========== Strategy Validation ==========

    function testMultipleStrategiesFromSameMaker() public {
        // First strategy creation
        (address app1, ABCWeightedSwap.Strategy memory strategy1) = createStrategy();

        // Create another strategy with different salt
        ABCWeightedSwap.Strategy memory strategy2 = ABCWeightedSwap.Strategy({
            maker: maker,
            token0: address(token0),
            token1: address(token1),
            feeBps: FEE_BPS,
            salt: bytes32(uint256(99)) // Different salt
        });

        token0.mint(maker, INITIAL_AMOUNT0);
        token1.mint(maker, INITIAL_AMOUNT1);

        vm.prank(maker);
        address app2 = aqua.ship(
            address(abcWeightedSwapImpl),
            abi.encode(strategy2),
            dynamic([address(token0), address(token1)]),
            dynamic([INITIAL_AMOUNT0, INITIAL_AMOUNT1])
        );

        // Should create different apps
        assertTrue(app1 != app2, "Should create different apps with different strategies");

        // Both should be functional
        vm.prank(taker);
        token0.transfer(address(this), 20);
        token0.approve(app1, type(uint256).max);
        token0.approve(app2, type(uint256).max);

        bytes memory takerData = abi.encode(true);
        uint256 out1 = ABCWeightedSwap(app1).swapExactIn(strategy1, true, 10, 0, address(this), takerData);
        uint256 out2 = ABCWeightedSwap(app2).swapExactIn(strategy2, true, 10, 0, address(this), takerData);

        // Both swaps should succeed with same output
        assertEq(out1, out2, "Same parameters should give same output");
    }

    function testInvalidTokenAddresses() public {
        // This test verifies that swapping with invalid token addresses fails
        // We can't test invalid addresses during creation since Aqua doesn't validate them
        ABCWeightedSwap.Strategy memory badStrategy = ABCWeightedSwap.Strategy({
            maker: maker,
            token0: address(0), // Invalid token address
            token1: address(token1),
            feeBps: FEE_BPS,
            salt: bytes32(uint256(3))
        });

        // Create app with valid tokens first
        ABCWeightedSwap.Strategy memory validStrategy = ABCWeightedSwap.Strategy({
            maker: maker,
            token0: address(token0),
            token1: address(token1),
            feeBps: FEE_BPS,
            salt: bytes32(uint256(3))
        });

        vm.prank(maker);
        address app = aqua.ship(
            address(abcWeightedSwapImpl),
            abi.encode(validStrategy),
            dynamic([address(token0), address(token1)]),
            dynamic([INITIAL_AMOUNT0, INITIAL_AMOUNT1])
        );

        // Now try to swap with invalid strategy (different token addresses)
        vm.expectRevert(); // Should revert due to strategy verification
        ABCWeightedSwap(app).swapExactIn(badStrategy, true, 10, 0, address(this), "");
    }

    // ========== Integration Tests ==========

    function testRapidConsecutiveSwaps() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();

        // Prepare tokens for multiple swaps
        vm.prank(taker);
        token0.transfer(address(this), 30);
        token0.approve(app, type(uint256).max);

        // Perform rapid consecutive swaps
        uint256[] memory outputs = new uint256[](3);
        bytes memory takerData = abi.encode(true);

        for (uint256 i = 0; i < 3; i++) {
            outputs[i] = ABCWeightedSwap(app).swapExactIn(strategy, true, 10, 0, address(this), takerData);
        }

        // Each subsequent swap should have worse rate
        assertTrue(outputs[0] > outputs[1], "Second swap should have worse rate");
        assertTrue(outputs[1] > outputs[2], "Third swap should have worse rate");
    }

    function testSwapWithDifferentRecipients() public {
        (address app, ABCWeightedSwap.Strategy memory strategy) = createStrategy();

        address recipient1 = address(0x1234);
        address recipient2 = address(0x5678);

        // First swap to recipient1
        vm.prank(taker);
        token0.transfer(address(this), 20);
        token0.approve(app, type(uint256).max);

        bytes memory takerData = abi.encode(true);
        uint256 out1 = ABCWeightedSwap(app).swapExactIn(strategy, true, 10, 0, recipient1, takerData);
        assertEq(token1.balanceOf(recipient1), out1, "Recipient1 should receive output");

        // Second swap to recipient2
        uint256 out2 = ABCWeightedSwap(app).swapExactIn(strategy, true, 10, 0, recipient2, takerData);
        assertEq(token1.balanceOf(recipient2), out2, "Recipient2 should receive output");
    }

    // Helper function to calculate expected output using constant product formula
    function calculateAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    )
        internal
        pure
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * (10_000 - feeBps) / 10_000;
        return (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
    }

    */
}
