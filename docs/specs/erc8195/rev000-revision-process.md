# ERC-8195 Revision Process

A revision document is a durable record of a protocol change and its rationale. It serves the same
purpose as an ADR (Architecture Decision Record): future contributors should be able to read any
revision document and understand not only what changed but why the alternative approaches were
rejected. Revision documents are append-only — once merged they are not edited to reflect
subsequent changes. Later revisions supersede earlier ones by reference.

---

## Required Sections

### Motivation

One or two paragraphs describing the situation before the revision. What was true, what broke or
became unsustainable, and what the revision is expected to achieve. This section must be
understandable without reading the code.

### Problem N — Short Title

One problem-focused section per distinct issue addressed by the revision. Number them sequentially
from 1. Each section should:

- Name the specific function or component that exhibited the problem
- Describe the observable symptom (revert, wrong state transition, fund loss, etc.)
- If the before-state is ambiguous, include a short code snippet showing the broken behavior

A revision may have one problem section or many. Tightly related problems may be combined into a
single numbered section.

### Changes

One subsection per code change, numbered to match the problem sections where applicable. Each
change subsection must include a before/after code block pair showing the exact diff at the
function or expression level. Surrounding context (function signature, surrounding lines) should
be included only when it is necessary to locate the change unambiguously.

### Rationale

One "Why not X?" subsection per meaningful alternative that was considered and rejected. Each
should explain the alternative in one sentence and then explain the specific reason it was
insufficient. This section is written in past tense from the perspective of having already made
the decision.

### API Changes

Describes any changes visible to off-chain callers: function signature changes, new or removed
errors, new events, new or removed backend endpoints, CLI flag changes, schema changes. Use a
prose sentence for each entry or a bullet list; a table is appropriate when there are many
signature changes. This section may be omitted only if the revision makes no API-visible change.

### Affected Files

A Markdown table with two columns: `File` and `Change`. Each row covers one file. Paths are
relative to the repository root. The table should include every file whose behavior or interface
changed, including test files and migration files if the change required them.

---

## Naming Convention

Revision documents are named `rev00N-kebab-slug.md`, where N is the next sequential integer with
leading zeros to three digits. The slug is a short, lowercase, hyphen-separated description of
the primary change.

Examples:

```
rev001-pitches-proofs-auction-accept.md
rev005-diamond-proxy.md
rev006-open-contest-state-machine.md
```

Revisions are numbered in merge order. Do not reuse or skip numbers. When two revisions are
prepared in parallel, the one merged first takes the lower number.

---

## Canonical Reference

`rev006-open-contest-state-machine.md` is the canonical reference example of a well-formed
revision document. When in doubt about level of detail or section structure, consult rev006.
