# Phase 3 Spec Review — Empirical Findings

- **Date:** 2026-05-02
- **Reviewer:** Claude Opus 4.7 (spec revision pass)
- **Scope:** `docs/superpowers/specs/2026-04-30-control-characters-design.md` — Phase 3 section and cross-section consistency after Phase 2 landed
- **Inputs:** Spec file; Phase 2 final review; Phase 2 branch-wide efficiency, simplify/reuse, simplify/quality empirical findings; `git log`; Phase 2 follow-up commit `8aeea2d`

---

## Q1: Was the spec's Phase 3 scope accurate to what the research docs demanded?

**Method:** Cross-referenced every bullet in the original §8 Phase 3 list against the four Phase 2 research docs' recommendations.

**Findings:**

The original Phase 3 section conflated two distinct tracks into one flat bullet list:
- **Feature scope** (OSC 8, OSC 52, blink, Unicode atlas, palette UI, flyweight, dirty tracking, fetchHistory, Span).
- **Engineering hygiene** (not present at all in the original spec).

The Phase 2 efficiency research (summary table) enumerates at least three hot-path regressions that shipped in Phase 2 (vertex array alloc, Row-per-LF alloc, doubled Metal buffer count). The Phase 2 quality research enumerates seven latent-risk or maintainability items (12-param init, 941-line file, deferred refactors, force-cast safety, ordering-invariant doc, discardableResult redundancy, test gaps). None of these appear in the original Phase 3 scope.

This is the single largest gap the spec review identified. The Phase 3 scope was a feature-only list; the engineering realities of what Phase 2 left behind were invisible to it. An implementer reading the spec cold would have no reason to expect Phase 3 to contain a hygiene track.

**Action taken:** Rewrote §8 Phase 3 into two explicit tracks (A: features; B: engineering hygiene), both mandatory. Each of the 13 hygiene items has concrete scope and a rationale tied to the research doc that found it.

---

## Q2: Was the Phase 3 feature scope realistic?

**Method:** Cross-referenced the original Phase 3 bullet list against implementation complexity.

**Findings:**

The original list bundled items of radically different scope:

- **Shippable in one phase:** OSC 8 hyperlinks (parser already has the seam), OSC 52 set path, palette chooser UI, blink uniform.
- **Phase-sized each:** Unicode atlas beyond ASCII (dynamic LRU, CoreText fallback), `CellStyle` flyweight (scrollback memory halving, style-table allocation discipline), `fetchHistory` RPC (requires new XPC surface + pagination contract), per-row dirty tracking (requires refactoring the version-counter invalidation model), `Span<Cell>` at boundaries.
- **Not in the original list but commonly required:** DECSCUSR (cursor shape), DA1/DA2/CPR responses (required for vim/tmux detection), DECOM, DECCOLM, mouse tracking, sixel, kitty images.

A Phase 3 that attempts all of the original list plus the commonly-required-but-missing items is two phases of work, not one. The spec implicitly invited scope creep.

**Action taken:** Tightened Phase 3 Track A to: OSC 8 full path, OSC 52 set path, DECSCUSR, blink, DA1/DA2/CPR, DECOM, DECCOLM, palette chooser UI, integration fixture corpus completion. Moved the heavier items to Phase 4+ with explicit rationale:
- Unicode atlas → Phase 4
- `CellStyle` flyweight → conditional on OSC 8 memory measurement, else Phase 4
- `fetchHistory` RPC → past Phase 3 (500-row attach still sufficient)
- Per-row dirty tracking → deferred
- `Span<Cell>` → deferred
- Mouse tracking → Phase 4
- Sixel / kitty → Phase 4+
- Character sets → Phase 4+

This is a material narrowing of Phase 3's ambition, which should make the Phase 3 plan tractable in 2–3 plans max.

---

## Q3: Are the Phase 2 deltas properly reconciled in-spec?

**Method:** Read the Phase 2 final review deltas (final-review Q5) and searched the spec for the same claims.

**Findings:**

Four Phase 2 deviations surfaced in the final review:

