# T8 Efficiency Review — Empirical Findings

Date: 2026-05-01
Commit: 78b5f43 ("input: bracketed paste (Phase 2 T8)")
Reviewer: Claude Sonnet 4.6 (swift-engineering, swift-concurrency-pro, swiftui-pro)

## Scope

Paste is a rare, user-initiated event (Cmd-V or Edit menu). Nothing on the paste
path runs in a frame loop or tight loop. Efficiency concerns exist only if there
is a systematic overhead pattern that would degrade across the lifetime of the
app — not per-call cost.

---

## Q: `bracketedPasteWrap` allocates a Data on every paste — is this an issue?

`bracketedPasteWrap` allocates two `Data` values per enabled paste:

1. `payload = Data(text.utf8)` — copies the pasteboard string to bytes.
2. `data = Data()` with `reserveCapacity(payload.count + 12)` — result buffer.

The disabled path returns `payload` directly (one allocation).

`reserveCapacity` is exact (6 + 6 = 12 overhead bytes, verified against the
literal byte arrays in the source). No over-allocation, no growth.

**Assessment:** Trivially correct. Paste is a rare human event; per-call
allocation cost is irrelevant. The `reserveCapacity` call even eliminates the
one internal reallocation that would otherwise occur on `append(payload)`.

---

## Q: `latestSnapshot()` read on every paste — same nonisolated mutex pattern as T7?

Yes. `TerminalSession.paste(_:)` (ContentView.swift:132) calls
`screenModel.latestSnapshot()`.

LSP + source confirm:
- `latestSnapshot()` is `nonisolated public` (ScreenModel.swift:681).
- Implementation: `_latestSnapshot.withLock { $0.snapshot }` — a single
  `Mutex` lock acquisition returning an already-computed `ScreenSnapshot`
  struct value (copy-on-read, no actor hop, no `await`).
- Called from `@MainActor func paste(_:)` — same isolation, zero contention
  in practice (the only writers are actor-isolated `apply` calls on the
  ScreenModel actor, which never run concurrently with the paste path).

**Assessment:** Identical to T7's `latestSnapshot()` usage. Trivial synchronous
lock, constant time, no blocking. No concern.

---

## Q: Anything else worth flagging on the paste path?

### Actor isolation chain (verified via LSP hover)

| Symbol | Isolation |
|--------|-----------|
| `TerminalMTKView.paste(_:)` (TermView.swift:71) | `@objc @MainActor` |
| `TerminalMTKView.validateMenuItem(_:)` (TermView.swift:81) | `@MainActor` |
| `TerminalSession.paste(_:)` (ContentView.swift:131) | `@MainActor` |
| `TerminalSession.bracketedPasteWrap` (ContentView.swift:118) | `nonisolated static` |

AppKit delivers responder-chain actions on the main thread. All four symbols are
either `@MainActor` or `nonisolated`. The full call chain:

```
AppKit main thread
  -> TerminalMTKView.paste(_:)          [@MainActor]
     -> onPaste?(str)                   [closure, captured from @MainActor context]
        -> session.paste(text)          [@MainActor]
           -> screenModel.latestSnapshot()  [nonisolated, Mutex lock]
           -> Self.bracketedPasteWrap(...)  [nonisolated static, pure]
           -> sendInput(data)           [@MainActor]
```

No isolation boundary crossing. No `await`. No unstructured `Task`. Clean.

### `NSMenuItemValidation` conformance — verified correct

The T8 quality review (t8-quality-review-empirical-findings.md) already confirmed
the `NSMenuItemValidation` formal conformance was added correctly in this commit
(`TerminalMTKView: MTKView, NSMenuItemValidation` at TermView.swift:32). The prior
T7 state had no conformance; T8 adds it. LSP hover confirms `validateMenuItem`
resolves as `@MainActor func validateMenuItem` under the protocol requirement.
Runtime impact was already documented as zero (AppKit uses `respondsToSelector:`).

### `validateMenuItem` double pasteboard read

`validateMenuItem(_:)` (TermView.swift:83) calls `NSPasteboard.general.string(forType:)`.
`paste(_:)` (TermView.swift:73) also calls `NSPasteboard.general.string(forType:)`.

On Cmd-V, AppKit calls `validateMenuItem` to enable the item, then calls `paste(_:)`.
That is two pasteboard reads. On a rare user action with no hot-path concern this
is irrelevant, but it is worth noting:

- These two reads are serialized on the main thread (no race).
- There is a theoretical TOCTOU: pasteboard content could change between the
  `validateMenuItem` check and the `paste(_:)` read. The `paste(_:)` guard
  (`guard let str = ... else { return }`) handles the nil case correctly, so the
  only observable effect of a TOCTOU would be an enabled-but-silent paste, which
  is acceptable UI behavior.
- No fix needed. Documented for completeness.

### `!str.isEmpty` guard

`paste(_:)` guards `!str.isEmpty` before sending. This prevents a zero-byte XPC
send. The `test_wrap_empty_enabled` test confirms the wrapper handles empty string
correctly (12-byte envelope only), so the guard is a conscious pragmatic choice
to avoid a useless round-trip, not a correctness gap.

---

## Summary

All three originally-scoped questions are clean:

1. `bracketedPasteWrap` allocations: trivial, paste is rare. `reserveCapacity`
   is exact, no over-allocation. No concern.
2. `latestSnapshot()` read: nonisolated Mutex, same pattern as T7. Trivial. No concern.
3. Anything else: actor isolation chain is clean end-to-end (verified LSP).
   `NSMenuItemValidation` conformance correctly declared. Double pasteboard read
   is a minor TOCTOU curiosity, not a real issue given the guard in `paste(_:)`.

**Paste path is clean. No efficiency or correctness issues.**
