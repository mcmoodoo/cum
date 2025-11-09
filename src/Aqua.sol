// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { IAqua } from "./interfaces/IAqua.sol";
import { Balance, BalanceLib } from "./libs/Balance.sol";

/// @title Aqua - Shared Liquidity Layer
contract Aqua is IAqua, Context {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using BalanceLib for Balance;

    error MaxNumberOfTokensExceeded(uint256 tokensCount, uint256 maxTokensCount);
    error StrategiesMustBeImmutable(address app, bytes32 strategyHash);
    error DockingShouldCloseAllTokens(address app, bytes32 strategyHash);
    error PushToNonActiveStrategyPrevented(address maker, address app, bytes32 strategyHash, address token);
    error SafeBalancesForTokenNotInActiveStrategy(address maker, address app, bytes32 strategyHash, address token);

    uint8 private constant _DOCKED = 0xff;

    mapping(address maker =>
        mapping(address app =>
            mapping(bytes32 strategyHash =>
                mapping(address token => Balance)))) private _balances; // aka makers' allowances

    function rawBalances(address maker, address app, bytes32 strategyHash, address token) external view returns (uint248 amount, uint8 tokensCount) {
        return _balances[maker][app][strategyHash][token].load();
    }

    function safeBalances(address maker, address app, bytes32 strategyHash, address[] calldata tokens) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        mapping(address => Balance) storage tokenBalances = _balances[maker][app][strategyHash];
        for (uint256 i = 0; i < tokens.length; i++) {
            (uint248 amount, uint8 tokensCount) = tokenBalances[tokens[i]].load();
            require(tokensCount > 0 && tokensCount != _DOCKED, SafeBalancesForTokenNotInActiveStrategy(maker, app, strategyHash, tokens[i]));
            amounts[i] = amount;
        }
    }

    function ship(address app, bytes calldata strategy, address[] calldata tokens, uint256[] calldata amounts) external returns(bytes32 strategyHash) {
        address maker = _msgSender();
        strategyHash = keccak256(strategy);
        uint8 tokensCount = tokens.length.toUint8();
        require(tokensCount != _DOCKED, MaxNumberOfTokensExceeded(tokensCount, _DOCKED));

        emit Shipped(maker, app, strategyHash, strategy);
        for (uint256 i = 0; i < tokens.length; i++) {
            Balance storage balance = _balances[maker][app][strategyHash][tokens[i]];
            require(balance.tokensCount == 0, StrategiesMustBeImmutable(app, strategyHash));
            balance.store(amounts[i].toUint248(), tokensCount);
            emit Pushed(maker, app, strategyHash, tokens[i], amounts[i]);
        }
    }

    function dock(address app, bytes32 strategyHash, address[] calldata tokens) external {
        address maker = _msgSender();
        for (uint256 i = 0; i < tokens.length; i++) {
            Balance storage balance = _balances[maker][app][strategyHash][tokens[i]];
            require(balance.tokensCount == tokens.length, DockingShouldCloseAllTokens(app, strategyHash));
            balance.store(0, _DOCKED);
        }
        emit Docked(maker, app, strategyHash);
    }

    function pull(address maker, bytes32 strategyHash, address token, uint256 amount, address to) external {
        address app = _msgSender();
        Balance storage balance = _balances[maker][app][strategyHash][token];
        (uint248 prevBalance, uint8 tokensCount) = balance.load();
        balance.store(prevBalance - amount.toUint248(), tokensCount);

        IERC20(token).safeTransferFrom(maker, to, amount);
        emit Pulled(maker, app, strategyHash, token, amount);
    }

    function push(address maker, address app, bytes32 strategyHash, address token, uint256 amount) external {
        Balance storage balance = _balances[maker][app][strategyHash][token];
        (uint248 prevBalance, uint8 tokensCount) = balance.load();
        require(tokensCount > 0 && tokensCount != _DOCKED, PushToNonActiveStrategyPrevented(maker, app, strategyHash, token));
        balance.store(prevBalance + amount.toUint248(), tokensCount);

        IERC20(token).safeTransferFrom(_msgSender(), maker, amount);
        emit Pushed(maker, app, strategyHash, token, amount);
    }
}