1. **T5 scroll dispatcher correction** — documented inline in the Phase 2 plan; no spec-level impact.
2. **`ScreenSnapshot` four new fields** (`cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`) — spec §4 originally listed only 7 fields; now reflects 12.
3. **`TerminalModes.Codable` conformance** — internal, not on wire, no spec impact needed beyond a note.
4. **`windowTitle` nonisolated snapshot cleanup** — misleading comment documented an intention that wasn't applied. Addressed by follow-up commit `8aeea2d` (re-read `git show` to confirm).

The spec originally read as if none of the Phase 2 growth had happened — `ScreenSnapshot` still had 7 fields in the code block, `AttachPayload` was still presented as future work, etc.

**Action taken:**
- Updated §4 `ScreenSnapshot` code block to include the four Phase 2 additions with a comment marker.
- Added a note that the 12-param init is the trigger for the `TerminalStateSnapshot` sub-struct in the Phase 3 hygiene track.
- Updated §6 "What changes" → "What landed in Phase 1 + Phase 2" and reframed `AttachPayload` as delivered.
- Confirmed via `git show 8aeea2d` that the `windowTitle` cleanup is complete in the code; the spec no longer implies a future cleanup.

---

## Q4: Does the spec adequately warn that Phase 3 cannot break Phase 1/2 wire compat?

**Method:** Searched §6 and the Phasing section for explicit wire-compat constraints.

**Findings:**

The original §6 item 4 mentions the `decodeIfPresent` pattern as a migration path "if daemon + client ever ship on separate cadences" but does not forbid wire-breaking changes in Phase 3. The original cross-phase principles mention compat within a phase boundary but don't constrain future phase boundaries.

**Action taken:** Added an explicit "Phase 3 constraint" sentence in §6 item 4 and in the Cross-phase principles: new fields use `decodeIfPresent`, removal is forbidden. This binds the Phase 3 planner to the Phase 2 wire shape even though Phase 2 technically allowed fields to be bumped.

---

## Q5: Is the Phase 2 test-gap list surfaced in the Phase 3 scope?

**Method:** Cross-referenced the Phase 2 final review's Q7 "behavioral gaps" list against the Phase 3 spec scope.

**Findings:**

The Phase 2 final review identified four test gaps:
1. `AttributeProjection.atlasVariant` invariance against dim/underline/blink.
2. `ScrollbackHistory.tail(0)` — addressed in follow-up commit `8aeea2d`.
3. `restore(from payload:)` clear-before-publish ordering test.
4. `TerminalSession.paste(_:)` end-to-end — addressed in follow-up commit `8aeea2d`.

Two are done. Two remain.

**Action taken:** Added items 1 and 3 to Phase 3 Track B (test gaps). Marked (2) and (4) as already landed in `8aeea2d` so the Phase 3 planner doesn't re-queue them.

---

## Q6: Are there stale forward-references in the spec that should be cleaned?

**Method:** Searched spec for "Phase 3", "Phase 2", "MVP", "deferred" to find stale claims.

**Findings:**

Several lines used "MVP" or "Phase 2 UX detail" language that predated Phase 2 landing:

- Line 322: "bell (0x07): No-op in MVP; visual/audible bell is a Phase 2 UX detail" — bell is delivered.
- Line 388: "`CellStyle` flyweight deferred to Phase 3 — architectural seam noted" — is now conditional, not firm Phase 3.
- Line 466: "blink — Phase 3 — global timer uniform" — correctly labeled but now explicitly bundled with DECSCUSR blink.
- Line 472: "Unicode beyond ASCII: Phase 3" — moved to Phase 4.

**Action taken:** Updated lines 322, 388, 466, 472 to reflect current state. Added the revised annotation dates (2026-05-02) to Appendix A and Appendix B.

---

## Q7: Questions for the human before the Phase 3 plan is written

These are genuinely ambiguous and must be resolved by the human before Phase 3 planning begins. I surfaced each in §8 Phase 3 open questions but am flagging them here so they are not missed:

1. **OSC 52 query path in Phase 3 or Phase 4?** The set path alone is tractable. The query path requires a new daemon surface (client-originated byte injection via XPC) because the pasteboard read happens on the client but the reply must go out through the daemon's PTY primary. I drafted Phase 3 with set-path only. **Human decision: confirm set-only is acceptable for Phase 3, or expand to include query.**

