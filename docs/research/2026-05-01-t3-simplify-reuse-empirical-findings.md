# T3 Simplify/Reuse Empirical Findings

**Date:** 2026-05-01  
**Commit reviewed:** `ed1b63f` — "model: TerminalModes + DECAWM/DECTCEM/DECCKM/bracketed paste + bell (Phase 2 T3)"  
**Reviewer:** code-reuse analysis pass

---

## Q1: Should `TerminalModes` be an `OptionSet` of single bits like `CellAttributes`?

### Method
- `rg "OptionSet" /Users/ronny/rdev/rTerm/ --type swift -n`
- `rg "modes\." /Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift -n`
- Read `TermCore/CellStyle.swift`, `TermCore/TerminalModes.swift`

### Raw findings
- Only one `OptionSet` in the codebase: `CellAttributes` in `CellStyle.swift:26` — a `UInt16` bitfield with 7 static members (bold, dim, italic, underline, blink, reverse, strikethrough).
- `modes.` access sites in `ScreenModel.swift` (14 total): all are named-field accesses (`modes.autoWrap`, `modes.cursorVisible`, etc.) — never tested as a bitmask, never passed to bitwise combinators, never iterated.
- `CellAttributes` use pattern: checked with `contains()`, combined with `insert()`/`remove()`, passed in aggregate to renderer — classic OptionSet usage.
- `TerminalModes` use pattern: each flag is read individually and written individually; no combination testing occurs anywhere.

### Conclusion
**OptionSet is wrong here.** `CellAttributes` is an OptionSet because callers need set-combination semantics (`attrs.contains(.bold)`, `attrs.insert(.italic)`). `TerminalModes` flags are always accessed by name and never combined — the "struct of named bools" is the right model. The doc comment on `TerminalModes` even explains `@frozen` was omitted deliberately to allow adding Phase 3 modes; an OptionSet would require pre-allocating bit positions which contradicts that intent. No change needed.

---

## Q2: Is the 4-arm `handleSetMode` switch a duplication target? Is there a `WritableKeyPath` helper elsewhere?

### Method
- `rg "WritableKeyPath|KeyPath" /Users/ronny/rdev/rTerm/TermCore/ --type swift -n`
- Read `ScreenModel.swift:617-642` (full `handleSetMode` body from `git show ed1b63f`)

### Raw findings
- Zero `WritableKeyPath` or `KeyPath` uses anywhere in `TermCore/`.
- `handleSetMode` switch body (ScreenModel.swift:617-642): 4 arms, each identical pattern `guard modes.X != enabled else { return false }; modes.X = enabled; return true`. Two additional arms return `false` unconditionally (alt-screen, unknown).
- The prior quality-review (2026-05-01-t3-quality-review-empirical-findings.md) already flagged this as **Suggestion, defer** — T4 will add 4 more alt-screen arms to the same switch; collapsing the bool arms to a KeyPath dispatch at T3 while leaving the alt-screen arms as no-ops would create a mixed dispatch style with no actual line-count win until T4.

### Conclusion
No `WritableKeyPath` helper exists and there is no precedent in TermCore. The switch-based approach is internally consistent, the 4-arm repetition is modest (20 lines), and it will grow in T4 with structurally different arms (alt-screen requires buffer-swap logic, not just a bool flip). Abstracting to a keypath helper now would add complexity with no immediate payoff. **Defer until T4 completes** and the full mode surface is visible, then evaluate if a helper earns its weight. Consistent with prior reviewer's Suggestion-defer classification.

---

## Q3: Does the `decodeIfPresent ?? default` pattern duplicate a helper that already exists in TermCore?

### Method
- `rg "decodeIfPresent" /Users/ronny/rdev/rTerm/TermCore/ --type swift -n`
- `rg "CodingKeys" /Users/ronny/rdev/rTerm/TermCore/ --type swift -n`
- `rg "init.from decoder" /Users/ronny/rdev/rTerm/TermCore/ --type swift -n`
- Read `TermCore/Cell.swift:40-59`, `TermCore/ScreenSnapshot.swift:105-132`

### Raw findings
`decodeIfPresent` call sites across all of TermCore:

| File | Line | Pattern |
|------|------|---------|
| `ScreenSnapshot.swift:126` | `windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)` — optional, no default needed |
| `ScreenSnapshot.swift:127` | `cursorKeyApplication = try ...decodeIfPresent(Bool.self, ...) ?? false` |
| `ScreenSnapshot.swift:128` | `bracketedPaste = try ...decodeIfPresent(Bool.self, ...) ?? false` |
| `ScreenSnapshot.swift:129` | `bellCount = try ...decodeIfPresent(UInt64.self, ...) ?? 0` |
| `ScreenSnapshot.swift:130` | `autoWrap = try ...decodeIfPresent(Bool.self, ...) ?? true` |
| `Cell.swift:49` | `style = try container.decodeIfPresent(CellStyle.self, forKey: .style) ?? .default` |

- Two types use the pattern: `Cell` (1 site, bespoke encode/decode for the Character-as-String workaround) and `ScreenSnapshot` (4 new T3 sites + 1 pre-existing `windowTitle`).
- No shared decoder helper exists anywhere; no extension on `KeyedDecodingContainer` with a `decode(_:forKey:default:)` shorthand.

