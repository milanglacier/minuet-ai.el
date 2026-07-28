# Duet history: replace the region-lines skip with char-budget hunk truncation

## Motivation

`minuet-duet-history-max-region-lines` (200) predates the external-diff
implementation: it was a cost guard for the in-house elisp diff. Today the
check runs *after* the external diff has already completed, so it bounds no
compute — compute/memory is already bounded by
`minuet-duet-history-max-buffer-size`. What the check still does is
(a) prevent the always-included newest entry from blowing
`minuet-duet-history-max-prompt-chars`, and (b) drop mass edits entirely.

Both jobs are done badly by a line-based unit:

- The span counts unchanged lines *between* hunks, so two one-line edits 300
  lines apart are dropped even though the diff is tiny.
- 150 lines of minified JS passes the check but can be tens of KB, blowing
  the prompt budget anyway.
- Multi-hunk mass edits (reformat, find/replace) vanish entirely instead of
  contributing their head as signal.

minuet-ai.nvim (`lua/minuet/duet/edits.lua`, `truncate_to_hunks`) already
solved this: bound each entry by a char budget and truncate an oversized diff
to the leading whole hunks that fit, dropping the entry only when not even
the first hunk fits (cutting mid-hunk would produce an invalid diff). Port
that behavior for parity; single oversized hunks (large pastes) are still
dropped, same as today.

## Changes

### minuet-duet-history.el

1. **Remove** `minuet-duet-history-max-region-lines` and
   `minuet-duet-history--hunk-span` (V2 branch is unreleased — no obsolete
   alias).
2. **Add** `minuet-duet-history-max-entry-chars`, default 2000 (matches
   nvim's `max_event_chars`).
3. **`minuet-duet-history--entry-string`** takes a BUDGET argument: after
   stripping the `---`/`+++` headers and trailing newline, return the diff
   when it fits, else the leading whole hunks within BUDGET; return nil when
   there are no hunks (binary input) or the first hunk exceeds BUDGET.
   Implemented with a new helper `minuet-duet-history--leading-hunks-end
   START END BUDGET` that scans literal `\n@@` boundaries in the diff
   process buffer, preserving the existing property that oversized diffs
   are never allocated as giant Lisp strings.
4. **`minuet-duet-history--record-entry`** calls it with
   `(min max-entry-chars max-prompt-chars)` — the prompt bound is the analog
   of nvim's `max_total_chars - overhead` cap, needed because the prompt
   builder always includes the newest entry. Single log message on nil
   (covers both no-hunks and first-hunk-over-budget).
5. Style: prefer `if-let*`/`when-let*` over nested `when`→`let`→`when`;
   a `(_ (bool-expr))` binding for a non-binding guard is fine.

### tests/minuet-duet-history-tests.el

- Update the `--entry-string` helper to pass a budget (default: huge).
- Delete the four `hunk-span` tests; add unit tests for truncation:
  fits-unchanged, multi-hunk keeps leading hunks, first hunk over budget →
  nil, no hunks → nil, headers stripped before budgeting.
- Replace `flush-skips-oversized-region` with two integration tests:
  a multi-hunk burst under a small `max-entry-chars` records the leading
  hunk(s) and rotates the snapshot; a single-hunk oversized burst is skipped
  but still rotates the snapshot.

### benchmarks/minuet-duet-history-benchmarks.el

- Replace the `region-lines` binding (read from the removed defcustom) with
  a fixed 200-line block size; both tracked large-diff workloads still
  measure a full external diff whose single oversized hunk is discarded by
  the entry budget — update the commentary accordingly.

### README.md

- Replace the `max-region-lines` bullet with a `max-entry-chars` bullet
  describing truncation; update the benchmark prose ("discarded by the
  limit" → entry budget).

## Verification

`make test` (ERT suite) and byte-compilation clean.
