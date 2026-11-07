#!/usr/bin/env node
import { access, mkdir, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";

const usage = `Usage: create-taskmarket-hook <project-name> --taskmarket <0x-address> [--hook-name <SolidityName>] [--network <base-sepolia|tempo-moderato>] [--hook-version <1|2>]

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
    if (
      flag !== "--taskmarket" &&
      flag !== "--hook-name" &&
      flag !== "--network" &&
      flag !== "--hook-version"
    )
      throw new Error(`unknown option: ${flag}`);
    options[flag] = value;
  }
  return {
    projectName,
    taskmarket: options["--taskmarket"],
    hookName: options["--hook-name"],
    network: options["--network"],
    hookVersion: options["--hook-version"],
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
const windowsReservedName = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i;

function isPortableFileComponent(component) {
  return (
    Buffer.byteLength(component) <= maxFileComponentBytes &&
    !windowsReservedName.test(component)
  );
}

const dependencies = {
  taskmarket:
    "daydreamsai/taskmarket-contracts@570c607ee2b11e8757adfdd31da22bc5088bed31",
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
        .replaceAll("{{DEPLOY_SECTION}}", values.network.deploySection)
        .replaceAll("{{NETWORK_LABEL}}", values.network.label)
        .replaceAll("{{TASKMARKET_HEX}}", values.taskmarket.slice(2))
        .replaceAll("{{TASKMARKET_ADDRESS}}", values.taskmarket),
    ])
  );
}

const foundryDefaults = `[profile.default]
src = "src"
test = "test"
script = "script"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
via_ir = true
`;

// Tempo has no native gas token: transactions pay fees in a TIP-20 stablecoin, and contracts are
// verified through Sourcify at contracts.tempo.xyz rather than an Etherscan API.
const moderatoFeeToken = "0x20c0000000000000000000006a37da5c996874be";
const tempoVerifier = "https://contracts.tempo.xyz";

const networks = {
  "base-sepolia": {
    label: "Base Sepolia",
    files: {
      "foundry.toml": `${foundryDefaults}
[rpc_endpoints]
base_sepolia = "\${FORGE_BASE_SEPOLIA_RPC_URL}"

[etherscan]
base_sepolia = { key = "\${FORGE_ETHERSCAN_API_KEY}", chain = 84532, url = "https://api.etherscan.io/v2/api?chainid=84532" }
`,
      ".env.example": `# A Base Sepolia RPC endpoint and the private key that will deploy the hook.
FORGE_BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
PRIVATE_KEY=
# Used by forge script --verify. Obtain one from Basescan/Etherscan.
FORGE_ETHERSCAN_API_KEY=
`,
    },
    deploySection: `## Deploy and verify on Base Sepolia

Set \`PRIVATE_KEY\`, \`FORGE_BASE_SEPOLIA_RPC_URL\`, and \`FORGE_ETHERSCAN_API_KEY\` in \`.env\`. Confirm that the configured Taskmarket address is the Base Sepolia deployment you intend to use before broadcasting.

\`\`\`sh
set -a
. ./.env
set +a
forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --broadcast --verify
\`\`\``,
  },
  "tempo-moderato": {
    label: "Tempo Moderato",
    files: {
      "foundry.toml": `${foundryDefaults}
# Deploy with FOUNDRY_PROFILE=tempo so forge builds Tempo transactions.
[profile.tempo]
network = "tempo"

[rpc_endpoints]
tempo_moderato = "\${FORGE_TEMPO_MODERATO_RPC_URL}"
`,
      ".env.example": `# A Tempo Moderato (chain 42431) RPC endpoint and the private key that will deploy the hook.
FORGE_TEMPO_MODERATO_RPC_URL=
PRIVATE_KEY=
# Tempo has no native gas token. Fees are paid in this TIP-20 stablecoin (OUSD on Moderato);
# the deployer must hold a balance of it.
FORGE_FEE_TOKEN=${moderatoFeeToken}
`,
    },
    deploySection: `## Deploy and verify on Tempo Moderato

Set \`PRIVATE_KEY\`, \`FORGE_TEMPO_MODERATO_RPC_URL\`, and \`FORGE_FEE_TOKEN\` in \`.env\`. Tempo has no native gas token: the deployer pays fees in the TIP-20 stablecoin named by \`FORGE_FEE_TOKEN\` and must hold a balance of it. Verification goes to Sourcify at \`${tempoVerifier}\` and needs no API key. Confirm that the configured Taskmarket address is the Tempo Moderato deployment you intend to use before broadcasting.

\`\`\`sh
set -a
. ./.env
set +a
FOUNDRY_PROFILE=tempo forge script script/Deploy.s.sol:Deploy --rpc-url tempo_moderato \\
  --tempo.fee-token "$FORGE_FEE_TOKEN" --broadcast \\
  --verify --verifier sourcify --verifier-url ${tempoVerifier}
\`\`\``,
  },
};

