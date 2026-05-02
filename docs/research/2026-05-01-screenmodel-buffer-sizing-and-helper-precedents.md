# ScreenModel `Buffer` sizing, hot-path access patterns, and helper precedents

**Date:** 2026-05-01
**Context:** /simplify pass on Phase 2 T2 (`4294571 model: dual-buffer ScreenModel refactor`)
**Investigators:** simplify reuse / quality / efficiency reviewer subagents

## Question

What does the dual-buffer refactor cost in terms of memory and per-call work, and are the new abstractions (`mutateActive`, `Buffer`, `static scrollUp`) reinventing existing TermCore patterns?

## Findings

### Memory footprint

- `Buffer` value-type header: **72 bytes**
  - `ContiguousArray<Cell>` header: 8 bytes
  - `Cursor`: 16 bytes
  - `Optional<Cursor>` (`savedCursor`): 24 bytes
  - `Optional<ScrollRegion>` (`scrollRegion`): 24 bytes
- `Cell` stride: **~32 bytes**
- Grid heap slab at default 80×24: **~60 KB** (1920 cells × 32-byte stride)
- T2 net memory impact: one extra `Buffer` (`alt`) → one additional 60 KB slab + 72 bytes header. Allocated once at `init`, never CoW-copied while alt is unused.

### Hot-path costs

`var active: Buffer` is a getter that returns by value — every access materializes a **72-byte struct copy** on the caller's stack. CoW means the underlying grid heap is shared (no allocation), but the header copy is real.

Call sites in `publishSnapshot` (T2 baseline):
- `active.grid` (line 217)
- `snapshotCursor()` → `active.cursor` (line 537)

Result: **two 72-byte copies per `publishSnapshot` invocation**. `publishSnapshot` runs once per `apply(_:)` batch that mutated state — sub-dominant compared to per-event handler work but trivially eliminated by binding `active` once.

`mutateActive<R>(_:)` in `-O` builds: zero overhead per call. Generic closure specializes at the call site; the body sees an `inout Buffer` pointer (no copy). The single conditional branch on `activeKind` is the only ABI cost.

### Allocation hot-spots in non-hot paths

`restore(from:)` (post the prior code-quality fix that removed the second alloc): still allocates a `rows × cols` grid via `Buffer(rows:cols:)`, then immediately drops the slab when `seeded.grid = snapshot.activeCells` reassigns. One `malloc` + one `free` per session reattach. Acceptable cost (reattach is rare); a `Buffer.init(rows:cols:grid:cursor:)` would eliminate it but adds API surface.

### Existing TermCore precedents

- **No `withFoo { ... }`-style closure helpers anywhere in TermCore.** `mutateActive` is genuinely new (not a reinvention).
- **No bulk-fill / `withUnsafeMutableBufferPointer.copyMemory` precedent.** `RingBuffer` (`/Users/ronny/rdev/rTerm/TermCore/RingBuffer.swift`) and `CircularCollection` (`/Users/ronny/rdev/rTerm/TermCore/CircularCollection.swift`) both copy element-by-element. The nested `for col in 0..<cols` loop in `scrollUp` matches that project-wide convention.
- **`Cell.empty` is the canonical empty sentinel.** Defined as `Cell(character: " ")` at `Cell.swift:33`. T2's switch from `Cell(character: " ")` to `.empty` in `eraseInDisplay`/`eraseInLine` is a consistency fix, not a behavior change.
- **`Buffer.init(rows:cols:)` matches Phase 1's grid allocation spelling** (`ContiguousArray(repeating: .empty, count: rows * cols)`).

### API hygiene observations

- `ScrollRegion` was first added at file scope without an access modifier (defaults to `internal` — visible across the whole `TermCore` module). Promoted to `private` in the post-review fixup since it's only consumed inside the file's `Buffer` and handlers. T5 may need to revisit if scroll-region info needs to surface via `ScreenSnapshot`.
- `currentIconName()` and `setIconName()` are `public` on `ScreenModel` but have zero call sites outside `ScreenModel.swift` (`rg` confirmed). Likely intentional surface for a future TerminalSession consumer; if no consumer materializes by Phase 3, downgrade to `package`.
- `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` for `TermCore` (Release). Public type additions affect ABI — reviewers should weigh access modifiers against future flexibility.

### Latent traps for future tasks

- `scrollUp` declares `let stride = cols` locally — shadows stdlib `stride(from:through:by:)`. T5 will likely need range arithmetic for DECSTBM bounds; a developer reaching for `stride(from: top, through: bottom, by: 1)` inside `scrollUp` would get a type error instead of a call. Worth renaming to `colWidth` or inlining `cols`.

## Method

- `git show 4294571 -- TermCore/ScreenModel.swift` for the diff
- Direct read of `TermCore/ScreenModel.swift`, `TermCore/Cell.swift`, `TermCore/Cursor.swift`, `TermCore/RingBuffer.swift`, `TermCore/CircularCollection.swift`
- `rg` searches across the codebase for `withUnsafeMutableBufferPointer`, `copyMemory`, `memmove`, `currentIconName`, `setIconName`, `withFoo`-style helpers, `Cell.empty` usage
- Swift type sizing inferred from field layout (no `MemoryLayout` runtime measurement)

## Conclusions

- The T2 refactor introduces no significant per-call overhead; the only measurable hot-path cost is the redundant `active` accessor copy in `publishSnapshot`, fixable with a one-line bind.
- `mutateActive`, `Buffer`, and `static scrollUp` do not duplicate any existing helper. The shape is genuinely new and consistent with the codebase's no-unsafe-bulk-ops convention.
- The `stride` local-variable name collision is a latent trap worth fixing now to spare T5 a confusing diagnostic.
- API hygiene: `ScrollRegion` access level was caught and fixed; `currentIconName()` access level can wait until Phase 3 confirms whether a caller materializes.
