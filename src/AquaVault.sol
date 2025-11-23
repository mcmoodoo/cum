// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IAqua } from "./interfaces/IAqua.sol";
import { PrivateVault } from "../lib/CUM-Circuit/contracts/src/PrivateVault.sol";

/// @title AquaVault
/// @notice A vault that acts as a single "maker" for Aqua.
///         Liquidity providers deposit the underlying asset and receive shares.
///         Aqua apps draw liquidity from this vault instead of individual LPs.
contract AquaVault is Ownable2Step, ReentrancyGuard, PrivateVault {
    IAqua public immutable AQUA;

    /// @notice Emitted when a strategy is shipped for this vault
    event StrategyShipped(address indexed app, bytes32 indexed strategyHash, bytes strategy, uint256 amount);

    /// @notice Emitted when additional capacity is pushed to an existing strategy
    event StrategyPushed(address indexed app, bytes32 indexed strategyHash, uint256 amount);

    /// @notice Emitted when a strategy is docked for this vault
    event StrategyDocked(address indexed app, bytes32 indexed strategyHash);

    /// @notice Emitted when a public deposit is made
    event Deposit(address indexed asset, address indexed depositor, uint256 amount);

    /// @notice Emitted when a public withdrawal is made
    event Withdrawal(address indexed asset, address indexed recipient, uint256 amount);

    constructor(
        IAqua aqua_,
        string memory name_,
        string memory symbol_,
        address withdrawalVerifier_,
        uint256 treeDepth_,
        bytes32[] memory initialRoots_,
        address[] memory tokenAddresses_,
        uint256[] memory denominations_
    )
        ERC20(name_, symbol_)
        Ownable(msg.sender)
        PrivateVault(withdrawalVerifier_, treeDepth_, initialRoots_, tokenAddresses_, denominations_)
    {
        AQUA = aqua_;
        // Pre-approve all supported assets to Aqua
        for (uint256 i = 0; i < tokenAddresses_.length; i++) {
            IERC20(tokenAddresses_[i]).approve(address(aqua_), type(uint256).max);
        }
    }

    /// @notice Ship a new single-asset strategy for a given app with the specified initial capacity.
    /// @param app The app (strategy implementation) address
    /// @param asset The asset address for this strategy
    /// @param strategy Strategy init data (unhashed, as required by Aqua.ship)
    /// @param amount Initial capacity to make available to the app via Aqua
    /// @return strategyHash The keccak256 hash of the strategy bytes
    function shipStrategySingle(
        address app,
        address asset,
        bytes calldata strategy,
        uint256 amount
    ) external onlyOwner returns (bytes32 strategyHash) {
        address[] memory tokens = new address[](1);
        tokens[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        strategyHash = AQUA.ship(app, strategy, tokens, amounts);
        emit StrategyShipped(app, strategyHash, strategy, amount);
    }

    /// @notice Push additional capacity for an already shipped strategy (single-asset).
    /// @param app The app address
    /// @param strategyHash The hash of the previously shipped strategy
    /// @param asset The asset address for this strategy
    /// @param amount Additional capacity to add
    function pushCapacitySingle(
        address app,
        bytes32 strategyHash,
        address asset,
        uint256 amount
    ) external onlyOwner {
        AQUA.push(address(this), app, strategyHash, asset, amount);
        emit StrategyPushed(app, strategyHash, amount);
    }

    /// @notice Dock a previously shipped single-asset strategy.
    /// @param app The app address
    /// @param strategyHash The hash of the previously shipped strategy
    /// @param asset The asset address for this strategy
    function dockStrategySingle(address app, bytes32 strategyHash, address asset) external onlyOwner {
        address[] memory tokens = new address[](1);
        tokens[0] = asset;
        AQUA.dock(app, strategyHash, tokens);
        emit StrategyDocked(app, strategyHash);
    }

    /// @notice Deposit assets into the vault with optional private deposit
    /// @param asset The token address to deposit
    /// @param amount The amount to deposit
    /// @param commitment Optional commitment for private deposit (pass bytes32(0) for public deposit)
    function deposit(
        address asset,
        uint256 amount,
        bytes32 commitment
    ) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer tokens from depositor to vault
        IERC20(asset).transferFrom(msg.sender, address(this), amount);

        // If commitment is provided, handle as private deposit
        if (commitment != bytes32(0)) {
            // Get the vault denomination
            uint256 denomination = vaults[asset].denomination;
            require(amount == denomination, "Amount must match denomination for private deposit");

            // Perform private deposit
            _privateDeposit(asset, commitment);

            // Update denomination to account for the new balance
            uint256 newTotalBalance = IERC20(asset).balanceOf(address(this));
            uint256 newLeafCount = vaults[asset].currentLeafIndex;
            if (newLeafCount > 0) {
                uint256 newDenomination = newTotalBalance / newLeafCount;
                setDenomination(asset, newDenomination);
            }
        }

        emit Deposit(asset, msg.sender, amount);
    }

    /// @notice Withdraw assets from the vault with optional private withdrawal
    /// @param proof ZK proof for private withdrawal (empty for public withdrawal)
    /// @param asset The token address to withdraw
    /// @param amount Amount to withdraw (for public withdrawal)
    /// @param merkleRoot The Merkle root for private withdrawal
    /// @param nullifierHash The nullifier hash for private withdrawal
    /// @param recipient The recipient address
    /// @param relayer The relayer address (for private withdrawal)
    /// @param fee The relayer fee (for private withdrawal)
    function withdraw(
        bytes calldata proof,
        address asset,
        uint256 amount,
        bytes32 merkleRoot,
        bytes32 nullifierHash,
        address recipient,
        address relayer,
        uint256 fee
    ) external nonReentrant {
        // Perform private withdrawal verification
        _privateWithdraw(proof, asset, merkleRoot, nullifierHash, recipient, relayer, fee);

        // Get denomination and transfer
        uint256 denomination = vaults[asset].denomination;
        require(denomination > 0, "Invalid denomination");

        // Transfer to recipient minus fee
        uint256 recipientAmount = denomination - fee;
        IERC20(asset).transfer(recipient, recipientAmount);

        // Transfer fee to relayer if applicable
        if (fee > 0 && relayer != address(0)) {
            IERC20(asset).transfer(relayer, fee);
        }

        // Update denomination to account for the new balance
        uint256 newTotalBalance = IERC20(asset).balanceOf(address(this));
        uint256 leafCount = vaults[asset].currentLeafIndex;
        if (leafCount > 0) {
            uint256 newDenomination = newTotalBalance / leafCount;
            setDenomination(asset, newDenomination);
        }

        emit Withdrawal(asset, recipient, denomination);
    }
}

