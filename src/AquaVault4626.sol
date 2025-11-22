// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAqua } from "./interfaces/IAqua.sol";

/// @title AquaVault4626
/// @notice ERC4626 vault that acts as a single "maker" for Aqua.
///         Liquidity providers deposit the underlying asset and receive shares.
///         Aqua apps draw liquidity from this vault instead of individual LPs.
/// @dev This vault is single-asset by ERC4626 design. For multi-token strategies,
///      deploy one vault per token or build a higher-level coordinator that owns multiple vaults.
contract AquaVault4626 is ERC4626, Ownable2Step {
    IAqua public immutable AQUA;

    /// @notice Emitted when a strategy is shipped for this vault
    event StrategyShipped(address indexed app, bytes32 indexed strategyHash, bytes strategy, uint256 amount);

    /// @notice Emitted when additional capacity is pushed to an existing strategy
    event StrategyPushed(address indexed app, bytes32 indexed strategyHash, uint256 amount);

    /// @notice Emitted when a strategy is docked for this vault
    event StrategyDocked(address indexed app, bytes32 indexed strategyHash);

    constructor(
        IERC20 asset_,
        IAqua aqua_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(asset_) Ownable(msg.sender) {
        AQUA = aqua_;
        // Pre-approve Aqua to pull the underlying from this vault.
        // Aqua contract calls token.transferFrom(maker=vault, ...) on pull.
        asset_.approve(address(aqua_), type(uint256).max);
    }

    /// @notice Ship a new single-asset strategy for a given app with the specified initial capacity.
    /// @param app The app (strategy implementation) address
    /// @param strategy Strategy init data (unhashed, as required by Aqua.ship)
    /// @param amount Initial capacity to make available to the app via Aqua
    /// @return strategyHash The keccak256 hash of the strategy bytes
    function shipStrategySingle(
        address app,
        bytes calldata strategy,
        uint256 amount
    ) external onlyOwner returns (bytes32 strategyHash) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(asset());
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        strategyHash = AQUA.ship(app, strategy, tokens, amounts);
        emit StrategyShipped(app, strategyHash, strategy, amount);
    }

    /// @notice Push additional capacity for an already shipped strategy (single-asset).
    /// @param app The app address
    /// @param strategyHash The hash of the previously shipped strategy
    /// @param amount Additional capacity to add
    function pushCapacitySingle(
        address app,
        bytes32 strategyHash,
        uint256 amount
    ) external onlyOwner {
        AQUA.push(address(this), app, strategyHash, address(asset()), amount);
        emit StrategyPushed(app, strategyHash, amount);
    }

    /// @notice Dock a previously shipped single-asset strategy.
    /// @param app The app address
    /// @param strategyHash The hash of the previously shipped strategy
    function dockStrategySingle(address app, bytes32 strategyHash) external onlyOwner {
        address[] memory tokens = new address[](1);
        tokens[0] = address(asset());
        AQUA.dock(app, strategyHash, tokens);
        emit StrategyDocked(app, strategyHash);
    }
}

