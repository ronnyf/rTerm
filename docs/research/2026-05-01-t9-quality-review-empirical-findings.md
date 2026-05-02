# T9 Quality Review — Empirical Findings
Date: 2026-05-01
Commit: 52637ff (phase-2-control-chars)

## Files examined
- rTerm/AttributeProjection.swift
- rTerm/GlyphAtlas.swift
- rTerm/RenderCoordinator.swift
- rTermTests/AttributeProjectionTests.swift
- TermCore/CellStyle.swift (CellAttributes definition)
- rTerm/ColorProjection.swift (nonisolated enum precedent)

## nonisolated enum — Swift 6 validity

`nonisolated` applied at the type level to an `enum` is valid Swift 6 syntax and is
the correct mechanism to suppress inherited `@MainActor` isolation from the module
default (`SWIFT_APPROACHABLE_CONCURRENCY = YES`). Confirmed by two pre-existing
uses in the same target:
  - `ColorProjection.swift:52` — `nonisolated public enum ColorProjection`
  - `ColorProjection.swift:32` — `@frozen nonisolated public enum ColorRole`
Both compile cleanly and are called from tests that run off the main actor.

`GlyphAtlas.Variant` is a nested enum inside a `struct`. Nested type declarations
inherit the outer type's isolation. `GlyphAtlas` is not isolated (it is a plain
struct, not a global-actor-isolated type), so `nonisolated` on `Variant` is
technically redundant but not wrong — it is defensive documentation that the enum
doesn't require any actor context, mirroring the comment.

## var resultFg / resultBg vs let tuple

`project()` uses two `var` locals mutated in-place across two conditional branches
(dim check, then reverse-swap via `swap(&,&)`). The `swap` call specifically
requires mutability — it cannot be expressed as a single `let` binding without
an intermediate temp. The current form is correct and clear.

## atlasVariant() tuple-switch

The (Bool, Bool) tuple switch is exhaustive and readable. Four cases, no default
fallthrough risk. The compiler verifies exhaustiveness. Acceptable.

## draw() per-cell loop overhead

Loop: 80 × 24 = 1,920 iterations.
Per iteration: one `.contains` (OptionSet bitmasked AND on UInt16), one 4-way
switch, one `project()` call (2 multiplies + 2 branch for swap at worst).
All on stack-allocated value types. At 60 fps this is ~115k iterations/s — well
within the CPU budget for a frame that is dominated by Metal GPU work. Not a
performance concern.

## reserveCapacity gap for underlineVerts

Lines 149–159: `regularVerts`, `boldVerts`, `italicVerts`, `boldItalicVerts`, and
`strikethroughVerts` all call `reserveCapacity`. `underlineVerts` (line 153) does
NOT call `reserveCapacity`. This is a minor inconsistency — underline cells are
bounded by the same rows*cols product and could receive the same hint. The omission
will cause a realloc in the common case (a terminal full of underlined text). Not
a correctness bug; a performance inconsistency.

## Strikethrough vs underline — shared helper

Strikethrough and underline are genuinely parallel: identical vertex-append path
(appendOverlayQuad), only differing in their y-coordinate math. A small private
helper `overlayLineVerts(cellHeight:position:thicknessFraction:)` → (y0, y1) would
de-duplicate 6 lines. Currently the duplication is minimal; acceptable as-is but
worth noting.

## Bell observer — monotonic time

`ProcessInfo.processInfo.systemUptime` is documented as monotonic wall-clock
seconds since boot, unaffected by NTP steps or time zone changes. Correct choice
for a rate limiter.

## bellMinInterval — static vs let

Declared `private let bellMinInterval: TimeInterval = 0.2` on the instance.
The LSP confirms it infers as `@MainActor private let bellMinInterval`. Since
`RenderCoordinator` is `@MainActor final class`, a `let` constant is semantically
identical to a `static let` here — no heap allocation difference. The instance
`let` form is consistent with AppSettings-style settings usage in this file.
Not a bug. A `static let` or `// 200 ms` inline comment would document intent
more explicitly, but the current form is harmless.

## Italic font fallback — "one-time" warning claim

The commit message says "log a one-time warning". Examination of
GlyphAtlas.init (line 115–117) shows the `Logger.warning` is emitted inside
`init` — `GlyphAtlas` is constructed once per `Variant` in `RenderCoordinator.init`,
so the warning fires at most once per atlas variant per app launch. The "one-time"
claim is accurate for normal use (coordinator is not recreated). No `static var
warningLogged` guard is needed because the construction site is already
effectively once-per-process. Correct as-is.

## import AppKit in RenderCoordinator

T8 did NOT import AppKit — confirmed by `git show 0dc9586:rTerm/RenderCoordinator.swift`.
T9 adds it for `NSSound.beep()`. `MetalKit` on macOS transitively pulls in AppKit
through Objective-C umbrella headers, so it was available before without an
explicit import. The explicit `import AppKit` is correct hygiene — it documents
the dependency on `NSSound` and `ProcessInfo`.

## CellAttributes full set vs test coverage

CellAttributes has 7 flags: bold, dim, italic, underline, blink, reverse, strikethrough.
`atlasVariant()` only reads bold + italic. Tests cover: [], [bold], [italic],
[bold, italic], [bold, underline] (non-atlas attr guard). Gap: no test for
`[dim, bold]` or `[dim]` to confirm dim does not bleed into atlas selection. This
is a test gap, not a logic bug — `atlasVariant` only reads bold/italic bits and
the logic is trivially correct. Low risk.

`project()` tests cover: empty, reverse-only, dim-only, dim+reverse. No test for
reverse-only on identical fg/bg (trivially correct but worth a comment). Acceptable.

## @testable import rTerm — module stability

`AttributeProjectionTests.swift:12` uses `@testable import rTerm`. `rTerm` is an
app target, not a library. `@testable` on an app target is fine — it does not
affect `BUILD_LIBRARY_FOR_DISTRIBUTION` (only TermCore has that set). No issue.
