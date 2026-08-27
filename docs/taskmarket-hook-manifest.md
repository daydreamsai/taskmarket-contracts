# Taskmarket hook manifest

`taskmarket-hook.json` is a portable declaration for an external ERC-8195 /
Taskmarket hook. Validate version 1 manifests against
[`schemas/taskmarket-hook.schema.json`](../schemas/taskmarket-hook.schema.json), served
after release at
`https://taskmarket.dev/schemas/taskmarket-hook/1.0.0/schema.json`, and with:

```sh
pnpm validate:hook-manifest -- path/to/taskmarket-hook.json
```

Run commands from this package root (`packages/contracts` in the official monorepo).
The official monorepo byte-for-byte checks its hosted web asset against this canonical
source so the URL cannot drift from the published schema.

The manifest is deliberately descriptive. Four fields must not be conflated:

- `listing` is a registry/listing status.
- `sourceVerification` records explorer/source-verifier evidence.
- `conformance` records interface/test conformance evidence; it is not an audit.
- `protocolDefault` records whether a diamond selects the hook by default; it is
  independent of every status above.

`security.audits` separately records audit status and scope. In a publishable manifest,
`submitted` and `listed` listings require `listingUrl`; `tested` and
`independently-verified` conformance requires `evidence`; and an `audited` entry
requires its `report` URL. Consumers should verify all claims against the cited sources
and the chain; a valid manifest is not an endorsement.

## Field ownership

Version 1 uses four explicit ownership scopes so multi-chain evidence cannot silently
borrow values from another deployment:

| Scope                                                    | Fields                                                                                                                                |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Source-global hook declaration                           | `identity`, `author`, `source`, `license`, `callbacks`, `taskModes`, `hookData`, `liveness`, `security`, `listing`, and `conformance` |
| Deployment-owned runtime evidence                        | `deployments[].chainId`, network label, hook and diamond addresses, deploy transaction/block, bytecode hashes, `proxy`, and `gas`     |
| Reusable definitions with chain-bound locators           | `privilegedRoles[].holders[]` and `externalDependencies[].deployments[]`                                                              |
| Cross-deployment aggregates with explicit chain evidence | `sourceVerification` and `protocolDefault`                                                                                            |

Source-global fields describe the one logical hook version named by this manifest.
They are not measurements of a particular deployment. Runtime values that can differ
by chain either live directly inside a deployment or carry a declared `chainId`.

Every externally rendered URL is HTTPS-only: author and source links, verifier and
dependency URLs, audit reports, listings, conformance evidence, and protocol-default
evidence. The spelling must start with `https://` and include a nonempty authority;
shortened forms such as `https:example.com`, `https:/example.com`, and the empty-authority
`https:///example.com` form are invalid. Consumers must still escape and safely render
those untrusted destinations.

For publication, `sourceVerification.status: verified` requires verified evidence for
every declared deployment chain and every verifier entry must be verified.
`partially-verified` requires both verified and pending/unverified evidence. Verifier
chain IDs must match declared deployments, and each `(chainId, normalized URL)` pair
must be unique so contradictory duplicate entries cannot satisfy partial verification.
The CLI uses the standard WHATWG URL serialization for this comparison, which includes
lowercasing the host, removing the default HTTPS port, resolving path dot segments, and
adding the implied root slash. Query strings and fragments remain significant.

## Required deployment evidence

Every deployment includes its EIP-155 `chainId`, nonzero hook and Taskmarket diamond
addresses, a nonzero deploy transaction and block, and a nonzero runtime bytecode hash.
Addresses are strict 20-byte `0x` hex values; transactions and codehashes are strict
`bytes32`. The source is pinned by repository URL, a nonzero commit, and source path.
Published gas estimates must be nonzero. A zero address, all-zero hash or commit, zero
deployment block, or zero gas estimate is rejected as incomplete evidence.

All manifest `chainId`, deployment block, and gas estimate values are JavaScript safe
integers: chain IDs are positive and blocks/gas values are nonnegative (or positive when
published). Values above `9007199254740991` are rejected so browser and CLI consumers
cannot silently compare rounded chain or measurement data.

File, request-body, and registry ingestion must validate the raw UTF-8 JSON through the
exported `inspectJson(source)` or `validateJson(source)` entry point. These functions use
the original JSON number token, so a fractional value such as `9007199254740991.1`
cannot be rounded to a publishable safe integer by `JSON.parse`. Exact safe integers in
plain decimal, `.0`, or mathematically integral exponent form are accepted; fractional
or out-of-range mathematical values are rejected. The object-based `inspect(manifest)`
and `validate(manifest)` functions remain useful for in-memory builders, but an already
parsed object cannot reveal precision that an earlier parse discarded. Consumers must
not parse untrusted manifest JSON before calling the raw-source entry point.

Gas evidence is deployment-specific. Every deployment includes
`gas.estimates.<callback>` with `typical`, `maximum`, and `methodology`; there is no
free-form global network label. Each deployment must cover the manifest's `callbacks`
exactly, and measurements may differ across chains.

Proxy metadata is also deployment-specific. Every `deployments[]` entry includes its own
`proxy` object, including immutable deployments as `{ "kind": "none", "upgradeable":
false }`. A manifest can therefore describe different proxy kinds, implementations,
admins, beacons, or timelocks on different chains without implying that one chain's
addresses apply globally. A top-level `proxy` singleton is invalid.

