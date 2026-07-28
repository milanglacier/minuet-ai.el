# Review: commit 2952214 — diff duet history via temp-file snapshots and external diff

Reviewed: `295221469e5a46874bda3e38fb1396fc1fe8dfb2` on `feat/recent-edit-history-V2`.
Scope: `minuet-duet-history.el` (full rewrite of snapshot/flush core), tests,
test fixtures, benchmarks, README, plan document.

## Verdict

**Merge-ready.** The rewrite is faithful to the plan, the async state machine is
correct under every interleaving I could construct, and the test suite is
genuinely strong (110/110 pass locally; byte-compile emits no warnings). The
findings below are minor hardening suggestions, none blocking.

## Overview

Replaces the in-elisp snapshot/diff pipeline (whole-buffer line vectors +
`minuet-diff` Myers hunks) with:

- Two per-buffer temp files written via `write-region` (no Lisp string
  allocation), ping-ponging roles between "last snapshot" and "pending".
- An async external `diff -U<n>` whose sentinel strips file headers, enforces
  `minuet-duet-history-max-region-lines` post-hoc from `@@` spans, records the
  entry, and rotates the files.
- A bounded-wait public flush (`minuet-duet-history-flush-timeout`, 0.2 s
  default) so predictions stay effectively synchronous but can never hang.
- Lifecycle coverage for clones, cancellation (eq-guarded sentinel), and
  stranded-file cleanup via a global registry swept on last deregister and at
  `kill-emacs`.

## Verification performed

- `make test`: 110/110 pass (includes the new async fixtures `slow-diff.sh`,
  `diff-exit-2.sh`).
- `make compile`: clean byte-compile of all four `.el` files, no warnings.
- Empirically confirmed that the `:stderr` pipe process inherits `:noquery t`
  from `make-process` (my initial concern that a live stderr pipe could
  trigger kill-buffer/kill-emacs query prompts is **unfounded** — no change
  needed there).

## Correctness analysis (things checked, all sound)

- **Cancellation protocol.** Every cancel site nils `--process` *before*
  `delete-process`, and the sentinel's eq-guard
  (`(eq process (buffer-local-value '--process buffer))`) correctly reduces a
  late sentinel to disposing its own stdout/stderr buffers. Files are owned by
  the buffer lifecycle, never the sentinel — no double-delete or use-after-free
  of file paths is reachable. The exited-but-sentinel-pending case (process no
  longer live at cancel time) also resolves correctly: the guard fails and the
  `unwind-protect` still kills both output buffers.
- **Flush loop.** The `starts < 2` cap makes the "follow-up flush within the
  same deadline" behavior genuinely bounded — a persistently failing diff
  program produces exactly two spawn attempts per call, not a respawn loop.
  Termination conditions (mode disabled mid-wait, process gone, deadline)
  are all checked each iteration. Re-entrant idle-timer firing during
  `accept-process-output` is safe because both `--flush-all` and
  `--start-flush` skip buffers with an in-flight process.
- **`accept-process-output nil 0.005` rationale** (waiting on any process
  rather than the diff process, in short slices) is a known-correct workaround
  for missed exit notifications; the inline comment documents it well.
- **Failure semantics.** Exit ≥ 2 / signal leaves the tick dirty so the burst
  is retried — verified by `flush-retries-after-diff-failure`. Exit 0 (reverted
  burst) rotates without an entry. `span = nil` (binary/garbled output) skips
  but rotates, which is the right call — retrying would loop forever.
- **`--hunk-span`.** Regex is safe against content collisions (diff content
  lines always carry a ` `/`+`/`-` prefix, so `^@@` can only be a header);
  omitted-count-means-1 and zero-count sides are handled and unit-tested; the
  multi-hunk span math (last end − first start per side, max of sides) matches
  the old middle-region semantics up to ≤ 2·context lines of overestimate,
  which the updated docstring discloses.
- **Encoding.** Forcing `utf-8-unix` on both the snapshot write and the
  process coding is the right invariant: both files always agree, and the
  non-ASCII round-trip test (latin-1 buffer that cannot encode `世界`) proves
  the file coding system cannot corrupt entries.
