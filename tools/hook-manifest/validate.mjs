#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL, URL } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const schema = JSON.parse(
  readFileSync(
    new URL("../../schemas/taskmarket-hook.schema.json", import.meta.url),
    "utf8",
  ),
);
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validateSchema = ajv.compile(schema);
const maxSafeIntegerSource = String(Number.MAX_SAFE_INTEGER);
const jsonNumberSourcePattern =
  /^-?(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?)([0-9]+))?$/;

function displayPath(instancePath) {
  return instancePath
    .split("/")
    .slice(1)
    .reduce((path, encodedSegment) => {
      const segment = encodedSegment
        .replaceAll("~1", "/")
        .replaceAll("~0", "~");
      if (/^(0|[1-9][0-9]*)$/.test(segment)) return `${path}[${segment}]`;
      if (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(segment))
        return `${path}.${segment}`;
      return `${path}[${JSON.stringify(segment)}]`;
    }, "$");
}

function formatSchemaError(error) {
  let path = displayPath(error.instancePath);
  if (error.keyword === "required") path += `.${error.params.missingProperty}`;
  if (error.keyword === "additionalProperties")
    path += `.${error.params.additionalProperty}`;
  return `${path}: ${error.message}`;
}

function appendPropertyPath(path, key, holder) {
  if (Array.isArray(holder) && /^(0|[1-9][0-9]*)$/.test(key))
    return `${path}[${key}]`;
  if (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key)) return `${path}.${key}`;
  return `${path}[${JSON.stringify(key)}]`;
}

function boundedExponent(sign, digits, limit) {
  if (!digits) return 0;
  let magnitude = 0;
  for (const character of digits) {
    const digit = character.charCodeAt(0) - 48;
    if (magnitude > Math.floor((limit - digit) / 10)) {
      magnitude = limit;
      break;
    }
    magnitude = magnitude * 10 + digit;
  }
  return sign === "-" ? -magnitude : magnitude;
}

function rawIntegerIssue(source) {
  const match = jsonNumberSourcePattern.exec(source);
  if (!match) return "is not a valid JSON number";

  const [, integerDigits, fractionDigits = "", exponentSign, exponentDigits] =
    match;
  const coefficient = `${integerDigits}${fractionDigits}`.replace(/^0+/, "");
  if (coefficient.length === 0) return null;

  // The exponent only matters relative to the token's coefficient and the
  // 16-digit safe-integer boundary. Saturating here avoids BigInt conversion
  // or exponentiation for adversarial exponents with millions of digits.
  const exponentLimit = source.length + maxSafeIntegerSource.length + 1;
  const exponent = boundedExponent(exponentSign, exponentDigits, exponentLimit);
  const decimalShift = exponent - fractionDigits.length;

  let integerDigitsSource;
  if (decimalShift < 0) {
    const requiredTrailingZeros = -decimalShift;
    let availableTrailingZeros = 0;
    for (
      let index = coefficient.length - 1;
      index >= 0 && coefficient[index] === "0";
      index -= 1
    ) {
      availableTrailingZeros += 1;
    }
    if (requiredTrailingZeros > availableTrailingZeros)
      return "has a fractional mathematical value";

    const integerLength = coefficient.length - requiredTrailingZeros;
    if (integerLength > maxSafeIntegerSource.length)
      return "is outside the JavaScript safe-integer range";
    integerDigitsSource = coefficient.slice(0, integerLength);
  } else {
    const integerLength = coefficient.length + decimalShift;
    if (integerLength > maxSafeIntegerSource.length)
      return "is outside the JavaScript safe-integer range";
    integerDigitsSource = `${coefficient}${"0".repeat(decimalShift)}`;
  }

  if (
    integerDigitsSource.length === maxSafeIntegerSource.length &&
    integerDigitsSource > maxSafeIntegerSource
  ) {
    return "is outside the JavaScript safe-integer range";
  }
  return null;
}

