// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Aqua } from "./Aqua.sol";
import { Simulator } from "./libs/Simulator.sol";
import { Multicall } from "./libs/Multicall.sol";

contract AquaRouter is Aqua, Simulator, Multicall { }