- **`write-region` hygiene.** Binding `write-region-annotate-functions`,
  `write-region-post-annotation-function`, `buffer-file-format`, and
  `write-region-inhibit-fsync`, with `VISIT = 0`, closes the format/annotation
  side-effect holes. `make-temp-file` gives 0600 files in the *local*
  `temporary-file-directory` (safe for TRAMP buffers), and
  `default-directory` is rebound before `make-process` so the diff never
  spawns remotely.
- **Header stripping** removes the temp-path leak from prompts and is asserted
  both at unit level and end-to-end (`flush-strips-file-headers` greps the
  entry for `temporary-file-directory`).
- **Mode lifecycle.** The three-arm enable (intact re-enable / refusals /
  re-init), the fall-through `--delete-files` before re-init, and the
  deregister-sweeps-registry-when-last-buffer-leaves design all hold together;
  the clone path correctly drops aliased process/file locals without touching
  the parent's.

## Findings

### 1. Stranded snapshot files can accumulate while other buffers stay tracked (low–medium)

`minuet-duet-history.el:474-486` — the registry is only swept when the *last*
tracked buffer deregisters (or at `kill-emacs`). When
`kill-all-local-variables` wipes a tracked buffer's locals (manual
`revert-buffer` with `preserve-modes` nil, or a major-mode change) and the
mode re-enables, the old pair of files is unreachable from any buffer-local
variable: the re-init arm's `--delete-files` sees nil vars, so the on-disk
files (containing buffer content) linger in the registry until every tracked
buffer disables. In a long session with the mode continuously enabled
somewhere, repeated revert/mode-change cycles leak two files each. Auto-revert
is unaffected (`preserve-modes` t), which limits real-world impact, but the
files hold user content, so lingering longer than expected is also a mild
privacy issue.

*Suggestion:* store registry entries as `(buffer . file)` conses and
opportunistically sweep entries whose buffer is dead or no longer references
the file — e.g. in `--flush-all`'s prune pass or in the mode's re-init arm.

### 2. Spawn failure after enable retries (and logs) forever (low)

If the diff program disappears *after* the mode is enabled (the
`executable-find` check only runs at enable time), `make-process` in
`--start-flush` signals `file-missing`, `--flush-buffer-safely` logs it, and
the tick stays dirty — so every idle period and every prediction (twice per
flush call, given the `starts < 2` loop) retries and logs again,
indefinitely. The oversized-buffer path disables the mode in the analogous
situation.

*Suggestion:* on a `file-missing`/`file-error` spawn failure, disable the mode
with a user-visible log, mirroring `--disable-oversized-buffer`.

### 3. `--allocate-files` is not exception-safe (very low)

`minuet-duet-history.el:235-244` — if the second `make-temp-file` signals
(disk full, unwritable tmpdir), the first file exists on disk, is stored in
`--snapshot-file`, but was never pushed onto the registry; the enable then
aborts mid-way with the mode variable left t. Pushing each path onto the
registry immediately after its `make-temp-file` (before creating the second)
makes the cleanup paths cover it.

### 4. Repeated logging for undecodable/binary-ish buffers (nit)

The `span = nil` branch logs "no hunks in diff output" on *every* burst in a
buffer whose content makes diff emit `Binary files ... differ`. Rotation is
correct (no retry loop), but the log line repeats per burst. Consider logging
once per buffer or demoting it.

### 5. Timing assertion flake risk (nit, tests)

`minuet-duet-history-flush-bounded-wait` asserts the flush returns within
0.5 s of wall clock with a 0.05 s timeout. The 10× margin is probably fine,
but on a heavily loaded CI runner a GC pause or scheduler hiccup between
`float-time` calls could trip it. If CI ever flakes here, widen the bound
rather than the timeout.

## Test coverage

Strong overall: the async paths (bounded wait, in-flight skip, exit-2 retry),
lifecycle (disable/kill/clone/cleanup-all/stranded-file sweep), re-enable
variants (intact, post-wipe, post-snapshot-deletion), encoding, header
stripping, and both refusal arms are all covered, with fixtures properly
`skip-unless`-guarded for portability.

One gap worth closing: **no test exercises the cancelled-sentinel path** — i.e.
start a `slow-diff.sh` flush, then `minuet-duet-history-clear` (or disable the
mode) while it is in flight, and assert that no entry is ever recorded, the
tick reflects the fresh snapshot, and no ` *minuet-duet-history-diff*` buffers
survive. That is the one branch of the sentinel state machine (eq-guard
mismatch on a live cancel) currently verified only by reading the code.

