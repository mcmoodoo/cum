// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAqua } from "./interfaces/IAqua.sol";
import { IVerifier, PrivateVault } from "./libs/pp/PrivateVault.sol";
import { XYCSwap } from "./apps/XYCSwap.sol";

contract AquaVault is PrivateVault, ReentrancyGuard, Ownable {
    IAqua public immutable aqua;
    IVerifier public verifier;

    /// @notice Emitted when a public deposit is made
    event Deposit(address indexed asset, address indexed depositor, uint256 amount);

    /// @notice Emitted when a public withdrawal is made
    event Withdrawal(address indexed asset, address indexed recipient, uint256 amount);

    constructor(
        IAqua aqua_,
        IVerifier verifier_,
        bytes32[] memory initialRoots_,
        address[] memory tokenAddresses_,
        uint256[] memory denominations_

    ) Ownable(msg.sender) PrivateVault(20, initialRoots_, tokenAddresses_, denominations_) {
        aqua = aqua_;
        verifier = verifier_;

        // Pre-approve all supported assets to Aqua
        for (uint256 i = 0; i < tokenAddresses_.length; i++) {
            IERC20(tokenAddresses_[i]).approve(address(aqua_), type(uint256).max);
        }
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
        }

        emit Deposit(asset, msg.sender, amount);
    }

    /// @notice Withdraw assets from the vault with optional private withdrawal
    /// @param proof ZK proof for private withdrawal (empty for public withdrawal)
    /// @param asset The token address to withdraw
    /// @param merkleRoot The Merkle root for private withdrawal
    /// @param nullifierHash The nullifier hash for private withdrawal
    /// @param recipient The recipient address
    /// @param relayer The relayer address (for private withdrawal)
    /// @param fee The relayer fee (for private withdrawal)
    function withdraw(
        bytes calldata proof,
        address asset,
        bytes32 merkleRoot,
        bytes32 nullifierHash,
        address recipient,
        address relayer,
        uint256 fee
    ) external nonReentrant {
        // Get denomination
        uint256 denomination = vaults[asset].denomination;
        require(denomination > 0, "Invalid denomination");

        // Check if we have enough balance in the vault
        uint256 vaultBalance = IERC20(asset).balanceOf(address(this));
        require(vaultBalance >= denomination, "Insufficient vault balance");

        // Perform private withdrawal verification
        _privateWithdraw(verifier, proof, asset, merkleRoot, nullifierHash, recipient, relayer, fee);

        // Transfer to recipient minus fee
        uint256 recipientAmount = denomination - fee;
        IERC20(asset).transfer(recipient, recipientAmount);

        // Transfer fee to relayer if applicable
        if (fee > 0 && relayer != address(0)) {
            IERC20(asset).transfer(relayer, fee);
        }

        emit Withdrawal(asset, recipient, denomination);
    }


    function ship(
        address app,
        bytes calldata strategy,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) public onlyOwner returns (bytes32 strategyHash) {
        // call initial ship on all the apps and strategies
        strategyHash = aqua.ship(
            app,
            strategy,
            tokens,
            amounts
        );
    }

    function dock(
        address app,
        bytes32 strategyHash,
        address[] calldata tokens
    ) public onlyOwner {
        // call dock on the apps and strategies
        aqua.dock(
            app,
            strategyHash,
            tokens
        );
    }
}