// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title squeekchain (SQK)
/// @notice A fixed supply of one billion tokens with 18 decimals, minted once to the deployer.
/// @dev The immediate deployer receives every token, including when a factory performs deployment.
/// There are no administrative functions or externally callable mint or burn functions.
contract Squeekchain is ERC20 {
    /// @notice The entire supply in base units: 1,000,000,000 SQK multiplied by 10^18.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("squeekchain", "SQK") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
