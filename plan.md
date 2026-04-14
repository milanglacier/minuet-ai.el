# Implement Emacs Duet next-edit-prediction Mirror

The mirror code for the duet (next-edit-prediction, NES) of the Neovim version
is located under `minuet-ai.nvim/lua/minuet/duet/*.lua`.

## Summary
- Begin execution by writing this plan to `plan.md`, then implement the feature.
- Add `minuet-duet.el` as an optional NES module that depends on `minuet.el` but keeps duet state, prompts, backends, preview rendering, and commands separate from the existing FIM completion path.
- Add `minuet-diff.el` with one minimal internal diff entrypoint used only by duet preview rendering.
- Keep `minuet.el` behavior unchanged; duet may call existing `minuet--...` helpers, but the main completion flow should not be refactored or extended for duet.

## Public API
- New commands: `minuet-duet-predict`, `minuet-duet-apply`, `minuet-duet-dismiss`.
- New query function: `minuet-duet-visible-p`.
- New customization group: `minuet-duet`.
- New defcustoms, using Emacs-style flat variables instead of a nested config object:
  - `minuet-duet-provider`
  - `minuet-duet-request-timeout`
  - `minuet-duet-editable-region-lines-before`
  - `minuet-duet-editable-region-lines-after`
  - `minuet-duet-editable-region-start-marker`
  - `minuet-duet-editable-region-end-marker`
  - `minuet-duet-cursor-position-marker`
  - `minuet-duet-preview-cursor`
- New provider option vars mirroring the Neovim duet defaults:
  - `minuet-duet-openai-options`
  - `minuet-duet-claude-options`
  - `minuet-duet-gemini-options`
  - `minuet-duet-openai-compatible-options`
- New faces:
  - `minuet-duet-add-face`
  - `minuet-duet-delete-face`
  - `minuet-duet-cursor-face`

## Implementation Changes
- In `minuet-duet.el`, keep all duet-specific logic local:
  - Buffer-local state for pending request, preview overlays, source modified tick, editable-region bounds, original editable text, proposed editable text, and predicted cursor character offset.
  - Context builder that uses point-based Emacs buffer access:
    - compute editable region bounds by moving whole lines around point
    - capture four prompt segments as raw substrings
    - store editable region as point bounds, not row/column tuples
  - Prompt/system/few-shot builders that mirror `minuet-ai.nvim` duet templates and provider defaults.
  - Duet response parser that:
    - requires exactly one editable-region start marker and end marker
    - requires exactly one cursor marker inside the editable block
    - trims one leading and one trailing newline inside the editable block, matching the Neovim behavior
    - returns rewritten editable text plus a cursor character offset from the start of that rewritten text
  - Request backends kept in this file:
    - OpenAI/OpenAI-compatible share one base request path
    - Claude and Gemini keep their provider-specific request bodies
    - reuse existing `minuet.el` helpers for API-key lookup, template evaluation, request transforms, streaming decode, Gemini chat conversion, logging, and temporary response collection
    - add `declare-function` entries in `minuet-duet.el` for reused internal helpers so byte-compilation stays clean
  - Prediction lifecycle:
    - `minuet-duet-predict` clears old preview, cancels old duet request, snapshots current tick, builds context, sends one request, discards stale responses, parses the result, and renders preview
    - `minuet-duet-apply` replaces only the editable region and moves point to `region-start + cursor-offset`
    - `minuet-duet-dismiss` clears overlays and pending duet state
    - clear duet preview/state on buffer edits via a duet-local `after-change-functions` hook while a preview or request is active
- In `minuet-diff.el`, expose exactly one helper:
  - `minuet-diff-line-hunks`
  - input: original editable lines and proposed editable lines
  - output: changed hunks as plists with sequence indices and counts
  - implementation: minimal LCS-based line diff, no whitespace options, no general-purpose diff API
- Preview rendering in `minuet-duet.el` should be Emacs-native rather than a literal Neovim port (duet/preview.lua):
  - diff only the editable-region lines
  - mark replaced/deleted source lines with delete-face overlays
  - render inserted/replacement preview lines through overlay strings anchored at line boundaries
  - render the predicted cursor as its own glyph at the proposed location
  - for cursor movement on unchanged text, render only the cursor marker at the mapped point instead of duplicating the whole line
  - if there are no text hunks and no cursor movement, show the same “no text changes” warning behavior

## Test Plan
- Add ERT coverage for `minuet-diff-line-hunks`:
  - no-op
  - pure insertion
  - pure deletion
  - replacement
  - mixed multi-hunk edit
- Add ERT coverage for duet response parsing:
  - valid editable block with one cursor marker
  - missing start/end marker
  - duplicate markers
  - missing cursor marker
  - duplicate cursor marker
  - newline trimming behavior
- Add ERT coverage for context extraction:
  - empty buffer
  - point at beginning/end of buffer
  - editable region clipped by buffer boundaries
  - multi-line region around point
- Add ERT integration-style tests with temp buffers for:
  - apply replacing only the editable region
  - point restored to predicted cursor offset after apply
  - stale prediction rejected after buffer modification
  - dismiss clearing overlays/state
- Run batch load or byte-compile checks for `minuet.el`, `minuet-diff.el`, and `minuet-duet.el`.

## Assumptions
- `minuet-duet.el` stays optional and separate; no default `require` is added to `minuet.el`.
- No README or recipe updates are included in this change.
- No Neovim-style `MinuetDuetRequest*` event parity is added in this first pass.
- Diff indices may be sequence-oriented internally, but all buffer and cursor handling in duet stays point-based and Emacs-native.
- Implementation should prefer `if-let*` and `when-let*`, and avoid splitting duet logic into extra files beyond `minuet-duet.el` and `minuet-diff.el`.