Minor: exact-string diff assertions (`flush-records-entries`,
`flush-widens-around-narrowing`) are GNU-diff-shaped but keep all counts > 1,
matching the plan's own caution — fine as-is.

## Performance

- The stated benchmark trade-offs are honest and documented in both the commit
  message and the benchmark Commentary: allocation per flush drops ~4×,
  retained snapshot heap goes to ~0, and the whole-rewrite skip path now pays
  a full external diff before discarding (bounded by the 1 MB
  `max-buffer-size`, so single-digit milliseconds — acceptable).
- Binding `minuet-duet-history-flush-timeout` to 30 inside the benchmark
  runner is the correct fix for the truncation/leak hazard the plan identified.
- `--flush-all` now checks tick and in-flight process via `buffer-local-value`
  without selecting buffers — a nice constant-factor win for the idle timer.

## Security / privacy

- Command is built as an argv list (no shell), context count is clamped with
  `max 0`, and `make-temp-file` yields 0600 files — no injection or
  world-readable exposure.
- The disk-privacy trade-off is disclosed in the README with the auto-save
  analogy and an explicit "leave the mode off for sensitive buffers" sentence,
  matching the decision recorded in the plan.
- Temp paths are stripped from prompt entries and tested for.
- Residual note: finding 1 above extends how long content-bearing files can
  persist beyond the documented lifetime.

## Conventions & docs

- Code style, docstring density, section banners, and `minuet--log` usage all
  match the existing file; docstrings explain the *why* (eq-guard ordering,
  the `accept-process-output nil` subtlety) at the right altitude.
- README and Commentary updates accurately describe the new semantics,
  including the "one burst stale" degradation; the two new defcustoms are
  documented with the Windows note the plan called for.
- Plan adherence is essentially exact, including all the sharp edges the plan
  called out (stderr sentinel silencing, omitted-count parsing, clone
  aliasing, benchmark timeout binding).

## Follow-up: cancelled-sentinel test gap closed

The test-coverage gap above has since been addressed with two new tests in
`tests/minuet-duet-history-tests.el`:

- `minuet-duet-history-clear-cancels-in-flight-diff` — starts a
  `slow-diff.sh`-backed flush with a 0.05 s timeout so it returns while the
  diff is in flight, captures the process and its stdout/stderr buffers, then
  calls `minuet-duet-history-clear`. Asserts the process is killed, waits for
  the late sentinel to dispose of both output buffers (which pins down that
  the eq-guarded cancelled branch actually ran, rather than never firing),
  and only then asserts no entry was recorded, the tick matches the fresh
  snapshot, and a follow-up flush records nothing.
- `minuet-duet-history-disable-cancels-in-flight-diff` — same setup, but
  cancels via `minuet-duet-history-mode -1`, additionally asserting both
  snapshot files are deleted alongside the no-entry and no-stray-buffer
  checks.

Both pass; the full suite is 112/112.

## Follow-up: findings 1 and 3 fixed (leftover temp-file handling)

Findings 1 (stranded-file accumulation) and 3 (`--allocate-files` exception
safety) have since been fixed in `minuet-duet-history.el`:

- `minuet-duet-history--temp-files` now stores `(BUFFER . FILE)` conses
  instead of bare paths, so every registered file records its owning buffer.
- New `minuet-duet-history--delete-leftover-files`, called at the end of
  every `--flush-all` pass (i.e. each idle tick): it deletes any registered
  file whose owning buffer is dead, or whose buffer no longer references the
  file through `--snapshot-file`/`--pending-file` (the
  `kill-all-local-variables` wipe case — manual revert, major-mode change).
  Leftover files now live at most one idle period instead of until the last
  tracked buffer deregisters. An entry whose deletion fails (e.g. a
  Windows file lock) is kept and retried on the next pass rather than
  silently dropped.
- Sweep cost is negligible: `buffer-live-p` is O(1) (a field check, not a
  buffer-list scan), and a measured full pass over 1000 registry entries
  takes ~0.3 ms (~0.3 µs/entry) — trivially small next to the `write-region`
  + external diff a flush already performs.
