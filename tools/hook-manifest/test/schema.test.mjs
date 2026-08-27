import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const schema = JSON.parse(
  readFileSync(
    new URL("../../../schemas/taskmarket-hook.schema.json", import.meta.url),
    "utf8",
  ),
);
const fixture = (name) =>
  JSON.parse(
    readFileSync(new URL(`../fixtures/${name}`, import.meta.url), "utf8"),
  );
const immutable = () => fixture("valid/simple-immutable.json");
const proxy = () => fixture("valid/advanced-proxy.json");
const multiChain = () => fixture("valid/multi-chain-proxies.json");
const portalReady = () => fixture("valid/portal-ready.json");
const ajv = new Ajv2020({
  allErrors: true,
  strict: true,
});
addFormats(ajv);
const validateSchema = ajv.compile(schema);

function assertSchemaInvalid(manifest, expectedPaths) {
  assert.equal(validateSchema(manifest), false);
  const errors = validateSchema.errors ?? [];
  for (const path of expectedPaths) {
    assert.ok(
      errors.some((error) => error.instancePath === path),
      `expected AJV error at ${path}:\n${JSON.stringify(errors, null, 2)}`,
    );
  }
}

function placeholderProxy() {
  const manifest = proxy();
  const zeroAddress = `0x${"0".repeat(40)}`;
  const zeroHash = `0x${"0".repeat(64)}`;
  manifest.source.commit = "0000000";
  manifest.deployments[0].hook = zeroAddress;
  manifest.deployments[0].taskmarketDiamond = zeroAddress;
  manifest.deployments[0].deployment.transactionHash = zeroHash;
  manifest.deployments[0].deployment.blockNumber = 0;
  manifest.deployments[0].runtimeCodehash = zeroHash;
  manifest.deployments[0].creationCodehash = zeroHash;
  manifest.deployments[0].proxy.implementation = zeroAddress;
  manifest.deployments[0].proxy.admin = zeroAddress;
  manifest.deployments[0].proxy.timelock = zeroAddress;
  manifest.privilegedRoles[0].holders[0].address = zeroAddress;
  manifest.externalDependencies[0].deployments[0].addresses[0] = zeroAddress;
  manifest.deployments[0].gas.estimates.checkFund.typical = 0;
  manifest.deployments[0].gas.estimates.checkFund.maximum = 0;
  return manifest;
}

test("canonical schema compiles with the exact strict Ajv 2020 configuration", () => {
  const strictAjv = new Ajv2020({ strict: true });
  addFormats(strictAjv);
  assert.doesNotThrow(() => strictAjv.compile(schema));
});

test("AJV validates all ready fixtures against the canonical Draft 2020-12 schema", () => {
  for (const name of [
    "valid/simple-immutable.json",
    "valid/advanced-proxy.json",
    "valid/multi-chain-proxies.json",
    "valid/portal-ready.json",
  ]) {
    const manifest = fixture(name);
    assert.equal(
      validateSchema(manifest),
      true,
      JSON.stringify(validateSchema.errors, null, 2),
    );
  }
});

test("AJV rejects deployment network labels beyond the portal-safe boundary", () => {
  const manifest = portalReady();
  manifest.deployments[0].network = "n".repeat(121);

  assertSchemaInvalid(manifest, ["/deployments/0/network"]);
  assert.ok(
    validateSchema.errors?.some(
      (error) => error.keyword === "maxLength" && error.params.limit === 120,
    ),
    JSON.stringify(validateSchema.errors, null, 2),
  );
});

test("AJV accepts JavaScript safe-integer boundaries for every manifest numeric field", () => {
  const max = Number.MAX_SAFE_INTEGER;
  const manifest = proxy();
  manifest.deployments[0].chainId = max;
  manifest.deployments[0].deployment.blockNumber = max;
  for (const estimate of Object.values(manifest.deployments[0].gas.estimates)) {
    estimate.typical = max;
    estimate.maximum = max;
  }
  manifest.sourceVerification.verifiers[0].chainId = max;
  manifest.privilegedRoles = [
    {
      name: "max-safe authority",
      holders: [
        { chainId: max, address: "0x3333333333333333333333333333333333333333" },
      ],
      capabilities: ["emergency pause"],
    },
  ];
  manifest.externalDependencies = [
    {
      name: "max-safe dependency",
      kind: "contract",
      purpose: "Boundary coverage.",
      deployments: [
        {
          chainId: max,
          addresses: ["0x4444444444444444444444444444444444444444"],
        },
      ],
    },
  ];
  manifest.protocolDefault = {
    status: "default-on-all-declared-chains",
    chains: [max],
    evidence: "https://example.com/default",
  };
  assert.equal(
    validateSchema(manifest),
    true,
    JSON.stringify(validateSchema.errors, null, 2),
  );
});