const template = {
  "remappings.txt": `@taskmarket/contracts/=lib/taskmarket-contracts/
@openzeppelin/=lib/openzeppelin-contracts/
openzeppelin-contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/
forge-std/=lib/forge-std/src/
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
    struct DefaultTerms {
        uint8 version;
        bool stakeRequired;
        uint16 stakeBps;
        uint8 penaltyTo;
        uint32 reviewWindowSecs;
        uint32 decisionWindowSecs;
        uint32 reopenExtensionSecs;
        uint8 releaseAllowed;
        uint16 releaseGraceBps;
        uint8 rejectOutcome;
        uint16 rejectFeeBps;
        uint8 maxRevisions;
        uint32 resolutionWindowSecs;
    }

    struct DefaultTermsV2 {
        uint8 version;
        bool stakeRequired;
        uint16 stakeBps;
        uint8 penaltyTo;
        uint32 reviewWindowSecs;
        uint32 decisionWindowSecs;
        uint32 reopenExtensionSecs;
        uint8 releaseAllowed;
        uint16 releaseGraceBps;
        uint8 rejectOutcome;
        uint16 rejectFeeBps;
        uint8 maxRevisions;
        uint32 resolutionWindowSecs;
        uint32 acceptWindowSecs;
    }

    bytes4 private constant TERMS_V2_CREATE_TASK = bytes4(
        keccak256(
            "createTask((uint256,uint256,bytes4,uint256,uint256,bytes4),(address[],bytes),(bytes32,string,bytes32[]),(address,uint256,uint16,uint32,uint32,address),(uint8,bool,uint16,uint8,uint32,uint32,uint32,uint8,uint16,uint8,uint16,uint8,uint32,uint32))"
        )
    );

    bytes4 private constant TERMS_CREATE_TASK = bytes4(
        keccak256(
            "createTask((uint256,uint256,bytes4,uint256,uint256,bytes4),(address[],bytes),(bytes32,string,bytes32[]),(address,uint256,uint16,uint32,uint32,address),(uint8,bool,uint16,uint8,uint32,uint32,uint32,uint8,uint16,uint8,uint16,uint8,uint32))"
        )
    );

    address private constant OWNER = address(1);
    address private constant FEE_RECIPIENT = address(2);
    address private constant REQUESTER = address(3);
    address private constant WORKER = address(4);

    ITMPDiamond private market;
    MockERC20 private usdc;
    MockPGTRForwarder private forwarder;

    /// @dev createTask calldata for the pinned dependency's diamond. From rev025 createTask takes
    ///      settlement terms in place of the stake config, and rev026 removed the older overload, so
    ///      the call is encoded for whichever one ITMPDiamond declares. The terms are version 1 with
    ///      every other field at its protocol default (zero). DefaultTerms mirrors TaskTerms field
    ///      for field (enums as uint8), so it ABI-encodes the same on a dependency that predates
    ///      TaskTerms. Version 2 terms (rev027) add acceptWindowSecs, which stays zero here.
    function _createTaskCall(address[] memory hooks) private view returns (bytes memory) {
        bytes4 selector = ITMPDiamond.createTask.selector;
        ITMPCore.TaskConfig memory config = taskConfig(REWARD, 1 days, market.BOUNTY());
        ITMPCore.HookConfig memory hookConfig = ITMPCore.HookConfig({contracts: hooks, data: hex""});
        ITMPCore.TaskContent memory content =
            ITMPCore.TaskContent({contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0)});
        if (selector == TERMS_V2_CREATE_TASK) {
            DefaultTermsV2 memory termsV2;
            termsV2.version = 2;
            return abi.encodeWithSelector(selector, config, hookConfig, content, noEvaluatorConfig(), termsV2);
        }
        if (selector != TERMS_CREATE_TASK) {
            return abi.encodeWithSelector(
                selector, config, ITMPCore.StakeConfig({required: false, bps: 0}), hookConfig, content, noEvaluatorConfig()
            );
        }
        DefaultTerms memory terms;
        terms.version = 1;
        return abi.encodeWithSelector(selector, config, hookConfig, content, noEvaluatorConfig(), terms);
    }

    function setUp() public {
        vm.startPrank(OWNER);
        usdc = new MockERC20("Mock USDC", "USDC", 6, OWNER);
        market = deployDiamond(OWNER, address(usdc), FEE_RECIPIENT, 500);
        // This hook implements the V1 ITMPHook interface. From diamond revision rev028 on, new
        // tasks take Task Hook V2 hooks only, and V1 hooks serve tasks created before that cut,
        // so the lifecycle runs on a diamond placed at rev027.
        placeAtVersion(address(market), 27);
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
                _createTaskCall(hooks)
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

This is local integration coverage only. It deliberately does not call the configured
{{NETWORK_LABEL}} address or require a private key.

{{DEPLOY_SECTION}}

Register the deployed hook when creating a Taskmarket task. Hooks are immutable per task, and check callbacks can block task state transitions, so test your policy thoroughly before using it in production.
`,
};