function summarizedSource(source) {
  if (source.length <= 80) return JSON.stringify(source);
  return JSON.stringify(
    `${source.slice(0, 40)}…(${source.length} characters)…${source.slice(-20)}`,
  );
}

function formatRawIntegerError(path, issue) {
  return `${path}: raw numeric literal ${summarizedSource(issue.source)} ${issue.reason}; manifest numbers must be exact JavaScript safe integers`;
}

/**
 * JSON paths whose numeric values are constrained by the manifest's safe
 * integer schema definitions. `*` matches one object property or array
 * index. Keep this list in lock-step with every safePositiveInteger and
 * safeNonnegativeInteger reference in the schema; the validator tests do a
 * completeness audit against the canonical schema.
 */
export const rawSafeIntegerPathPatterns = Object.freeze([
  Object.freeze(["deployments", "*", "chainId"]),
  Object.freeze(["deployments", "*", "deployment", "blockNumber"]),
  Object.freeze(["deployments", "*", "gas", "estimates", "*", "typical"]),
  Object.freeze(["deployments", "*", "gas", "estimates", "*", "maximum"]),
  Object.freeze(["sourceVerification", "verifiers", "*", "chainId"]),
  Object.freeze(["privilegedRoles", "*", "holders", "*", "chainId"]),
  Object.freeze(["externalDependencies", "*", "deployments", "*", "chainId"]),
  Object.freeze(["protocolDefault", "chains", "*"]),
]);

function isRawSafeIntegerPath(pathSegments) {
  return rawSafeIntegerPathPatterns.some(
    (pattern) =>
      pattern.length === pathSegments.length &&
      pattern.every(
        (segment, index) => segment === "*" || segment === pathSegments[index],
      ),
  );
}

function collectRawIntegerErrors(manifest, issuesByHolder) {
  const errors = [];

  const visit = (value, path, pathSegments) => {
    if (value === null || typeof value !== "object") return;
    const holderIssues = issuesByHolder.get(value);
    if (holderIssues) {
      for (const [key, issue] of holderIssues) {
        const childPathSegments = [...pathSegments, key];
        if (isRawSafeIntegerPath(childPathSegments)) {
          errors.push(
            formatRawIntegerError(appendPropertyPath(path, key, value), issue),
          );
        }
      }
    }
    for (const [key, child] of Object.entries(value)) {
      visit(child, appendPropertyPath(path, key, value), [
        ...pathSegments,
        key,
      ]);
    }
  };
  visit(manifest, "$", []);
  return errors;
}

function normalizedEffectiveHttpsUrl(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || !url.hostname) return null;
    return url.href;
  } catch {
    return null;
  }
}

function isSafePositiveInteger(value) {
  return Number.isSafeInteger(value) && value >= 1;
}

function isSafeNonnegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function checkSemanticConsistency(manifest, errors) {
  if (
    manifest === null ||
    typeof manifest !== "object" ||
    Array.isArray(manifest)
  )
    return;
  const deployments = Array.isArray(manifest.deployments)
    ? manifest.deployments
    : [];
  const declaredChains = new Set();
  const firstDeploymentByChain = new Map();
  deployments.forEach((deployment, deploymentIndex) => {
    const chainId = deployment?.chainId;
    if (!isSafePositiveInteger(chainId)) return;
    declaredChains.add(chainId);
    if (firstDeploymentByChain.has(chainId)) {
      errors.push(
        `$.deployments[${deploymentIndex}].chainId: duplicates deployment chainId from deployment ${firstDeploymentByChain.get(chainId)}`,
      );
    } else {
      firstDeploymentByChain.set(chainId, deploymentIndex);
    }
  });

  const callbacks = Array.isArray(manifest.callbacks) ? manifest.callbacks : [];
  deployments.forEach((deployment, deploymentIndex) => {
    const estimates = deployment?.gas?.estimates;
    if (!estimates || typeof estimates !== "object" || Array.isArray(estimates))
      return;
    callbacks.forEach((callback) => {
      if (!Object.hasOwn(estimates, callback)) {
        errors.push(
          `$.deployments[${deploymentIndex}].gas.estimates.${callback}: missing estimate for declared callback`,
        );
      }
    });
    Object.keys(estimates).forEach((callback) => {
      if (!callbacks.includes(callback)) {
        errors.push(
          `$.deployments[${deploymentIndex}].gas.estimates.${callback}: estimate is not for a declared callback`,
        );
      }
      const estimate = estimates[callback];
      if (
        estimate &&
        isSafeNonnegativeInteger(estimate.typical) &&
        isSafeNonnegativeInteger(estimate.maximum) &&
        estimate.maximum < estimate.typical
      ) {
        errors.push(
          `$.deployments[${deploymentIndex}].gas.estimates.${callback}.maximum: must be greater than or equal to typical`,
        );
      }
    });
  });

  const privilegedRoles = Array.isArray(manifest.privilegedRoles)
    ? manifest.privilegedRoles
    : [];
  const roleNameIndexes = new Map();
  const holderAddressesByChain = new Set();
  privilegedRoles.forEach((role, roleIndex) => {
    const roleName = role?.name;
    if (typeof roleName === "string") {
      if (roleNameIndexes.has(roleName)) {
        errors.push(
          `$.privilegedRoles[${roleIndex}].name: duplicates role name from privileged role ${roleNameIndexes.get(roleName)}`,
        );
      } else {
        roleNameIndexes.set(roleName, roleIndex);
      }
    }

    const holders = Array.isArray(role?.holders) ? role.holders : [];
    const holderIndexes = new Map();
    holders.forEach((holder, holderIndex) => {
      const chainId = holder?.chainId;
      const address = holder?.address;
      if (isSafePositiveInteger(chainId) && !declaredChains.has(chainId)) {
        errors.push(
          `$.privilegedRoles[${roleIndex}].holders[${holderIndex}].chainId: must reference a declared deployment`,
        );
      }
      if (isSafePositiveInteger(chainId) && typeof address === "string") {
        const key = JSON.stringify([chainId, address.toLowerCase()]);
        if (holderIndexes.has(key)) {
          errors.push(
            `$.privilegedRoles[${roleIndex}].holders[${holderIndex}].address: duplicates normalized chainId and address from holder ${holderIndexes.get(key)}`,
          );
        } else {
          holderIndexes.set(key, holderIndex);
        }
        holderAddressesByChain.add(key);
      }
    });
  });

  deployments.forEach((deployment, deploymentIndex) => {
    const proxy = deployment?.proxy;
    if (proxy?.upgradeable !== true) return;
    for (const field of ["admin", "timelock"]) {
      const address = proxy[field];
      if (
        typeof address === "string" &&
        isSafePositiveInteger(deployment?.chainId) &&
        !holderAddressesByChain.has(
          JSON.stringify([deployment.chainId, address.toLowerCase()]),
        )
      ) {
        errors.push(
          `$.deployments[${deploymentIndex}].proxy.${field}: must appear in privilegedRoles holders for deployment chain ${deployment.chainId}`,
        );
      }
    }

    const upgradeAuthorityRole = proxy.upgradeAuthorityRole;
    if (typeof upgradeAuthorityRole === "string") {
      const matches = privilegedRoles.filter(
        (role) => role?.name === upgradeAuthorityRole,
      );
      if (
        matches.length !== 1 ||
        !Array.isArray(matches[0]?.holders) ||
        !matches[0].holders.some(
          (holder) => holder?.chainId === deployment?.chainId,
        )
      ) {
        errors.push(
          `$.deployments[${deploymentIndex}].proxy.upgradeAuthorityRole: must reference exactly one privilegedRoles entry with holders for deployment chain ${deployment?.chainId}`,
        );
      }
    }
  });

  const externalDependencies = Array.isArray(manifest.externalDependencies)
    ? manifest.externalDependencies
    : [];
  const dependencyNameIndexes = new Map();
  externalDependencies.forEach((dependency, dependencyIndex) => {
    const dependencyName = dependency?.name;
    if (typeof dependencyName === "string") {
      if (dependencyNameIndexes.has(dependencyName)) {
        errors.push(
          `$.externalDependencies[${dependencyIndex}].name: duplicates dependency name from external dependency ${dependencyNameIndexes.get(dependencyName)}`,
        );
      } else {
        dependencyNameIndexes.set(dependencyName, dependencyIndex);
      }
    }

    const bindings = Array.isArray(dependency?.deployments)
      ? dependency.deployments
      : [];
    const bindingIndexes = new Map();
    bindings.forEach((binding, bindingIndex) => {
      const chainId = binding?.chainId;
      if (isSafePositiveInteger(chainId)) {
        if (!declaredChains.has(chainId)) {
          errors.push(
            `$.externalDependencies[${dependencyIndex}].deployments[${bindingIndex}].chainId: must reference a declared deployment`,
          );
        }
        if (bindingIndexes.has(chainId)) {
          errors.push(
            `$.externalDependencies[${dependencyIndex}].deployments[${bindingIndex}].chainId: duplicates chainId from deployment binding ${bindingIndexes.get(chainId)}`,
          );
        } else {
          bindingIndexes.set(chainId, bindingIndex);
        }
      }

      const addresses = Array.isArray(binding?.addresses)
        ? binding.addresses
        : [];
      const addressIndexes = new Map();
      addresses.forEach((address, addressIndex) => {
        if (typeof address !== "string") return;
        const normalizedAddress = address.toLowerCase();
        if (addressIndexes.has(normalizedAddress)) {
          errors.push(
            `$.externalDependencies[${dependencyIndex}].deployments[${bindingIndex}].addresses[${addressIndex}]: duplicates normalized address from address ${addressIndexes.get(normalizedAddress)}`,
          );
        } else {
          addressIndexes.set(normalizedAddress, addressIndex);
        }
      });
    });
  });

  const verifiers = manifest.sourceVerification?.verifiers;
  if (Array.isArray(verifiers)) {
    const evidenceKeys = new Map();
    verifiers.forEach((verifier, index) => {
      if (
        verifier &&
        isSafePositiveInteger(verifier.chainId) &&
        !declaredChains.has(verifier.chainId)
      ) {
        errors.push(
          `$.sourceVerification.verifiers[${index}].chainId: must reference a declared deployment`,
        );
      }
      if (
        verifier &&
        isSafePositiveInteger(verifier.chainId) &&
        typeof verifier.url === "string"
      ) {
        const normalizedUrl = normalizedEffectiveHttpsUrl(verifier.url);
        if (normalizedUrl !== null) {
          const key = JSON.stringify([verifier.chainId, normalizedUrl]);
          if (evidenceKeys.has(key)) {
            errors.push(
              `$.sourceVerification.verifiers[${index}].url: duplicates chainId and normalized URL from verifier ${evidenceKeys.get(key)}`,
            );
          } else {
            evidenceKeys.set(key, index);
          }
        }
      }
    });

    if (
      !isDraft(manifest) &&
      manifest.sourceVerification?.status === "verified"
    ) {
      const verifiedChains = new Set(
        verifiers
          .filter(
            (verifier) =>
              isSafePositiveInteger(verifier?.chainId) &&
              verifier?.status === "verified",
          )
          .map((verifier) => verifier.chainId),
      );
      deployments.forEach((deployment, deploymentIndex) => {
        if (
          isSafePositiveInteger(deployment?.chainId) &&
          !verifiedChains.has(deployment.chainId)
        ) {
          errors.push(
            `$.sourceVerification.verifiers: must include verified evidence for $.deployments[${deploymentIndex}].chainId (${deployment.chainId})`,
          );
        }
      });
    }
  }

  const protocolDefault = manifest.protocolDefault;
  if (protocolDefault && Array.isArray(protocolDefault.chains)) {
    protocolDefault.chains.forEach((chainId, index) => {
      if (isSafePositiveInteger(chainId) && !declaredChains.has(chainId)) {
        errors.push(
          `$.protocolDefault.chains[${index}]: must reference a declared deployment`,
        );
      }
    });
    const uniqueChains = new Set(protocolDefault.chains);
    if (
      protocolDefault.status === "default-on-all-declared-chains" &&
      (uniqueChains.size !== declaredChains.size ||
        [...declaredChains].some((chainId) => !uniqueChains.has(chainId)))
    ) {
      errors.push(
        "$.protocolDefault.chains: must contain every declared deployment chain",
      );
    }
    if (
      protocolDefault.status === "default-on-some-chains" &&
      uniqueChains.size >= declaredChains.size
    ) {
      errors.push(
        "$.protocolDefault.chains: must be a strict subset of declared deployment chains",
      );
    }
  }
}