test("AJV rejects unsafe numeric values at every indexed manifest field", () => {
  const unsafe = Number.MAX_SAFE_INTEGER + 1;
  const cases = [
    [
      "deployment chain",
      "/deployments/0/chainId",
      (manifest) => {
        manifest.deployments[0].chainId = unsafe;
      },
    ],
    [
      "deployment block",
      "/deployments/0/deployment/blockNumber",
      (manifest) => {
        manifest.deployments[0].deployment.blockNumber = unsafe;
      },
    ],
    [
      "gas typical",
      "/deployments/0/gas/estimates/checkFund/typical",
      (manifest) => {
        manifest.deployments[0].gas.estimates.checkFund.typical = unsafe;
      },
    ],
    [
      "gas maximum",
      "/deployments/0/gas/estimates/checkFund/maximum",
      (manifest) => {
        manifest.deployments[0].gas.estimates.checkFund.maximum = unsafe;
      },
    ],
    [
      "verifier chain",
      "/sourceVerification/verifiers/0/chainId",
      (manifest) => {
        manifest.sourceVerification.verifiers[0].chainId = unsafe;
      },
    ],
    [
      "role holder chain",
      "/privilegedRoles/0/holders/0/chainId",
      (manifest) => {
        manifest.privilegedRoles[0].holders[0].chainId = unsafe;
      },
    ],
    [
      "dependency binding chain",
      "/externalDependencies/0/deployments/0/chainId",
      (manifest) => {
        manifest.externalDependencies[0].deployments[0].chainId = unsafe;
      },
    ],
    [
      "protocol default chain",
      "/protocolDefault/chains/0",
      (manifest) => {
        manifest.protocolDefault = {
          status: "default-on-some-chains",
          chains: [unsafe],
          evidence: "https://example.com/default",
        };
      },
    ],
  ];
  for (const [label, path, mutate] of cases) {
    const manifest = proxy();
    mutate(manifest);
    assertSchemaInvalid(manifest, [path]);
    assert.ok(Number.isInteger(unsafe), `${label} test uses a parsed integer`);
  }
});

test("CLI rejects raw JSON literals above the JavaScript safe range without precision loss", () => {
  const raw = readFileSync(
    new URL("../fixtures/invalid/unsafe-numeric-literal.json", import.meta.url),
    "utf8",
  );
  const parsed = JSON.parse(raw);
  assert.ok(raw.includes("9007199254740993"));
  assert.equal(parsed.deployments[0].chainId, Number.MAX_SAFE_INTEGER + 1);

  const result = spawnSync(
    process.execPath,
    [
      "tools/hook-manifest/validate.mjs",
      "tools/hook-manifest/fixtures/invalid/unsafe-numeric-literal.json",
    ],
    { cwd: process.cwd(), encoding: "utf8" },
  );
  assert.equal(result.status, 1, result.stderr);
  for (const path of [
    "$.deployments[0].chainId",
    "$.deployments[0].deployment.blockNumber",
    "$.deployments[0].gas.estimates.checkFund.typical",
    "$.deployments[0].gas.estimates.checkFund.maximum",
    "$.sourceVerification.verifiers[0].chainId",
  ]) {
    assert.ok(
      result.stderr.includes(path),
      `expected ${path} in:\n${result.stderr}`,
    );
  }
});

test("AJV rejects ambiguous singleton proxy metadata for multi-chain manifests", () => {
  const manifest = fixture("invalid/multi-chain-singleton-proxy.json");
  assertSchemaInvalid(manifest, ["/deployments/0", "/deployments/1"]);
  assert.ok(
    validateSchema.errors?.some(
      (error) =>
        error.instancePath === "" &&
        error.keyword === "additionalProperties" &&
        error.params.additionalProperty === "proxy",
    ),
    JSON.stringify(validateSchema.errors, null, 2),
  );
});

test("AJV rejects legacy global gas and unbound dependency locators", () => {
  const manifest = fixture("invalid/legacy-global-runtime-evidence.json");
  assertSchemaInvalid(manifest, [
    "/deployments/0",
    "/deployments/1",
    "/externalDependencies/0",
  ]);
  assert.ok(
    validateSchema.errors?.some(
      (error) =>
        error.instancePath === "" &&
        error.keyword === "additionalProperties" &&
        error.params.additionalProperty === "gas",
    ),
    JSON.stringify(validateSchema.errors, null, 2),
  );
});

