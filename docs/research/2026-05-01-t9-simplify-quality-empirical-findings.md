# T9 Simplify/Quality Review — Empirical Findings
Date: 2026-05-01
Commit: 9d168de

Scope: targeted questions on six design choices in the T9 renderer commit.
Prior reviews already covered: nonisolated correctness, reserveCapacity gap,
dim+bold test, plan-vs-doc dimming inconsistency.

## Files examined
- rTerm/RenderCoordinator.swift
- rTerm/GlyphAtlas.swift
- rTerm/AttributeProjection.swift
- rTermTests/AttributeProjectionTests.swift
- rTerm/ContentView.swift (Logger pattern)
- rTerm/TermView.swift (Logger pattern)
- TermCore/Logging.swift (Logger.TermCore namespace)

---

## 1. Vertex-array + draw-pass duplication — dict/array-of-pairs vs explicit vars

### What exists
Four named `[Float]` arrays (regularVerts, boldVerts, italicVerts,
boldItalicVerts) + four parallel `if !verts.isEmpty { makeBuffer ... draw }`
blocks (lines 241–307). Total: ~64 lines for the glyph-atlas draw path.

### Would `[GlyphAtlas.Variant: ([Float], MTLTexture)]` help?
In theory: one loop to build verts, one loop to emit draw calls.
In practice on this codebase:

**Against the dictionary approach:**
- `GlyphAtlas.Variant` is a value-type enum; it is `Equatable` but not `Hashable`.
  Adding `Hashable` conformance would be a one-liner, but it is not currently
  there. A typed array-of-pairs avoids that requirement.
- At 4 entries, dictionary lookup overhead (hashing, collision probe) is pure
  noise, but it also provides zero readability benefit over a switch/named vars.
- Dictionary literals for `[Variant: ([Float], MTLTexture)]` would capture the
  atlas texture at init time but the vertex array must be rebuilt every frame —
  the two lifetimes don't match cleanly. You'd need a dictionary of just verts
  keyed by variant and a parallel lookup into the atlas properties, or a
  `(verts: [Float], atlas: GlyphAtlas)` pair.

**Against an array-of-pairs:**
- `[(verts: [Float], atlas: GlyphAtlas)]` collapses the 4 × 18 line draw blocks
  to a single 10-line loop. That is the most honest reduction available here.
- Requires the loop to be order-stable (it would be — you build the array in a
  fixed order), which is fine.

**Verdict:** The explicit-variable form is the right trade-off for this commit.
The four named arrays are self-documenting, exhaustiveness is checked at the
`switch variant` site, and the draw-pass blocks are short enough (18 lines each)
that the repetition is traceable. The `[(verts, atlas)]` refactor is a genuine
simplification opportunity but belongs in a dedicated clean-up commit, not a
feature commit. The dictionary form is slightly worse than array-of-pairs for
this use case (Hashable requirement, lookup cost on a 4-element collection).

---

## 2. Strikethrough vs underline draw passes — shared helper worth extracting?

### What exists
Underline pass (lines 310–327) and strikethrough pass (lines 329–345) are
structurally identical: guard on `!verts.isEmpty`, `device.makeBuffer(…)`,
`renderEncoder.setVertexBuffer`, `drawPrimitives`. The only differences are
the variable name, the vertex count divisor (both `floatsPerOverlayVertex`),
and the `setRenderPipelineState` call (underline sets it first; strikethrough
repeats the same state).

### Is a helper worth it?
A helper such as:
```swift
private func drawOverlayPass(verts: [Float],
                              into encoder: MTLRenderCommandEncoder)
```
would reduce each pass to a 2-line call site. The helper body would be
~8 lines. Net saving: ~16 lines at the cost of one extra function in the
call chain.

