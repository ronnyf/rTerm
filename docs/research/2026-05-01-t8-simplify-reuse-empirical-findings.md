# T8 Simplify/Reuse — Empirical Findings

Date: 2026-05-01
Commit: 78b5f43 ("input: bracketed paste (Phase 2 T8)")
Reviewer: Claude Sonnet 4.6

---

## Q1: Does `bracketedPasteWrap` reuse any existing escape-sequence builder?

No. There is no shared escape-sequence builder in the codebase. The two candidates are:

**`KeyEncoder.cursorKey(_:mode:)`** (`rTerm/KeyEncoder.swift:42–51`)  
A private method that assembles 3-byte `ESC + intro + final` sequences:
```swift
let intro: UInt8 = (mode == .application) ? 0x4F : 0x5B
return Data([0x1B, intro, final])
```
It is private, 3 bytes only, and models a structurally different shape (CSI/SS3
single-byte final, no numeric parameters). It cannot represent 6-byte `~`-terminated
sequences like ESC[200~ or the PgUp/PgDn/Del cases.

**The static `Data([0x1B, 0x5B, …])` literals in `KeyEncoder.encode`** (lines 78–86)
These are inline 3–4-byte literals for Home/End/PgUp/PgDn/ForwardDelete. They share
the same byte-literal construction style as T8's envelope constants, but they are
dispersed one-liners with no shared helper.

**T8's envelope construction** (`rTerm/ContentView.swift:487–489`):
```swift
data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC [ 2 0 0 ~
data.append(payload)
data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])  // ESC [ 2 0 1 ~
```
Uses `append(contentsOf:)` rather than `Data([…])` because it is building up a
larger buffer rather than returning a fresh value.

---

## Q2: Could a shared `escapeSeq(prefix:body:suffix:)` helper unify these?

Evaluated. The answer is: not meaningfully, and the attempt would be net-negative.

### Shape mismatch

The sequences in the codebase fall into two structurally distinct groups:

| Site | Shape | Bytes | Construction |
|------|-------|-------|--------------|
| `KeyEncoder.cursorKey` | ESC + 1 intro + 1 final | 3 | `Data([0x1B, intro, final])` |
| `KeyEncoder.encode` Home/End/PgUp/PgDn/Del | ESC [ + 1–2 params + `~` or letter | 3–4 | inline `Data([…])` |
| `bracketedPasteWrap` prefix/suffix | ESC [ + 3 decimal digits + `~` | 6 | `append(contentsOf:)` |

A helper with signature `escapeSeq(prefix: Data, body: Data, suffix: Data) -> Data`
would not reduce the byte-literal verbosity — callers would still need to specify
`Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])` as the prefix, which is the thing being
"simplified". The constant bytes are the payload, not the structure.

### The `Data([0x1B, 0x5B, ...])` block duplication question

The bracketed-paste prefix `[0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]` and suffix
`[0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]` appear in two places each: `bracketedPasteWrap`
(production) and `BracketedPasteTests.swift` (tests). This is intentional and correct:
the test constants are the ground truth against which the production constants are
validated. If both were derived from a single named constant, the test would tautologically
pass even if the constant were wrong. The duplication serves the test's correctness
function.

The Page Up/Down/Delete/Home/End sequences in `KeyEncoder` are also each unique
one-liners — no pair repeats anywhere. No consolidation opportunity exists there.

### Named constants as a lighter alternative

If the goal is readability only (not structural sharing), the two envelope constants
could be extracted to `private static let` inside `bracketedPasteWrap`'s owning type
or file:

```swift
// Hypothetical — not in the codebase
private static let bp200: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
private static let bp201: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
```

However:
1. The existing inline comments (`// ESC [ 2 0 0 ~`) already make the bytes self-describing.
2. The constants are used in exactly one production call site each; there is nothing to
   deduplicate yet.
3. Introducing named constants that are only used once and must be kept in sync with
   the test's own inline expectations is more ceremony than it is worth at this scale.

---

## Verdict

**Clean.** No shared escape-sequence builder exists or is warranted. `bracketedPasteWrap`
does not duplicate any existing constant block; it introduces two novel 6-byte sequences
that appear nowhere else in the production code. The inline comments make the byte
values self-documenting. The test duplication of the constants is structurally correct.
No refactoring is recommended.