test("AJV requires portable slash-separated repository-relative source paths", () => {
  for (const path of [
    "",
    "/src/Hook.sol",
    "src/Hook.sol/",
    "src//Hook.sol",
    "./src/Hook.sol",
    "src/./Hook.sol",
    "../Hook.sol",
    "src/../Hook.sol",
    "C:/repo/Hook.sol",
    "C:\\repo\\Hook.sol",
    "\\\\server\\share\\Hook.sol",
    "//server/share/Hook.sol",
    "src\\Hook.sol",
    "src/\nHook.sol",
    "src/\u0001Hook.sol",
    "src/\u007fHook.sol",
  ]) {
    const manifest = immutable();
    manifest.source.path = path;
    assertSchemaInvalid(manifest, ["/source/path"]);
  }

  for (const path of ["src/Hook.sol", ".github/hooks/Hook Example.sol"]) {
    const manifest = immutable();
    manifest.source.path = path;
    assert.equal(
      validateSchema(manifest),
      true,
      `${path}: ${JSON.stringify(validateSchema.errors)}`,
    );
  }
});

test("AJV rejects every placeholder evidence branch in a published manifest", () => {
  assertSchemaInvalid(placeholderProxy(), [
    "/source/commit",
    "/deployments/0/hook",
    "/deployments/0/taskmarketDiamond",
    "/deployments/0/deployment/transactionHash",
    "/deployments/0/deployment/blockNumber",
    "/deployments/0/runtimeCodehash",
    "/deployments/0/creationCodehash",
    "/deployments/0/proxy/implementation",
    "/deployments/0/proxy/admin",
    "/deployments/0/proxy/timelock",
    "/privilegedRoles/0/holders/0/address",
    "/externalDependencies/0/deployments/0/addresses/0",
    "/deployments/0/gas/estimates/checkFund/typical",
    "/deployments/0/gas/estimates/checkFund/maximum",
  ]);
});

test("AJV conditionally permits portal placeholders only with explicit non-publishable draft status", () => {
  const draft = placeholderProxy();
  draft["x-draft"] = {
    warning: "This file is a draft and must not be published.",
    missing: ["deployment evidence"],
  };
  assert.equal(
    validateSchema(draft),
    true,
    JSON.stringify(validateSchema.errors, null, 2),
  );
  assert.ok(
    schema.properties["x-draft"].description.includes("never publishable"),
  );

  draft["x-draft"] = false;
  assertSchemaInvalid(draft, ["/source/commit", "/deployments/0/hook"]);
});

test("AJV permits missing affirmative evidence only while the manifest is an explicit draft", () => {
  const draft = portalReady();
  draft.sourceVerification = { status: "verified", verifiers: [] };
  draft.listing = { status: "submitted" };
  draft.conformance = { status: "tested", standard: "ITMPHook / ERC-8195" };
  draft.security.audits[0] = {
    status: "audited",
    scope: "Hook implementation",
  };
  draft.protocolDefault = { status: "candidate" };
  draft["x-draft"] = {
    warning: "This file is a draft and must not be published.",
    missing: ["trust evidence"],
  };
  assert.equal(
    validateSchema(draft),
    true,
    JSON.stringify(validateSchema.errors, null, 2),
  );

  delete draft["x-draft"];
  assertSchemaInvalid(draft, [
    "/sourceVerification/verifiers",
    "/listing",
    "/conformance",
    "/security/audits/0",
    "/protocolDefault",
  ]);
});

test("AJV requires evidence URLs for affirmative trust and default claims", () => {
  for (const status of ["submitted", "listed"]) {
    const manifest = portalReady();
    manifest.listing = { status };
    assertSchemaInvalid(manifest, ["/listing"]);
  }
  for (const status of ["tested", "independently-verified"]) {
    const manifest = portalReady();
    manifest.conformance = { status, standard: "ITMPHook / ERC-8195" };
    assertSchemaInvalid(manifest, ["/conformance"]);
  }

  const audited = portalReady();
  audited.security.audits[0] = {
    status: "audited",
    scope: "Hook implementation",
  };
  assertSchemaInvalid(audited, ["/security/audits/0"]);

  const candidate = portalReady();
  candidate.protocolDefault = { status: "candidate" };
  assertSchemaInvalid(candidate, ["/protocolDefault"]);
});