function isDraft(manifest) {
  return (
    Object.hasOwn(manifest, "x-draft") &&
    manifest["x-draft"] !== false &&
    manifest["x-draft"] !== null
  );
}

export function inspect(manifest) {
  validateSchema(manifest);
  const errors = (validateSchema.errors ?? []).map(formatSchemaError);
  checkSemanticConsistency(manifest, errors);
  if (
    manifest !== null &&
    typeof manifest === "object" &&
    !Array.isArray(manifest)
  ) {
    if (isDraft(manifest)) {
      errors.push("$.x-draft: draft manifests are not publishable");
    }
  }
  const uniqueErrors = [...new Set(errors)];
  return { errors: uniqueErrors, publishable: uniqueErrors.length === 0 };
}

export function validate(manifest) {
  return inspect(manifest).errors;
}

/**
 * Parse and inspect raw manifest JSON without allowing JSON.parse to hide a
 * fractional or unsafe integer through IEEE-754 rounding. Callers ingesting
 * files or request bodies should use this entry point instead of pre-parsing.
 */
export function inspectJson(source) {
  if (typeof source !== "string") {
    return {
      manifest: undefined,
      errors: ["$: raw JSON source must be a string"],
      publishable: false,
    };
  }

  const issuesByHolder = new WeakMap();
  let manifest;
  try {
    manifest = JSON.parse(
      source,
      function inspectRawNumber(key, value, context) {
        if (typeof value !== "number") return value;
        const numberSource = context?.source;
        if (typeof numberSource !== "string") {
          throw new Error(
            "the current Node.js runtime does not expose JSON number source text",
          );
        }
        const reason = rawIntegerIssue(numberSource);
        if (reason === null) return value;

        const issue = { source: numberSource, reason };
        let holderIssues = issuesByHolder.get(this);
        if (!holderIssues) {
          holderIssues = new Map();
          issuesByHolder.set(this, holderIssues);
        }
        holderIssues.set(key, issue);
        return value;
      },
    );
  } catch (error) {
    return {
      manifest: undefined,
      errors: [`$: invalid JSON: ${error.message}`],
      publishable: false,
    };
  }

  const rawErrors = collectRawIntegerErrors(manifest, issuesByHolder);
  const inspected = inspect(manifest);
  const errors = [...new Set([...rawErrors, ...inspected.errors])];
  return { manifest, errors, publishable: errors.length === 0 };
}

export function validateJson(source) {
  return inspectJson(source).errors;
}

const invokedAsScript =
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invokedAsScript) {
  const file = process.argv[2] === "--" ? process.argv[3] : process.argv[2];
  if (!file) {
    console.error(
      "Usage: node tools/hook-manifest/validate.mjs <taskmarket-hook.json>",
    );
    process.exitCode = 2;
  } else {
    try {
      const errors = validateJson(readFileSync(file, "utf8"));
      if (errors.length) {
        console.error(
          `Invalid ${file}:\n${errors.map((error) => `- ${error}`).join("\n")}`,
        );
        process.exitCode = 1;
      } else {
        console.log(`Valid ${file}`);
      }
    } catch (error) {
      console.error(`Invalid ${file}: ${error.message}`);
      process.exitCode = 1;
    }
  }
}