// Task Hook V2 (rev028), generated with --hook-version 2. BaseTMPHookV2 owns onlyDiamond, ERC-165
// and the allow-by-default before-callbacks, so the generated hook only declares and overrides the
// callbacks it uses. V2 is the default; --hook-version 1 still generates a V1 hook for tasks created
// before rev028.
const templateV2 = {
  "remappings.txt": template["remappings.txt"],
  ".gitignore": template[".gitignore"],
  "script/Deploy.s.sol": template["script/Deploy.s.sol"],
  "src/{{HOOK_NAME}}.sol": `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTMPHookV2} from "@taskmarket/contracts/src/hooks/base/BaseTMPHookV2.sol";

/// @notice A safe starting point for a Taskmarket Task Hook V2.
/// @dev BaseTMPHookV2 restricts every callback to the configured Taskmarket Diamond, exposes it as
///      \`diamond()\`, answers ERC-165 for ITMPHookV2, reports \`minDiamondVersion() == 28\`, allows
///      every before-callback by default and ignores every after-callback. The diamond calls only
///      the callbacks whose capability bit the hook declares, and records the hook's codehash at
///      attach: deploy a new hook rather than upgrading one in place. A before-callback allows by
///      returning its own selector and vetoes by reverting. After-callbacks are best-effort and
///      carry a sequence number, so a missed call can be detected and reconciled against
///      getTaskSettlement.
contract {{HOOK_NAME}} is BaseTMPHookV2 {
    /// @notice Capability bit 21: afterComplete. Bits 0-15 are the before-callbacks (Create .. Rate),
    ///         21-24 afterComplete, afterCancel, afterExpire, afterForfeit, 25 afterAction.
    uint32 public constant CAPABILITIES = uint32(1) << 21;

    event TaskCompleted(bytes32 indexed taskId, address indexed requester, uint128 workerPaid, uint64 seq);

    constructor(address taskmarket_) BaseTMPHookV2(taskmarket_) {}

    /// @notice Declare only the callbacks this hook implements. Here: the after-complete callback.
    function hookCapabilities() external pure override returns (uint32) {
        return CAPABILITIES;
    }

    function afterComplete(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata amounts, uint64 seq)
        external
        override
        onlyDiamond
    {
        emit TaskCompleted(taskId, ctx.requester, amounts.workerPaid, seq);
    }
}
`,
  "test/{{HOOK_NAME}}.t.sol": `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITMPHookV2} from "@taskmarket/contracts/src/interfaces/ITMPHookV2.sol";
import {BaseTMPHookV2} from "@taskmarket/contracts/src/hooks/base/BaseTMPHookV2.sol";
import {{{HOOK_NAME}}} from "../src/{{HOOK_NAME}}.sol";

contract {{HOOK_NAME}}Test is Test {
    address constant TASKMARKET = address(bytes20(hex"{{TASKMARKET_HEX}}"));
    {{HOOK_NAME}} hook;

    function setUp() public {
        hook = new {{HOOK_NAME}}(TASKMARKET);
    }

    function testSupportsHookV2Interface() public view {
        assertTrue(hook.supportsInterface(type(ITMPHookV2).interfaceId));
    }

    function testDeclaresOnlyAfterComplete() public view {
        assertEq(hook.hookCapabilities(), uint32(1) << 21);
    }

    function testRequiresRev028Diamond() public view {
        assertEq(hook.minDiamondVersion(), 28);
    }

    function testAfterCompleteAcceptsConfiguredTaskmarket() public {
        vm.prank(TASKMARKET);
        hook.afterComplete(bytes32(0), _context(), _amounts(), 0);
    }

    function testAfterCompleteRejectsEveryoneElse() public {
        vm.expectRevert(
            abi.encodeWithSelector(BaseTMPHookV2.BaseTMPHookV2__UnauthorizedCaller.selector, address(this))
        );
        hook.afterComplete(bytes32(0), _context(), _amounts(), 0);
    }

    function _context() internal pure returns (ITMPHookV2.TaskContextV2 memory ctx) {}

    function _amounts() internal pure returns (ITMPHookV2.SettlementAmounts memory amounts) {}
}
`,
  "README.md": `# {{PROJECT_NAME}}

A Taskmarket Task Hook V2 project generated by \`create-taskmarket-hook\`.

The starter hook extends \`BaseTMPHookV2\` from the Taskmarket contracts (rev028 and later), which accepts calls **only** from the Taskmarket deployment configured at generation time: \`{{TASKMARKET_ADDRESS}}\` (readable as \`diamond()\`). Declare the callbacks your hook implements in \`hookCapabilities()\`; the diamond calls nothing else. Override the matching \`before*\` callback (keep \`onlyDiamond\`; return its own selector to allow, revert to veto) or \`after*\` callback to observe it. Bits 0-15 are the before-callbacks from Create to Rate, 21-24 \`afterComplete\`, \`afterCancel\`, \`afterExpire\` and \`afterForfeit\`, and 25 \`afterAction\`. \`beforeCreate\` receives the hook's own configuration bytes. After-callbacks are best-effort and carry a sequence number and the amounts that moved; reconcile a missed one with \`getTaskSettlement(taskId)\`.

The diamond records the hook's runtime codehash when a task attaches it and refuses vetoable actions if the code changes, so deploy a new hook rather than upgrading one in place.

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

{{DEPLOY_SECTION}}

Attach the deployed hook when creating a Taskmarket task. The attachment is fixed for the life of the task, and before-callbacks can block task actions, so test your policy thoroughly before using it in production. Non-vetoable exits (forfeit, expiry refund, timeouts, lapsed review, finalize after expiry and dispute resolution) always complete whatever the hook does.
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
    network = "base-sepolia",
    hookVersion = "2",
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
  if (!Object.hasOwn(networks, network))
    return fail("--network must be base-sepolia or tempo-moderato");

  if (hookVersion !== "1" && hookVersion !== "2")
    return fail("--hook-version must be 1 or 2");

  const target = path.resolve(process.cwd(), projectName);
  try {
    await access(target, constants.F_OK);
    return fail(`target already exists: ${target}`);
  } catch {
    /* expected */
  }
  const files = render(
    {
      ...networks[network].files,
      ...(hookVersion === "1" ? template : templateV2),
    },
    {
      projectName,
      taskmarket: taskmarket.toLowerCase(),
      hookName,
      network: networks[network],
    }
  );
  const nonPortablePath = Object.keys(files).find((file) =>
    file.split("/").some((component) => !isPortableFileComponent(component))
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
          `generation failed: ${error.message}; cleanup failed: ${cleanupError.message}`
        );
      }
    }
    throw error;
  }
  console.log(
    `Created ${target}\n\nNext:\n  cd ${projectName}\n  ${installCommands.join(
      "\n  "
    )}\n  forge test -j 1`
  );
}

main().catch((error) => fail(error.message));