2. **`CellStyle` flyweight trigger.** OSC 8 adds ~16 B to `CellStyle`, doubling scrollback memory pressure. I recommended conditional Phase 3 inclusion based on measurement (cold-attach > 3 MB OR scrollback > 100 MB). **Human decision: is this the right gate, or should flyweight just be in Phase 3 unconditionally?** Unconditional inclusion expands Phase 3 scope meaningfully.

3. **Measurement instrumentation tool.** Track B items 1, 3, and 11 all recommend measurement-before-optimization. I did not pick a tool (`os_signpost` vs. Metal frame capture vs. `MTLCommandBuffer.GPUTime` vs. allocation profiler vs. XCTest measurement blocks). **Human decision: which tool, or planner's choice?**

4. **Scope of OSC 8 URI opening.** `NSWorkspace.open(_:)` handles http(s), file, mailto. The spec did not constrain scheme list. **Human decision: lock the scheme allowlist now, or defer to the plan?**

5. **Plan granularity.** Track A + Track B together may exceed a reasonable single-session plan. **Human decision: one Phase 3 plan, or split into `phase-3-features` and `phase-3-hygiene`?**

6. **Phase 3 test-gap (3) test method.** The ordering invariant for `restore(from payload:)` cannot be unit-tested without a concurrent reader. Options: integration test with a background reader task, `os_signpost` instrumentation, or documented-but-untested. **Human decision: required, or acceptable as "documented, not tested"?**

7. **`iconName` on snapshot.** `ScreenModel` stores `iconName` from `OSC 1` but does not expose it on `ScreenSnapshot`. Originally flagged as dead code in Phase 1. With OSC 8 and OSC 52 on deck, is this the time to expose it on the snapshot (promoting the `windowTitle`-style pattern), or leave it sitting?

---

## Q8: Cross-section consistency of the edits

**Method:** After edits, re-read the spec end-to-end looking for inconsistencies.

**Findings:**

- §1 Summary now says Phase 3 is "revised"; §1 architecture overview still says "Three internal seams change" even though the seams have already been delivered. The prose is accurate about the architecture ("still a single actor with the custom serial-queue executor") but reads as if the change is future work. I decided this is acceptable — the architecture section describes the system in its current form. Leaving as-is.
- Decisions table row 8 now accurately reflects the Phase 3 scope.
- §3 note about `Cell` memory mentions "§8 Phase 3 style-flyweight" — I corrected this to reference Appendix A since flyweight is now conditional.
- §4 snapshot block and §4 prose now agree (12 fields, explicit note about Phase 2 additions, extraction plan tied to Phase 3 hygiene).
- §6 properly marks Phase 1/2 as delivered and Phase 3 as forward.
- §8 three-track structure is the major structural change; consistency maintained.
- Appendix A explicitly splits "Live seams for Phase 3" from "Deferred past Phase 3" — no ambiguity about what is in/out.
- Appendix B notes which items moved into Phase 3.

No residual inconsistencies. Spec is internally coherent.

---

## Summary

The spec review produced seven distinct observations:

1. Phase 3 scope was feature-only; engineering hygiene was missing entirely. **Added Track B with 13 items drawn from the four Phase 2 research docs.**
2. Phase 3 feature scope was too ambitious. **Tightened to OSC 8, OSC 52 set, DECSCUSR, blink, DA1/DA2/CPR, DECOM, DECCOLM, palette UI. Moved Unicode atlas / flyweight / fetchHistory / dirty tracking / Span / mouse / sixel / kitty to Phase 4+.**
3. Phase 2 deltas (four ScreenSnapshot fields, AttachPayload delivered, windowTitle cleanup landed) were not reflected in spec prose. **Updated §4 and §6.**
4. Wire compatibility constraint for Phase 3 was implicit. **Made explicit in §6 and Cross-phase principles.**
5. Test gaps from Phase 2 were documented in research but not in spec. **Added remaining two gaps to Phase 3 Track B.**
6. Several stale lines had "MVP" / "Phase 2 UX" / "Phase 3 deferred" language that was now wrong. **Corrected lines 322, 388, 466, 472.**
7. Seven open questions genuinely need human input before planning. **Captured in §8 Phase 3 open questions and here in Q7.**

The updated spec should give the Phase 3 planner enough signal to sequence work without re-reading all four Phase 2 research docs, provided the human answers the seven open questions first.

---

*Generated by: Phase 3 spec revision pass, 2026-05-02*
