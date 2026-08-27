#!/usr/bin/env node
import { access, mkdir, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";

const usage = `Usage: create-taskmarket-hook <project-name> --taskmarket <0x-address> [--hook-name <SolidityName>]

Example:
  npx create-taskmarket-hook my-hook --taskmarket 0x1111111111111111111111111111111111111111 --hook-name MyHook`;

function fail(message) {
  console.error(`Error: ${message}\n\n${usage}`);
  process.exitCode = 1;
}

function parseArgs(args) {
  const [projectName, ...rest] = args;
  const options = {};
  for (let index = 0; index < rest.length; index += 2) {
    const flag = rest[index];
    const value = rest[index + 1];
    if (!flag?.startsWith("--") || !value || options[flag])
      throw new Error("invalid arguments");
    if (flag !== "--taskmarket" && flag !== "--hook-name")
      throw new Error(`unknown option: ${flag}`);
    options[flag] = value;
  }
  return {
    projectName,
    taskmarket: options["--taskmarket"],
    hookName: options["--hook-name"],
  };
}

function solidityName(projectName) {
  const baseName = projectName
    .split("-")
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join("");
  return baseName.endsWith("Hook") ? baseName : `${baseName}Hook`;
}

const maxFileComponentBytes = 255;
const windowsReservedName =
  /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i;

function isPortableFileComponent(component) {
  return (
    Buffer.byteLength(component) <= maxFileComponentBytes &&
    !windowsReservedName.test(component)
  );
}

const dependencies = {
  taskmarket:
    "daydreamsai/taskmarket-contracts@a85cc8dae76e0fc6da9e463375fd2e385710d442",
  openzeppelin:
    "OpenZeppelin/openzeppelin-contracts@fcbae5394ae8ad52d8e580a3477db99814b9d565",
  openzeppelinUpgradeable:
    "OpenZeppelin/openzeppelin-contracts-upgradeable@7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf",
  forgeStd: "foundry-rs/forge-std@1801b0541f4fda118a10798fd3486bb7051c5dd6",
};

const installCommands = [
  `forge install --no-git ${dependencies.taskmarket}`,
  `forge install --no-git ${dependencies.openzeppelin}`,
  `forge install --no-git ${dependencies.openzeppelinUpgradeable}`,
  `forge install --no-git ${dependencies.forgeStd}`,
];

function render(files, values) {
  return Object.fromEntries(
    Object.entries(files).map(([file, contents]) => [
      file
        .replaceAll("{{PROJECT_NAME}}", values.projectName)
        .replaceAll("{{HOOK_NAME}}", values.hookName),
      contents
        .replaceAll("{{PROJECT_NAME}}", values.projectName)
        .replaceAll("{{HOOK_NAME}}", values.hookName)
        .replaceAll("{{TASKMARKET_HEX}}", values.taskmarket.slice(2))
        .replaceAll("{{TASKMARKET_ADDRESS}}", values.taskmarket),
    ]),
  );
}

const template = {
  "foundry.toml": `[profile.default]
src = "src"
test = "test"
script = "script"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
via_ir = true

[rpc_endpoints]
base_sepolia = "\${FORGE_BASE_SEPOLIA_RPC_URL}"

[etherscan]
base_sepolia = { key = "\${FORGE_ETHERSCAN_API_KEY}", chain = 84532, url = "https://api.etherscan.io/v2/api?chainid=84532" }
`,
  "remappings.txt": `@taskmarket/contracts/=lib/taskmarket-contracts/
@openzeppelin/=lib/openzeppelin-contracts/
openzeppelin-contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/
forge-std/=lib/forge-std/src/
`,
  ".env.example": `# A Base Sepolia RPC endpoint and the private key that will deploy the hook.
FORGE_BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
PRIVATE_KEY=
# Used by forge script --verify. Obtain one from Basescan/Etherscan.
FORGE_ETHERSCAN_API_KEY=
`,
  ".gitignore": `.env
out/
cache/
broadcast/
lib/
`,
  "src/{{HOOK_NAME}}.sol": `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";
import {BaseTMPHook} from "@taskmarket/contracts/src/hooks/base/BaseTMPHook.sol";

/// @notice A safe starting point for Taskmarket lifecycle hooks.
/// @dev BaseTMPHook restricts every callback to the configured Taskmarket Diamond, exposes it as
///      \`diamond()\`, and defaults every check to allow. Override only the internal callbacks your
///      policy needs. Keep check hooks deterministic: returning false or reverting blocks the
///      corresponding lifecycle action.
contract {{HOOK_NAME}} is BaseTMPHook {
    event TaskCompleted(bytes32 indexed taskId, address indexed requester);

    constructor(address taskmarket_) BaseTMPHook(taskmarket_) {}

    // Example override: add your completion policy here. Revert or return false to reject.
    function _checkComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata)
        internal
        override
        returns (bool)
    {
        return true;
    }

    function _onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata)
        internal
        override
    {
        emit TaskCompleted(taskId, ctx.requester);
    }
}
`,
  "script/Deploy.s.sol": `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {{{HOOK_NAME}}} from "../src/{{HOOK_NAME}}.sol";

contract Deploy is Script {
    // The Taskmarket address is fixed at scaffold time; update only after verifying the target deployment.
    address constant TASKMARKET = address(bytes20(hex"{{TASKMARKET_HEX}}"));

    function run() external returns ({{HOOK_NAME}} hook) {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        hook = new {{HOOK_NAME}}(TASKMARKET);
        vm.stopBroadcast();
    }
}
`,
  "test/{{HOOK_NAME}}.t.sol": `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";
import {BaseTMPHook} from "@taskmarket/contracts/src/hooks/base/BaseTMPHook.sol";
import {{{HOOK_NAME}}} from "../src/{{HOOK_NAME}}.sol";

contract {{HOOK_NAME}}Test is Test {
    address constant TASKMARKET = address(bytes20(hex"{{TASKMARKET_HEX}}"));
    {{HOOK_NAME}} hook;

    function setUp() public {
        hook = new {{HOOK_NAME}}(TASKMARKET);
    }

    function testCheckClaimAcceptsConfiguredTaskmarket() public {
        vm.prank(TASKMARKET);
        assertTrue(hook.checkClaim(bytes32(0), _context(), address(0xBEEF)));
    }

    function testCheckClaimRejectsEveryoneElse() public {
        vm.expectRevert(
            abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, address(this))
        );
        hook.checkClaim(bytes32(0), _context(), address(0xBEEF));
    }

    function _context() internal pure returns (ITMPCore.TaskContext memory ctx) {}
}
`,
  "test/{{HOOK_NAME}}Lifecycle.t.sol": `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {ITMPCore} from "@taskmarket/contracts/src/interfaces/ITMPCore.sol";
import {ITMPDiamond} from "@taskmarket/contracts/src/interfaces/ITMPDiamond.sol";
import {MockERC20} from "@taskmarket/contracts/src/mocks/MockERC20.sol";
import {DiamondTestHelper} from "@taskmarket/contracts/test/helpers/DiamondTestHelper.sol";
import {noEvaluatorConfig} from "@taskmarket/contracts/test/helpers/EvaluatorConfigHelper.sol";
import {taskConfig} from "@taskmarket/contracts/test/helpers/TaskConfigHelper.sol";
import {MockPGTRForwarder} from "@taskmarket/contracts/test/mocks/MockPGTRForwarder.sol";
import {{{HOOK_NAME}}} from "../src/{{HOOK_NAME}}.sol";

/// @notice Local integration coverage for the generated hook and the pinned Taskmarket dependency.
/// @dev This deploys a fresh local Diamond. It does not use the production address configured for Deploy.
contract {{HOOK_NAME}}LifecycleTest is DiamondTestHelper {
    event TaskCompleted(bytes32 indexed taskId, address indexed requester);

    bytes32 private constant HOOK_REGISTERED = keccak256("HookRegistered(bytes32,address)");
    uint256 private constant REWARD = 100e6;

    address private constant OWNER = address(1);
    address private constant FEE_RECIPIENT = address(2);
    address private constant REQUESTER = address(3);
    address private constant WORKER = address(4);

    ITMPDiamond private market;
    MockERC20 private usdc;
    MockPGTRForwarder private forwarder;

    function setUp() public {
        vm.startPrank(OWNER);
        usdc = new MockERC20("Mock USDC", "USDC", 6, OWNER);
        market = deployDiamond(OWNER, address(usdc), FEE_RECIPIENT, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        usdc.mint(address(forwarder), 10_000e6);
        vm.stopPrank();
    }

    function testGeneratedHookCompletesTaskmarketLifecycle() public {
        {{HOOK_NAME}} defaultHook = new {{HOOK_NAME}}(address(market));
        {{HOOK_NAME}} firstCustomHook = new {{HOOK_NAME}}(address(market));
        {{HOOK_NAME}} secondCustomHook = new {{HOOK_NAME}}(address(market));
        address[] memory hooks = new address[](2);
        hooks[0] = address(firstCustomHook);
        hooks[1] = address(secondCustomHook);

        address[] memory defaults = new address[](1);
        defaults[0] = address(defaultHook);
        vm.prank(OWNER);
        market.setDefaultHooks(defaults);

        vm.recordLogs();
        bytes32 taskId = abi.decode(
            forwarder.relay(
                address(market),
                REQUESTER,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, 1 days, market.BOUNTY()),
                        ITMPCore.StakeConfig({required: false, bps: 0}),
                        ITMPCore.HookConfig({contracts: hooks, data: hex""}),
                        ITMPCore.TaskContent({contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0)}),
                        noEvaluatorConfig()
                    )
                )
            ),
            (bytes32)
        );

        address[] memory registered = _decodeRegisteredHooks(taskId, 3);
        assertEq(registered[0], address(defaultHook), "default decoded HookRegistered address");
        assertEq(registered[1], address(firstCustomHook), "first custom decoded HookRegistered address");
        assertEq(registered[2], address(secondCustomHook), "second custom decoded HookRegistered address");
        address[] memory attached = market.getTaskHooks(taskId);
        assertEq(attached.length, 3, "default and two custom hooks attached");
        assertEq(attached[0], address(defaultHook), "default hook attached first");
        assertEq(attached[1], address(firstCustomHook), "first custom hook attached second");
        assertEq(attached[2], address(secondCustomHook), "second custom hook attached third");

        bytes32 deliverable = keccak256("generated-hook-lifecycle-deliverable");
        forwarder.relay(address(market), WORKER, 0, abi.encodeCall(market.submitWork, (taskId, deliverable)));
        vm.expectEmit(true, true, false, true, address(defaultHook));
        emit TaskCompleted(taskId, REQUESTER);
        vm.expectEmit(true, true, false, true, address(firstCustomHook));
        emit TaskCompleted(taskId, REQUESTER);
        vm.expectEmit(true, true, false, true, address(secondCustomHook));
        emit TaskCompleted(taskId, REQUESTER);
        forwarder.relay(
            address(market), REQUESTER, 0, abi.encodeCall(market.acceptSubmission, (taskId, WORKER, deliverable, 0))
        );
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted), "task accepted");

        emit log_named_address("GOLDEN_HOOK_ADDRESS", address(defaultHook));
        emit log_named_address("GOLDEN_TASKMARKET_ADDRESS", address(market));
        emit log_named_bytes32("GOLDEN_TASK_ID", taskId);
        emit log_named_bytes32("GOLDEN_RUNTIME_CODEHASH", address(defaultHook).codehash);
    }

    function _decodeRegisteredHooks(bytes32 taskId, uint256 expected) private returns (address[] memory registered) {
        registered = new address[](expected);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 index; index < logs.length; index++) {
            Vm.Log memory entry = logs[index];
            if (entry.emitter == address(market) && entry.topics.length == 2 && entry.topics[0] == HOOK_REGISTERED) {
                assertEq(entry.topics[1], taskId, "HookRegistered task ID");
                if (found < expected) registered[found] = abi.decode(entry.data, (address));
                found++;
            }
        }
        assertEq(found, expected, "expected HookRegistered events");
    }
}
`,
  "README.md": `# {{PROJECT_NAME}}

A Taskmarket lifecycle-hook project generated by \`create-taskmarket-hook\`.

The starter hook extends \`BaseTMPHook\` from the Taskmarket contracts, which accepts calls **only** from the Taskmarket deployment configured at generation time: \`{{TASKMARKET_ADDRESS}}\` (readable as \`diamond()\`). The base defaults every check callback to allow, so you override just the internal callbacks your policy needs. Extend the marked \`_checkComplete\` override (or another \`_check*\` / \`_on*\` callback) with your policy; a false return or revert rejects that transition.

## Install

Prerequisites: Node.js 18+, [Foundry](https://book.getfoundry.sh/getting-started/installation), and Git.

\`\`\`sh
${installCommands.join("\n")}
cp .env.example .env
\`\`\`

## Build and test

\`\`\`sh
forge build
forge test -j 1
\`\`\`

## Local Taskmarket lifecycle integration test

\`test/{{HOOK_NAME}}Lifecycle.t.sol\` is a runnable end-to-end local harness using the same
commit-pinned \`@taskmarket/contracts\` dependency installed above. It deploys a fresh Diamond and
PGTR forwarder, configures one generated hook as a protocol default, creates a Bounty task with
two generated custom hooks, proves all three emitted \`HookRegistered\` events and their resolved
default-then-custom ordering, submits work, accepts the submission, and verifies each generated
\`onComplete\` callback event.

Run it on its own while developing hook policy:

\`\`\`sh
forge test -j 1 --match-contract {{HOOK_NAME}}LifecycleTest -vvv
\`\`\`

This is local integration coverage only. It deliberately does not call the configured Base Sepolia
address or require a private key.

## Deploy and verify on Base Sepolia

Set \`PRIVATE_KEY\`, \`FORGE_BASE_SEPOLIA_RPC_URL\`, and \`FORGE_ETHERSCAN_API_KEY\` in \`.env\`. Confirm that the configured Taskmarket address is the Base Sepolia deployment you intend to use before broadcasting.

\`\`\`sh
set -a
. ./.env
set +a
forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --broadcast --verify
\`\`\`

Register the deployed hook when creating a Taskmarket task. Hooks are immutable per task, and check callbacks can block task state transitions, so test your policy thoroughly before using it in production.
`,
};

async function main() {
  let parsed;
  try {
    parsed = parseArgs(process.argv.slice(2));
  } catch {
    return fail("arguments must be flag/value pairs");
  }
  const {
    projectName,
    taskmarket,
    hookName = projectName && solidityName(projectName),
  } = parsed;
  if (!projectName || !/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(projectName))
    return fail("project name must be lowercase kebab-case");
  if (!isPortableFileComponent(projectName))
    return fail("project name is not portable across supported filesystems");
  if (
    !taskmarket ||
    !/^0x[0-9a-fA-F]{40}$/.test(taskmarket) ||
    /^0x0{40}$/i.test(taskmarket)
  )
    return fail("--taskmarket must be a non-zero 20-byte address");
  if (!/^(?:Hook|[A-Z][A-Za-z0-9]*Hook)$/.test(hookName))
    return fail("--hook-name must be a PascalCase name ending in Hook");

  const target = path.resolve(process.cwd(), projectName);
  try {
    await access(target, constants.F_OK);
    return fail(`target already exists: ${target}`);
  } catch {
    /* expected */
  }
  const files = render(template, {
    projectName,
    taskmarket: taskmarket.toLowerCase(),
    hookName,
  });
  const nonPortablePath = Object.keys(files).find((file) =>
    file.split("/").some((component) => !isPortableFileComponent(component)),
  );
  if (nonPortablePath)
    return fail(`generated path is not portable: ${nonPortablePath}`);
  let targetCreated = false;
  try {
    await mkdir(target, { recursive: false });
    targetCreated = true;
    for (const [file, contents] of Object.entries(files)) {
      const destination = path.join(target, file);
      await mkdir(path.dirname(destination), { recursive: true });
      await writeFile(destination, contents);
    }
  } catch (error) {
    if (targetCreated) {
      try {
        await rm(target, { recursive: true, force: true });
      } catch (cleanupError) {
        throw new AggregateError(
          [error, cleanupError],
          `generation failed: ${error.message}; cleanup failed: ${cleanupError.message}`,
        );
      }
    }
    throw error;
  }
  console.log(
    `Created ${target}\n\nNext:\n  cd ${projectName}\n  ${installCommands.join("\n  ")}\n  forge test -j 1`,
  );
}

main().catch((error) => fail(error.message));
