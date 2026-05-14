// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

interface ICheatCodes {
    function ffi(string[] calldata) external returns (bytes memory);
}

contract ShellDeployer {
    address internal constant HEVM_ADDRESS = address(bytes20(uint160(uint256(keccak256("hevm cheat code")))));

    ICheatCodes internal constant cheatCodes = ICheatCodes(HEVM_ADDRESS);

    function deployWithShell(string memory shellCmd) public returns (address deployedAddress) {
        string[] memory cmds = new string[](3);
        cmds[0] = "/bin/bash";
        cmds[1] = "-lc";
        cmds[2] = shellCmd;

        bytes memory bytecode = cheatCodes.ffi(cmds);
        assembly {
            deployedAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        require(deployedAddress != address(0), "deploy failed");
    }

    function deployWithShell(string memory shellCmd, bytes memory args) public returns (address deployedAddress) {
        string[] memory cmds = new string[](3);
        cmds[0] = "/bin/bash";
        cmds[1] = "-lc";
        cmds[2] = shellCmd;

        bytes memory bytecode = abi.encodePacked(cheatCodes.ffi(cmds), args);
        assembly {
            deployedAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        require(deployedAddress != address(0), "deploy failed");
    }
}
