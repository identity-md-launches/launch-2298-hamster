// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @title Reference deployment of HamsterToken
/// @notice For local and review use only. The IdentityMD launch deploys the token from its built
/// bytecode through the launch factory; this script is not part of that path and takes no
/// configuration, because the token has none: it has no constructor arguments.
/// @dev `deploy()` is the pure deployment step and is what the tests call. `run()` wraps it in a
/// broadcast for whoever runs the script by hand; the broadcaster becomes the holder of the
/// whole supply.
contract DeployHamsterToken is Script {
    /// @notice Deploys a fresh HamsterToken. The caller of `new` (this contract, or the
    /// broadcaster under `run()`) receives the whole supply.
    function deploy() public returns (HamsterToken token) {
        token = new HamsterToken();
    }

    /// @notice Broadcast entry point: `forge script script/DeployHamsterToken.s.sol --broadcast`.
    function run() external returns (HamsterToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