### Conclusion
There are exactly 4 `decodeIfPresent ?? value` sites in `ScreenSnapshot` and 1 in `Cell` (with different motivation — the `Cell` decoder exists primarily for the Character→String encode, the `decodeIfPresent` there is incidental). The 4 sites in `ScreenSnapshot` are already the entire back-compat block; extracting a `KeyedDecodingContainer` helper would move ~4 lines of straightforward code behind a new abstraction that has no other callers. **Clean as-is.** If T4/T5 add more optional fields to `ScreenSnapshot`, revisit at that point (threshold ~3 additional fields would make a helper worthwhile).

---

## Q4: Are the 9 new test functions reusing helpers or hand-rolling boilerplate?

### Method
- `rg "ScreenModel\(" /Users/ronny/rdev/rTerm/TermCoreTests/ScreenModelTests.swift -n | wc -l` → 52 total
- `rg "ScreenModel\(cols: 80, rows: 24\)" ... | wc -l` → 10 occurrences
- `rg "func.*model\|func.*terminal\|func.*fixture\|func.*make" /Users/ronny/rdev/rTerm/TermCoreTests/ --type swift -n -i` → zero results
- Inspected the 9 new `ScreenModelModeTests` functions directly

### Raw findings
- No test helper factory exists anywhere in `TermCoreTests/` — not for `ScreenModel`, not for `TerminalParser`, not for any other type.
- The pre-existing test file (prior to T3) already contained 43 bare `let model = ScreenModel(cols: X, rows: Y)` instantiations across 6 structs, establishing the established convention.
- The 9 new mode tests follow the exact same inline-construction pattern.
- 7 of the 9 new tests use `ScreenModel(cols: 80, rows: 24)` — a standard terminal size appropriate for mode-only tests (modes don't depend on grid geometry). The 2 DECAWM tests use small custom sizes (`cols: 5`, `cols: 3`) which are geometry-specific.
- No test duplicates setup beyond the single-line `let model = ...` plus `await model.apply([...])`.

### Conclusion
**Consistent with established convention.** The inline construction is the project norm across all 6 pre-existing test structs and 43 prior test functions. The 7 `cols: 80, rows: 24` repetitions are a reasonable candidate for a `let standardModel: ScreenModel` computed property or `@Test` attribute if the struct grows large, but at 9 functions it is premature. No boilerplate regression vs prior tests.

---

## Q5: The `BufferKind: String` change — are there other short enums that should also adopt String raw values?

### Method
- `rg "enum.*: Codable|: Codable" /Users/ronny/rdev/rTerm/TermCore/ --type swift -n | grep -v "//"`
- Read `TermCore/Shell.swift`, `TermCore/DECPrivateMode.swift`, `TermCore/TerminalColor.swift`, `TermCore/DaemonProtocol.swift`

### Raw findings

Codable enums in TermCore:

| Enum | File | Cases | String raw? | Notes |
|------|------|-------|-------------|-------|
| `BufferKind` | ScreenSnapshot.swift:42 | `main`, `alt` | **Yes** (T3 change) | Pure string tags |
| `Shell` | Shell.swift | `bash`, `zsh`, `fish`, `sh` | No | All no-payload cases matching executable names |
| `TerminalColor` | TerminalColor.swift | `default`, `ansi16(UInt8)`, `palette256(UInt8)`, `rgb(UInt8,UInt8,UInt8)` | No — cannot | Has associated values |
| `DaemonRequest` | DaemonProtocol.swift | `listSessions`, `createSession(...)`, `attach(...)`, `detach(...)`, `input(...)`, `resize(...)`, `destroySession(...)` | No — cannot | Has associated values |
| `DaemonResponse` | DaemonProtocol.swift | `sessions(...)`, `sessionCreated(...)`, `attachPayload(...)`, `sessionEnded(...)`, `output(...)`, `error(...)` | No — cannot | Has associated values |
| `DaemonError` | DaemonProtocol.swift | `sessionNotFound(SessionID)`, `spawnFailed(Int32)`, `alreadyAttached(SessionID)`, `internalError(String)` | No — cannot | Has associated values |
| `DECPrivateMode` | DECPrivateMode.swift | 9 cases including `unknown(Int)` | No — cannot | Has associated value on `.unknown` |

### Conclusion
`Shell` is the only other enum with all no-payload cases that could adopt `String` raw values. However `Shell` is **not** used in `ScreenSnapshot` encoding — it lives in `DaemonRequest.createSession` which uses Swift's synthesized `Codable` encoder (tagged dict: `{"_0": {"bash": {}}}` style). Adding `String` raw values to `Shell` would change the on-wire encoding format for the XPC protocol, which is a protocol-breaking change with no readability benefit at that layer. `BufferKind` was different: it appeared directly as a JSON string in `ScreenSnapshot` payloads where `"main"` vs `"alt"` is clearly human-readable. **No other enum warrants the same migration.**

---

## Summary

| Question | Finding | Action |
|----------|---------|--------|
| `TerminalModes` vs `OptionSet` | Named bools are correct; `OptionSet` applies only to combination semantics | None |
| `handleSetMode` keypath helper | No precedent exists; pattern is deferred until T4 adds alt-screen arms | Defer to T4 |
| `decodeIfPresent ?? default` helper | Only 4 sites, no existing helper; not worth abstracting yet | None |
| Test boilerplate | Consistent with existing convention across 52 total instantiations | None |
| `BufferKind: String` migration candidates | `Shell` is the only candidate but migration would break XPC wire format | None |

Overall: **T3 is clean for reuse.** No new patterns that warrant factoring; the one deferred suggestion (keypath-based mode dispatch) remains appropriately deferred to T4.