test("AJV rejects HTTP and executable schemes for externally rendered URLs", () => {
  const manifest = proxy();
  manifest.author.url = "http://example.com/author";
  manifest.source.repository = "javascript:alert(1)";
  manifest.sourceVerification.verifiers[0].url = "data:text/html,unsafe";
  manifest.externalDependencies[0].deployments[0].url =
    "http://example.com/oracle";
  manifest.security.audits[0] = {
    status: "audited",
    scope: "Hook implementation",
    report: "javascript:alert(1)",
  };
  manifest.listing.listingUrl = "data:text/html,unsafe";
  manifest.conformance.evidence = "http://example.com/tests";
  manifest.protocolDefault.evidence = "javascript:alert(1)";
  assertSchemaInvalid(manifest, [
    "/author/url",
    "/source/repository",
    "/sourceVerification/verifiers/0/url",
    "/externalDependencies/0/deployments/0/url",
    "/security/audits/0/report",
    "/listing/listingUrl",
    "/conformance/evidence",
    "/protocolDefault/evidence",
  ]);
});

test("AJV standard formats reject malformed HTTPS URIs and short-form emails", () => {
  const manifest = proxy();
  manifest.author.url = "https://example.com/%";
  manifest.author.contact = "a@b";
  assertSchemaInvalid(manifest, ["/author/url", "/author/contact"]);
});

test("AJV requires a nonempty HTTPS authority", () => {
  for (const url of [
    "https:example.com",
    "https:/example.com",
    "https:///example.com",
  ]) {
    const manifest = proxy();
    manifest.author.url = url;
    assertSchemaInvalid(manifest, ["/author/url"]);
  }

  for (const url of [
    "https://example.com",
    "https://EXAMPLE.com:443/source?view=code#L1",
  ]) {
    const manifest = proxy();
    manifest.author.url = url;
    assert.equal(
      validateSchema(manifest),
      true,
      `${url}: ${JSON.stringify(validateSchema.errors, null, 2)}`,
    );
  }
});

test("AJV requires kind-specific proxy locators and concrete upgrade authority", () => {
  const roleLinked = proxy();
  delete roleLinked.deployments[0].proxy.admin;
  delete roleLinked.deployments[0].proxy.timelock;
  roleLinked.deployments[0].proxy.upgradeAuthorityRole =
    "UPGRADE_AUTHORITY_ROLE";
  assert.equal(
    validateSchema(roleLinked),
    true,
    JSON.stringify(validateSchema.errors, null, 2),
  );

  const proseOnly = proxy();
  delete proseOnly.deployments[0].proxy.admin;
  delete proseOnly.deployments[0].proxy.timelock;
  delete proseOnly.deployments[0].proxy.upgradeAuthorityRole;
  assertSchemaInvalid(proseOnly, ["/deployments/0/proxy"]);

  const transparent = proxy();
  transparent.deployments[0].proxy.kind = "transparent";
  delete transparent.deployments[0].proxy.admin;
  assertSchemaInvalid(transparent, ["/deployments/0/proxy"]);

  const beacon = proxy();
  beacon.deployments[0].proxy.kind = "beacon";
  delete beacon.deployments[0].proxy.beacon;
  assertSchemaInvalid(beacon, ["/deployments/0/proxy"]);

  beacon.deployments[0].proxy.beacon =
    "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  assert.equal(
    validateSchema(beacon),
    true,
    JSON.stringify(validateSchema.errors, null, 2),
  );

  beacon.deployments[0].proxy.beacon = `0x${"0".repeat(40)}`;
  assertSchemaInvalid(beacon, ["/deployments/0/proxy/beacon"]);

  const strayBeacon = proxy();
  strayBeacon.deployments[0].proxy.beacon =
    "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  assertSchemaInvalid(strayBeacon, ["/deployments/0/proxy/beacon"]);
});

test("AJV accepts distinct proxy and gas metadata plus chain-bound dependencies", () => {
  const manifest = multiChain();
  assert.equal(
    validateSchema(manifest),
    true,
    JSON.stringify(validateSchema.errors, null, 2),
  );
  assert.notDeepEqual(
    manifest.deployments[0].proxy,
    manifest.deployments[1].proxy,
  );
  assert.notDeepEqual(manifest.deployments[0].gas, manifest.deployments[1].gas);
  assert.notDeepEqual(
    manifest.externalDependencies[0].deployments[0],
    manifest.externalDependencies[0].deployments[1],
  );
});

