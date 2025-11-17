// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAqua } from "../../src/interfaces/IAqua.sol";
import { IABCWeightedSwapCallback } from "../apps/interfaces/IABCWeightedSwapCallback.sol";
import { AquaApp, TransientLockLib, TransientLock } from "../../src/AquaApp.sol";

import { WeightedMath } from "./libs/WeightedMath.sol";

contract ABCWeightedSwap is AquaApp {
    using Math for uint256;
    using TransientLockLib for TransientLock;

    error InsufficientOutputAmount(uint256 amountOut, uint256 amountOutMin);
    error ExcessiveInputAmount(uint256 amountIn, uint256 amountInMax);
    error InvalidTokenIndices(uint256 indexIn, uint256 indexOut);

    struct Strategy {
        address maker;
        address[] tokens;
		uint256[] normalizedWeights;
        uint256 feeBps;
        bytes32 salt;
    }

    struct InAndOut {
        address tokenIn;
        address tokenOut;
        uint256 weightIn;
        uint256 weightOut;
        uint256 balanceIn;
        uint256 balanceOut;
    }

    modifier validIndices(Strategy calldata strategy, uint256 indexIn, uint256 indexOut) {
        require(indexIn < strategy.tokens.length && indexOut < strategy.tokens.length && indexIn != indexOut, InvalidTokenIndices(indexIn, indexOut));
        _;
    }

	constructor(IAqua aqua_) AquaApp(aqua_) { }

    function quoteExactIn(
        Strategy calldata strategy,
        uint256 amountIn, // amount of tokenIn
		uint256 indexIn, // index of tokenIn
		uint256 indexOut // index of tokenOut
    )
        external
        validIndices(strategy, indexIn, indexOut)
        view
        returns (uint256 amountOut)
    {
        bytes32 strategyHash = keccak256(abi.encode(strategy));
        InAndOut memory io = _getInAndOut(strategy, strategyHash, indexIn, indexOut);
		amountOut = WeightedMath.computeOutGivenExactIn(io.balanceIn, io.weightIn, io.balanceOut, io.weightOut, amountIn);
    }

    function quoteExactOut(
        Strategy calldata strategy,
        uint256 amountOut, // amount of tokenIn
        uint256 indexIn, // index of tokenIn
        uint256 indexOut // index of tokenOut
    )
        external
        validIndices(strategy, indexIn, indexOut)
        view
        returns (uint256 amountIn)
    {
        bytes32 strategyHash = keccak256(abi.encode(strategy));
        InAndOut memory io = _getInAndOut(strategy, strategyHash, indexIn, indexOut);
        amountIn = WeightedMath.computeInGivenExactOut(io.balanceIn, io.weightIn, io.balanceOut, io.weightOut, amountOut);
    }

    function swapExactIn(
        Strategy calldata strategy,
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        bytes calldata takerData
    )
        external
        nonReentrantStrategy(keccak256(abi.encode(strategy)))
        validIndices(strategy, indexIn, indexOut)
        returns (uint256 amountOut)
    {
        bytes32 strategyHash = keccak256(abi.encode(strategy));

        InAndOut memory io = _getInAndOut(strategy, strategyHash, indexIn, indexOut);
        amountOut = WeightedMath.computeOutGivenExactIn(io.balanceIn, io.weightIn, io.balanceOut, io.weightOut, amountIn);
        require(amountOut >= amountOutMin, InsufficientOutputAmount(amountOut, amountOutMin));

        AQUA.pull(strategy.maker, strategyHash, io.tokenOut, amountOut, to);
        IABCWeightedSwapCallback(msg.sender).abcWeightedSwapCallback(io.tokenIn, io.tokenOut, amountIn, amountOut, strategy.maker, address(this), strategyHash, takerData);
        _safeCheckAquaPush(strategy.maker, strategyHash, io.tokenIn, io.balanceIn + amountIn);
    }

    function swapExactOut(
        Strategy calldata strategy,
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountOut,
        uint256 amountInMax,
        address to,
        bytes calldata takerData
    )
        external
        nonReentrantStrategy(keccak256(abi.encode(strategy)))
        validIndices(strategy, indexIn, indexOut)
        returns (uint256 amountIn)
    {
        bytes32 strategyHash = keccak256(abi.encode(strategy));

        InAndOut memory io = _getInAndOut(strategy, strategyHash, indexIn, indexOut);
        amountIn = WeightedMath.computeInGivenExactOut(io.balanceIn, io.weightIn, io.balanceOut, io.weightOut, amountOut);
        require(amountIn <= amountInMax, ExcessiveInputAmount(amountIn, amountInMax));

        AQUA.pull(strategy.maker, strategyHash, io.tokenOut, amountOut, to);
        IABCWeightedSwapCallback(msg.sender).abcWeightedSwapCallback(io.tokenIn, io.tokenOut, amountIn, amountOut, strategy.maker, address(this), strategyHash, takerData);
        _safeCheckAquaPush(strategy.maker, strategyHash, io.tokenIn, io.balanceIn + amountIn);
    }

    function _getInAndOut(Strategy calldata strategy, bytes32 strategyHash, uint256 indexIn, uint256 indexOut) private view returns (InAndOut memory io) {
        io.tokenIn = strategy.tokens[indexIn];
        io.tokenOut = strategy.tokens[indexOut];
        io.weightIn = strategy.normalizedWeights[indexIn];
        io.weightOut = strategy.normalizedWeights[indexOut];
        (io.balanceIn, io.balanceOut) = AQUA.safeBalances(strategy.maker, address(this), strategyHash, io.tokenIn, io.tokenOut);
    }
}
