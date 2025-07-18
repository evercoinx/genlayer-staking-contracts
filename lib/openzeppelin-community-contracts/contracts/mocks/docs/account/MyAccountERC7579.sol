// contracts/MyAccountERC7579.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MODULE_TYPE_VALIDATOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {AccountERC7579} from "../../../account/extensions/AccountERC7579.sol";

contract MyAccountERC7579 is Initializable, AccountERC7579 {
    function initializeAccount(address validator, bytes calldata validatorData) public initializer {
        // Install a validator module to handle signature verification
        _installModule(MODULE_TYPE_VALIDATOR, validator, validatorData);
    }
}