- `--allocate-files` now registers each file immediately after its
  `make-temp-file`, so a failure creating the second file can no longer
  strand the first outside the registry (finding 3).
- `--delete-files` and `--cleanup-all` were adjusted for the new entry shape.

Test updates:

- New `minuet-duet-history-flush-all-deletes-leftover-files`: enables the
  mode, wipes locals with `kill-all-local-variables`, re-enables (fresh pair
  allocated, old pair orphaned on disk), then asserts `--flush-all` deletes
  exactly the old pair and keeps the live one.
- `minuet-duet-history-flush-all-flushes-and-prunes` updated for the new
  behavior: a hookless-dead buffer's files are now deleted by the same flush
  pass while another buffer stays tracked, instead of lingering until the
  last deregister.
- Test cleanup forms updated for the `(buffer . file)` entry shape.

Full suite after the fix: 113/113; byte-compile clean.

## Follow-up: leftover-file fix redesigned as event-driven (no idle scan)

After discussion, the polling design above (a per-idle-tick scan comparing
registry entries against each buffer's file variables) was judged a smell:
it made the global registry depend on buffer-local internals and ran
recurring work to compensate for a gap that can be closed at the source.
It was replaced with fully event-driven cleanup:

- **`change-major-mode-hook` teardown** (`--on-major-mode-change`, added
  buffer-locally on enable): `kill-all-local-variables' runs this hook
  *before* wiping locals (verified empirically), so the mode now disables
  itself while its file/process variables are still intact — files deleted
  and buffer deregistered on the spot. The wipe-orphan class (manual revert,
  major-mode change) no longer exists, rather than being cleaned up later.
- **Prune-time cleanup for hookless deaths**: `--deregister` now deletes a
  dead buffer's registered files (`--delete-dead-buffer-files`). This covers
  buffers killed without `kill-buffer-hook` (`inhibit-buffer-hooks`), which
  no hook can observe — but only when the idle prune actually encounters a
  dead buffer, not as a recurring scan. This case is real, though rare:
  `inhibit-buffer-hooks` does not suppress major-mode hooks (verified
  empirically), so e.g. `prog-mode-hook'-based enabling can fire inside a
  `with-temp-buffer' that calls a major mode without `delay-mode-hooks'.
- The per-tick `--delete-leftover-files` sweep was removed entirely; the
  registry keeps its `(BUFFER . FILE)` shape (needed for prune-time
  ownership) and remains the final safety net at last-deregister and
  `kill-emacs`. The cleanup predicate no longer inspects any buffer-local
  file variables.

Test updates: the wipe test now asserts teardown happens at
`kill-all-local-variables` time (files already gone, buffer deregistered,
before any flush pass); `reenable-after-local-wipe` asserts the buffer left
the tracked list at wipe time; the hookless-death expectations in
`flush-all-flushes-and-prunes` are unchanged (files deleted by the prune).

Full suite after the redesign: 113/113; byte-compile clean.

## Follow-up: prune-time cleanup for hookless deaths dropped (won't pursue)

The prune-time deletion of a dead buffer's files (and with it the
`(BUFFER . FILE)` registry shape) was subsequently judged not worth its
complexity and removed. Rationale:

- The only case it covered is a buffer killed with its hooks inhibited while
  the mode is enabled — which takes an unusual setup to begin with (a
  major-mode hook enabling the mode inside e.g. `with-temp-buffer` without
  `delay-mode-hooks`).
- Serving that case requires the registry to record file ownership, because
  a dead buffer's local variables are unreadable (verified empirically) —
  bare paths cannot be attributed after death.

Final state of the leftover-file handling:

- `--temp-files` is a flat list of paths again; `--delete-dead-buffer-files`
  is gone; `--deregister` is back to its original shape.
- The realistic orphan class (`kill-all-local-variables` wipes) remains fully
  fixed at the source by the `change-major-mode-hook` teardown.
- Hookless deaths fall back to the original backstop: files stay registered
  until the last tracked buffer deregisters or Emacs exits. The trade-off is
  recorded as a won't-pursue note in the `--temp-files` docstring, and the
  `flush-all-flushes-and-prunes` test asserts (and documents) the lingering
  behavior deliberately.
- The per-file registration in `--allocate-files` (finding 3, exception
  safety) is kept.

Full suite after the simplification: 113/113; byte-compile clean.