**Verdict:** Borderline. The duplication is two blocks of ~8 lines each;
extracting it would be a genuine improvement to maintainability (especially
if a third overlay type is added — cursor already uses `setVertexBytes`, not
this path, so it wouldn't collapse into the helper). For a production codebase
the helper is worth it. For this PR it is a "nice to have" — the existing
duplication is readable and traceable without it.

---

## 3. `lastSeenBellCount` and `lastBeepAt` — `private(set)` vs `private var`

`private var` is correct here. `private(set)` means:
- read is at the declared access level (`private` without a modifier → `private`)
- write is restricted to `private(set)` — same file/type

Since both properties are already `private`, `private(set)` would be redundant:
the setter is already `private` by the access modifier. `private(set)` is useful
when the variable is `internal` or `public` (e.g., `public private(set) var` for
a read-only-from-outside, writable-internally property). In this context it adds
no documentation value and is not idiomatic.

**Verdict:** `private var` is correct and idiomatic. No change needed.

---

## 4. `bellMinInterval = 0.2` — magic number, `private static let` + comment?

### What exists
`private let bellMinInterval: TimeInterval = 0.2` at line 59.

### Current documentation
The doc comment on `lastBeepAt` (lines 54–58) already explains the purpose and
gives the example of `yes $'\a'`. The `bellMinInterval` line itself has no
comment.

### Verdict
A `private static let bellMinInterval: TimeInterval = 0.2 // 200 ms, matches xterm's BEL rate-limit` would be a meaningful improvement:
- Makes it a shared constant across instances (trivially, since coordinators
  are not pooled, but signals intent).
- The inline comment citing xterm precedent is the load-bearing addition — the
  doc comment on `lastBeepAt` explains "why rate-limit" but not "why 200 ms".
  Without it, `0.2` looks arbitrary.

The existing `private let` instance form is not wrong (a `let` on a `@MainActor`
class is effectively immutable per-instance; there's no per-instance variance
here). The upgrade to `static let` + inline xterm comment is a low-cost quality
improvement.

---

## 5. Narrating comments that don't pull weight

Scanned all new comments in the diff.

**Earn their place:**
- Lines 49–58: bell-field doc comments explain the rate-limit design and
  give a concrete adversarial example (`yes $'\a'`). Non-obvious behavior,
  clearly documented.
- Lines 126–135 (bell observer block): the "Always advance lastSeenBellCount"
  comment explains a subtle intent (collapse backlog) that the code itself
  doesn't make obvious. Useful.
- Lines 138–144 (vertex-buffer comment block): updates the earlier "regular or
  bold batch" description to include italic/boldItalic. Accurate and necessary
  since the block's count changed.
- AttributeProjection.swift lines 23–30: the xterm charproc.c / iTerm2 citation
  for dim-before-reverse order is load-bearing documentation — it justifies a
  non-obvious composition order that affects correctness, not just style.

**Possibly over-narrating:**
- RenderCoordinator.swift line 147 `let verticesPerCell = 6` — the name is
  self-explanatory and the value is the same as before T9. The inline let is
  the same pattern as `floatsPerCellVertex` and `floatsPerOverlayVertex` so
  consistency matters more than brevity here.
- GlyphAtlas.swift init comment "Apply italic trait. monospaced system font…":
  the text is accurate but long for a comment introducing a 3-line code block.
  Could be trimmed to "Synthesized oblique when no true italic master exists;
  falls back to regular on descriptor failure." The current text is not wrong
  but slightly over-explains what the code already shows.

**Overall:** No comment is pure noise or misleading. One is slightly over-long.
No action required.

---

## 6. Forward references to T10 — still useful, or noise?

Searched source files (rTerm/, TermCore/) for "T10", "scrollback", "Phase 3".
Result: zero matches in source code.

The only T10 mentions are in commit messages and the plan document
(`docs/superpowers/plans/2026-05-01-control-chars-phase2.md`). No source-level
forward reference to remove.

**Verdict:** Not applicable to this commit. The prior T9 commit had Phase 2
comments in GlyphAtlas.Variant; those were correctly removed in this commit
(the `// Phase 2: // case italic` stubs are gone from the diff).

---

## 7. Italic font fallback — inline Logger vs centralized `Logger.rTerm.*`

### Existing pattern in rTerm target
- `ContentView.swift:40` — `private let log = Logger(subsystem: "rTerm", category: "TerminalSession")`
- `TermView.swift:34`    — `private let log = Logger(subsystem: "rTerm", category: "TerminalMTKView")`
- `GlyphAtlas.swift:115`— `Logger(subsystem: "rTerm", category: "GlyphAtlas").warning(…)` (inline construction, no stored property)

### TermCore pattern
`TermCore/Logging.swift` defines a `Logger.TermCore` namespace enum with static
`let` properties, one per category. All TermCore callers use `Logger.TermCore.*`.

### rTerm target status
The rTerm target has no equivalent `Logger.rTerm` namespace. ContentView and
TermView store loggers as instance `private let` properties (the older pattern).
GlyphAtlas uses an ad-hoc inline construction at the call site — it avoids adding
a stored property to a `struct` just for a one-shot warning.

### Is the inline construction a deviation?
Technically yes relative to the TermCore namespace pattern, but the rTerm target
has not yet adopted a namespace. The inline `Logger(subsystem:category:)` form
is functionally correct: it creates a `Logger` value type (cheap, stack-allocated)
on the rare warning path. The `os_log` subsystem-category routing is identical to
what a stored property would produce.

### What should it be?
The lowest-friction fix consistent with the TermCore pattern is to add a
`rTerm/Logging.swift` file with:
```swift
extension Logger {
    enum rTerm {
        static let subsystem = "rTerm"
        static let glyphAtlas    = Logger(subsystem: subsystem, category: "GlyphAtlas")
        static let terminalSession = Logger(subsystem: subsystem, category: "TerminalSession")
        static let terminalMTKView = Logger(subsystem: subsystem, category: "TerminalMTKView")
    }
}
```
and updating the three call sites. This is a hygiene improvement, not a bug.
The inline construction in GlyphAtlas is not wrong for a struct that fires the
warning at most once per atlas variant per app launch.

**Verdict:** The inline Logger construction is a minor inconsistency with the
TermCore namespace pattern. Worth tracking as a housekeeping item. The GlyphAtlas
specific form is defensible (struct, one-shot path). Adding `rTerm/Logging.swift`
would bring the rTerm target into line with TermCore convention.
