// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/TaskMarket.sol";

contract DeployTestnet is Script {
    address constant CIRCLE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant REPUTATION_REGISTRY = 0x8004B663056A597Dffe9eCcC1965A193B7388713;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        uint16 feeBps = uint16(vm.envUint("FORGE_DEFAULT_PLATFORM_FEE_BPS"));
        address serverAddress = vm.envAddress("FORGE_SERVER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        TaskMarket implementation = new TaskMarket();
        bytes memory initData = abi.encodeCall(
            TaskMarket.initialize, (CIRCLE_USDC, deployer, feeBps)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        TaskMarket market = TaskMarket(address(proxy));
        market.addForwarder(serverAddress);
        market.setReputationRegistry(REPUTATION_REGISTRY);

        vm.stopBroadcast();

        console.log("Proxy (CONTRACT_ADDRESS):", address(proxy));
        console.log("Implementation:", address(implementation));
        console.log("USDC:", CIRCLE_USDC);
        console.log("Trusted forwarder:", serverAddress);
        console.log("Reputation registry:", REPUTATION_REGISTRY);
    }
}