test("AJV enforces exact callback gas coverage on every deployment", () => {
  const missing = multiChain();
  delete missing.deployments[1].gas.estimates.checkFund;
  assertSchemaInvalid(missing, ["/deployments/1/gas/estimates"]);

  const extra = multiChain();
  extra.deployments[1].gas.estimates.onExpire = {
    typical: 1,
    maximum: 2,
    methodology: "fixture",
  };
  assertSchemaInvalid(extra, ["/deployments/1/gas/estimates/onExpire"]);
});

test("AJV requires kind-aware non-vacuous external dependency evidence", () => {
  const dependency = (kind) => ({
    name: `${kind} dependency`,
    kind,
    purpose: "Required by hook execution.",
  });
  const binding = (fields = {}) => ({ chainId: 8453, ...fields });

  for (const kind of ["contract", "token", "oracle", "relayer"]) {
    const missing = immutable();
    missing.externalDependencies = [dependency(kind)];
    assertSchemaInvalid(missing, ["/externalDependencies/0"]);

    const empty = immutable();
    empty.externalDependencies = [
      {
        ...dependency(kind),
        deployments: [binding({ addresses: [] })],
      },
    ];
    assertSchemaInvalid(empty, [
      "/externalDependencies/0/deployments/0/addresses",
    ]);
  }

  const api = immutable();
  api.externalDependencies = [
    {
      ...dependency("api"),
      deployments: [binding({ url: "https://api.example.com/v1" })],
    },
  ];
  assert.equal(
    validateSchema(api),
    true,
    JSON.stringify(validateSchema.errors, null, 2),
  );

  api.externalDependencies[0].deployments[0].addresses = [
    "0x3333333333333333333333333333333333333333",
  ];
  assertSchemaInvalid(api, ["/externalDependencies/0/deployments/0/addresses"]);

  const apiWithoutUrl = immutable();
  apiWithoutUrl.externalDependencies = [
    {
      ...dependency("api"),
      deployments: [
        binding({
          addresses: ["0x3333333333333333333333333333333333333333"],
        }),
      ],
    },
  ];
  assertSchemaInvalid(apiWithoutUrl, ["/externalDependencies/0/deployments/0"]);

  for (const kind of ["other"]) {
    const byAddress = immutable();
    byAddress.externalDependencies = [
      {
        ...dependency(kind),
        deployments: [
          binding({
            addresses: ["0x3333333333333333333333333333333333333333"],
          }),
        ],
      },
    ];
    assert.equal(
      validateSchema(byAddress),
      true,
      JSON.stringify(validateSchema.errors, null, 2),
    );

    const byUrl = immutable();
    byUrl.externalDependencies = [
      {
        ...dependency(kind),
        deployments: [binding({ url: "https://dependency.example.com" })],
      },
    ];
    assert.equal(
      validateSchema(byUrl),
      true,
      JSON.stringify(validateSchema.errors, null, 2),
    );

    byUrl.externalDependencies[0].deployments[0].addresses = [];
    assertSchemaInvalid(byUrl, [
      "/externalDependencies/0/deployments/0/addresses",
    ]);

    const missing = immutable();
    missing.externalDependencies = [dependency(kind)];
    assertSchemaInvalid(missing, ["/externalDependencies/0"]);

    const empty = immutable();
    empty.externalDependencies = [
      {
        ...dependency(kind),
        deployments: [binding({ addresses: [] })],
      },
    ];
    assertSchemaInvalid(empty, [
      "/externalDependencies/0/deployments/0/addresses",
    ]);

    const zero = immutable();
    zero.externalDependencies = [
      {
        ...dependency(kind),
        deployments: [binding({ addresses: [`0x${"0".repeat(40)}`] })],
      },
    ];
    assertSchemaInvalid(zero, [
      "/externalDependencies/0/deployments/0/addresses/0",
    ]);
  }
});

test("SemVer prerelease numeric identifiers reject leading zeroes", () => {
  for (const version of [
    "1.0.0-0",
    "1.0.0-alpha.0",
    "1.0.0-0A.01a",
    "1.0.0+001",
  ]) {
    const manifest = portalReady();
    manifest.identity.version = version;
    assert.equal(
      validateSchema(manifest),
      true,
      `${version}: ${JSON.stringify(validateSchema.errors)}`,
    );
  }
  for (const version of ["1.0.0-01", "1.0.0-alpha.01", "1.0.0-00"]) {
    const manifest = portalReady();
    manifest.identity.version = version;
    assertSchemaInvalid(manifest, ["/identity/version"]);
  }
});