`source.path` is a portable, slash-separated path relative to the repository root. It
must have nonempty segments and no leading or trailing slash, backslash, Windows drive
prefix, `.` or `..` segment, empty segment, C0 control character, or DEL character.

The portal may emit placeholders only with an explicit true/object `x-draft` extension.
Generic Draft 2020-12 validation conditionally accepts that schema-shaped editing output,
but the marker explicitly means it is never publishable and the CLI reports it as such.
Draft affirmative statuses may temporarily omit their evidence URLs. An absent or false
marker activates the schema's non-placeholder and affirmative-evidence publication rules.
Remove `x-draft` only after replacing every placeholder with independently checked
evidence.

## Callbacks and modes

`callbacks` may only declare the Taskmarket interface callbacks: `checkFund`,
`checkClaim`, `checkSelectWorker`, `checkSubmit`, `checkEvaluate`, `checkComplete`,
`onComplete`, `onForfeit`, `onCancel`, and `onExpire`. `taskModes` is the declared
compatibility set: `bounty`, `claim`, `pitch`, `auction`, or `benchmark`.

## hookData is publisher-attested metadata

`hookData.encoding` is either:

- `none`: the exact wire value is `0x`; `schema` must be `{}` and each example has
  `decoded: null`, `encoded: "0x"`.
- `abi`: `abiType` declares the Solidity ABI type expression, `schema` describes its
  decoded values, and each example supplies claimed ABI hex bytes in `encoded`.

The package validator applies the same canonical schema with Ajv 2020 and standard
format validation, then adds only the documented cross-field consistency checks. The
schema is self-contained so the hosted mirror remains portable to other Draft 2020-12
validators. Validation checks this publisher-attested metadata structurally only; it
does not prove that `abiType`, `decoded`, `schema`, and `encoded` are semantically
equivalent. Consumers must independently ABI-decode `encoded` using `abiType` and
validate the decoded result before relying on it. Do not put a JSON serialization in
`encoded`. Add new, incompatible formats through a new `manifestVersion` and schema
URL; vendor additions may use `x-` keys.

## Operations and trust

Every upgradeable `deployments[].proxy` declares its implementation, an authority
description, and at least one concrete authority locator: `admin`, `timelock`, or
`upgradeAuthorityRole`. Transparent proxies require `admin`; beacon proxies additionally
require the `beacon` contract address. Every declared admin or timelock address must
also appear in a `privilegedRoles[].holders[]` object with the same deployment
`chainId`. Each holder is `{ "chainId": ..., "address": "0x..." }`.
`upgradeAuthorityRole`, when used, must exactly and uniquely name a privileged role
with at least one holder on that deployment's chain. Role names and normalized
`(chainId, address)` holder pairs must be unique. This keeps each deployment's prose
explanation tied to concrete chain-local addresses and capabilities.
`kind: none` is reserved for immutable deployments and must omit every proxy-only
authority field. Manifest builders must emit this object inside every deployment;
builders for upgradeable hooks must populate each chain's own locators and role links.

Publishable `externalDependencies` are also kind-aware. `contract`, `token`, `oracle`,
and `relayer` entries require at least one nonzero on-chain address in every declared
dependency binding. Each dependency has
`deployments: [{ "chainId": ..., "addresses": [...], "url": "https://..." }]`;
binding chain IDs must name manifest deployments and may occur only once per dependency.
`api` bindings require an HTTPS URL and forbid addresses. `other` covers mixed or
uncommon dependencies and requires at least one nonzero address or HTTPS URL per
binding. Normalized addresses may not repeat within a binding, while the same address
on two different chains remains two distinct locators. List every external contract or
service and its purpose, plus liveness failure and recovery behavior.

Every deployment's gas estimates must match `callbacks` exactly and include a
methodology. A `candidate` protocol-default claim requires evidence. A
`default-on-some-chains` or
`default-on-all-declared-chains` claim also requires deployment-backed chain IDs; the
latter must list every declared deployment. Keep security assumptions, audits, and known
limitations in `security.notes`.

## Unpublished version 1 migration

The version 1 schema was corrected before publication, so there is no compatibility
branch for the ambiguous draft shape. Builders must make these mechanical migrations:

- Move root `gas.estimates` into every `deployments[].gas.estimates`, emit a complete
  callback map for each deployment, and remove `gas.network`.
- Replace each role holder address string with `{ "chainId": ..., "address": ... }`.
- Replace dependency-level `addresses` or `url` with chain-specific
  `externalDependencies[].deployments[]` bindings.

A root `gas` singleton or dependency locator without a deployment binding is invalid.

The valid fixtures are test data, not real deployments. `portal-ready.json` matches the
portal generator's ready output shape and is validated in the package test suite:

```sh
pnpm validate:hook-manifest -- tools/hook-manifest/fixtures/valid/simple-immutable.json
pnpm validate:hook-manifest -- tools/hook-manifest/fixtures/valid/advanced-proxy.json
pnpm validate:hook-manifest -- tools/hook-manifest/fixtures/valid/multi-chain-proxies.json
pnpm validate:hook-manifest -- tools/hook-manifest/fixtures/valid/portal-ready.json
```
