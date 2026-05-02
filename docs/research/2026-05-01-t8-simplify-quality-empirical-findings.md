# T8 Simplify/Quality Review — Empirical Findings

Date: 2026-05-01
Commit: 78b5f43 ("input: bracketed paste (Phase 2 T8)")
Reviewer: Claude Sonnet 4.6 (swift-engineering + swift-concurrency-pro roles)
Prior reviews addressed: nonisolated bracketedPasteWrap, formal NSMenuItemValidation
conformance, stale T8/T10 forward-reference comment.

---

## Q1: `Data()` + `reserveCapacity` vs `Data(capacity:)` — worth changing?

**No. Not worth changing.**

The two initializers have meaningfully different semantics:

- `Data()` creates an empty buffer. `reserveCapacity(_:)` is then a hint;
  the standard library is free to over-allocate or round up.
- `Data(capacity:)` (the `NSData(capacity:)` bridge) also creates an empty
  buffer but with a *minimum* pre-allocation. The result is still count == 0
  and is appended to exactly like the `reserveCapacity` path.

In practice both patterns produce identical behavior and identical performance
for a 12-byte overhead append. LSP hover on `Data.init()` confirms it is
`@inlinable`; `reserveCapacity` is also `@inlinable`. The compiler will inline
both. There is no observable difference in a hot path, let alone for a
human-speed paste event.

The current pattern (`var data = Data(); data.reserveCapacity(...)`) is:
1. Idiomatic Swift (matches `RangeReplaceableCollection` conventions).
2. More readable — the capacity hint and the appends are visually separate,
   making the intent obvious.
3. Consistent with other `Data` construction in the codebase (none use
   `Data(capacity:)`; verified via `rg "Data(capacity:"` — no hits).

`Data(capacity:)` would not be wrong, but it offers no correctness benefit
and is slightly less idiomatic Swift. Do not change.

---

## Q2: `log.debug("paste: \(str.count) chars")` — privacy annotation needed?

**No. Not a concern.**

The log statement records only `str.count` — an integer metadata value. It
does not log any pasteboard content. At `debug` level it is suppressed in
production logs and requires `log stream --level debug` to observe even in
development.

The entire codebase has zero `privacy:` annotations (confirmed: `rg "privacy"
--include="*.swift"` returns no results). The parallel `sendInput` log at
`ContentView.swift:102` uses the same pattern — `\(data.count) bytes` — with
no annotation. The `keyDown` log at `TermView.swift:62` logs `event.keyCode`
(a key code integer, not the character typed) without annotation.

The project convention is: log metadata (counts, codes), never content. This
log follows that convention. Adding `, privacy: .public` would not be wrong,
but it is not required and would be inconsistent with the rest of the file.

If the project ever adds a privacy audit pass, `\(str.count, privacy: .public)`
would be the idiomatic form (explicitly marks the count as non-sensitive for
log collection tools). File that as a future project-wide hygiene item, not a
T8 fix.

---

## Q3: `validateMenuItem(_:)` returns `true` for non-paste actions — correct?

**Yes, `return true` is correct.**

The prior quality review (docs/research/2026-05-01-t8-quality-review-empirical-
findings.md §Q: validateMenuItem returning correct bool) established the answer
definitively. Summary:

- `return true` for unrecognized actions is the standard AppKit pattern for
  objects that handle only a subset of menu actions.
- Returning `false` would wrongly disable actions that belong to responders
  higher in the chain (e.g., Edit > Copy, Edit > Select All).
- `super.validateMenuItem(menuItem)` is not callable because `NSView`/
  `NSResponder` do not declare `validateMenuItem` — `return true` is the
  only correct fallback.
- Prior behavior (T7, no `validateMenuItem` at all) is equivalent: AppKit
  defaults to enabled when no validator is found. `return true` preserves
  that behavior with explicit protocol conformance.

No change needed.

---

## Q4: Anything else not caught by prior reviews?

### Finding 1 — `paste(_:)` reads pasteboard on main thread twice per paste

`TerminalMTKView.paste(_:)` (TermView.swift:71-76):
```swift
func paste(_ sender: Any?) {
    let pb = NSPasteboard.general
    guard let str = pb.string(forType: .string), !str.isEmpty else { return }
    log.debug("paste: \(str.count) chars")
    onPaste?(str)
}

func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(paste(_:)) {
        return NSPasteboard.general.string(forType: .string) != nil
    }
    return true
}
```

The pasteboard is read in `validateMenuItem` (once, to check availability) and
again in `paste(_:)` (once, to retrieve the string). This is inherent to the
AppKit menu validation model — the menu item is validated before the action
fires, and the two calls cannot share a result. Between the two calls, the
pasteboard could theoretically change (another app copies something). This is
not a bug: AppKit's own NSTextView has the same TOCTOU characteristic for paste,
and there is no race-free alternative given the API design. Document as
expected behavior, not a defect.

Verdict: **not a defect; expected AppKit pattern.**

### Finding 2 — Access level on `bracketedPasteWrap` vs prior review conclusion

The prior review (§Q: nonisolated public static on a non-public class) correctly
concluded that `public` on a member of an `internal` class in an app target is
effectively `internal`, and that this follows an existing project convention
(TerminalPalette, RGBA). No new finding here; confirm the earlier verdict stands.

### Finding 3 — `NSMenuItemValidation` formal conformance now declared

The prior quality review (commit 8cb30b2) raised the missing `NSMenuItemValidation`
conformance as a static-typing omission. This commit (78b5f43) adds it:

```swift
final class TerminalMTKView: MTKView, NSMenuItemValidation {
```

The prior finding is resolved. The compiler will now verify the method signature
matches the protocol requirement. No `override` keyword applies because
`validateMenuItem` is not on a superclass — correct.

### Finding 4 — `TermView` `onPaste` parameter is non-optional but has a default?

`TermView.onPaste` is declared `var onPaste: ((String) -> Void)?` — optional,
matching the `onInput` pattern. The ContentView call site provides a concrete
closure. No issue: the optional allows future callsites (e.g., a read-only view)
to omit paste support without compiler error. Pattern is consistent with `onInput`.

---

## Summary

All three specific questions have clean answers:

| Question | Verdict |
|----------|---------|
| `Data(capacity:)` vs `Data()` + `reserveCapacity` | No change needed; current pattern is idiomatic and consistent. |
| `privacy:` annotation on paste log | No change needed; log records metadata only; no project precedent for annotations. |
| `return true` in `validateMenuItem` for non-paste items | Correct and standard. |

No new defects found. The commit is clean.
