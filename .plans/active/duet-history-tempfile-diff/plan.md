# Redesign minuet-duet-history.el: temp-file snapshots + external `diff`

## Context

The current edit-history tracker snapshots each buffer as a Lisp line vector (`split-string` of the whole buffer) and diffs in elisp (`minuet-diff-line-hunks` + a custom udiff formatter). Benchmarks show the cost is dominated by allocation/GC (~2.4 MiB alloc per flush, ~1.5 MiB retained per near-cap buffer, occasional ~14 ms GC pauses), not the diff itself. The redesign eliminates Emacs-heap snapshots entirely: snapshots become temp files written with `write-region` (no Lisp string allocation), and diffs are computed by an external `diff -U<n>` run asynchronously via `make-process`. Prediction keeps its effective synchronous semantics through a *bounded* wait on the in-flight process, so the freshest burst is still captured in practice while a wedged diff can never hang prediction.

Decisions settled in discussion: no elisp fallback is kept; `diff` availability is a mode-enable precondition with a defcustom override for Windows; privacy of temp files is accepted (opt-in mode, same precedent as auto-save) but noted in docs; `minuet-duet-history-prompt-text` and the entry format (unified diff) stay as-is; `minuet-diff.el` stays in the repo (minuet-duet.el:829 uses it for preview rendering) — history just stops requiring it.

## Files

- `minuet-duet-history.el` — full rewrite of the snapshot/flush core
- `tests/minuet-duet-history-tests.el` — delete internals tests, rewrite flush tests, add async tests
- `tests/test-helper.el` — host a shared `wait-until` helper (copy of minuet-duet-tests.el:29–37)
- `tests/scripts/` — two tiny fixture scripts (slow diff, exit-2 diff)
- `benchmarks/minuet-duet-history-benchmarks.el` — bind the flush timeout high; Commentary tweak
- `README.md` — Edit History section (~lines 592–650)
- `minuet-duet.el` — **no change** (flush call at :515, prompt-text at :546 keep working)

## 1. minuet-duet-history.el

### Requires / defcustoms
- Drop `(require 'minuet-diff)`.
- Keep all six defcustoms. Update docstrings of `-max-region-lines` (check is now post-hoc on `@@` spans, overestimates by ≤ 2·context lines) and `-diff-context-lines` (becomes the `-U` argument; diff merges touching hunks itself).
- Add `minuet-duet-history-diff-program` (default `"diff"`): invoked as `PROG -U<n> OLD NEW`; must emit unified diffs with exit codes 0 (same) / 1 (differences) / ≥2 (error). Mode refuses to enable when not `executable-find`-able.
- Add `minuet-duet-history-flush-timeout` (default `0.2`): max seconds the public flush blocks waiting for the diff before prediction proceeds with slightly-stale history.

### State
- Delete `--snapshot-lines`. Keep `--timer`, `--buffers`, `--snapshot-tick`, `--entries`.
- New buffer-locals: `--snapshot-file`, `--pending-file` (two-file ping-pong allocated once per buffer at enable — rotation is a variable swap, no per-flush file create/delete), `--process` (in-flight diff process or nil).
- New global `--temp-files`: registry of every allocated temp path, so `kill-emacs` cleanup covers buffers that died with `inhibit-buffer-hooks`.

### Functions
Deleted: `--common-affixes`, `--format-udiff`, `--diff-entry`, `--buffer-lines`.

Snapshot layer:
- `--write-snapshot (file)` — `save-restriction`+`widen`; bind `coding-system-for-write 'utf-8-unix`, `write-region-inhibit-fsync t`, `write-region-annotate-functions nil`, `write-region-post-annotation-function nil`, `buffer-file-format nil`; `(write-region (point-min) (point-max) file nil 0)` (VISIT=0 suppresses the message without visiting side effects). Returns the `buffer-chars-modified-tick` read just before writing.
- `--allocate-files ()` — two `make-temp-file "minuet-duet-history-"` (uses the *local* `temporary-file-directory`, safe for TRAMP buffers); push both onto the registry.
- `--take-snapshot ()` — allocate files if unset; write into `--snapshot-file`; set `--snapshot-tick`.
- `--delete-files ()` — `ignore-errors`-delete both, remove from registry, nil the vars.
- `--cancel-process ()` — stash and nil `--process`, then `delete-process` the stashed one if live (order defeats the sentinel via its eq-guard).

Flush layer:
- `--start-flush ()` (replaces `--flush-buffer`) — guards: mode on, tick dirty, **no in-flight process**; oversized-buffer check first (→ `--disable-oversized-buffer`, unchanged). Write `--pending-file`, capture pending tick. `make-process` with `:command (list prog (format "-U%d" context) snapshot pending)`, `:buffer` a hidden stdout buffer, `:stderr` a separate hidden buffer (silence its pipe sentinel with `#'ignore` — stderr must not pollute stdout or header stripping breaks), `:coding 'utf-8-unix`, `:noquery t`, `:sentinel #'--sentinel`; bind `default-directory` to `temporary-file-directory` (never spawn on a remote host) and `process-connection-type nil`. `process-put` `:minuet-buffer`, `:minuet-pending-tick`, `:minuet-stderr`. Set `--process`.
- `--sentinel (proc _event)` — state machine below.
- `--strip-file-headers (output)` — drop the leading `--- `/`+++ ` lines (they leak temp paths) and the trailing newline.
- `--hunk-span (output)` — scan `@@` headers with `"^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"`; **omitted count means 1** (GNU diff prints `@@ -2 +2 @@` for single-line hunks); return `(max old-span new-span)` where span = last-hunk-start+count − first-hunk-start per side; nil when no hunks match (binary/garbled output).
- `--rotate (pending-tick)` — `cl-rotatef` the two file vars; `--snapshot-tick` ← pending-tick.
- `--push-entry`, `--flush-buffer-safely` (now wrapping `--start-flush`) — unchanged shape.
- `--flush-all` — keep prune/tick-skip logic; also skip buffers with a live `--process`.

Sentinel state machine (IDLE ↔ IN-FLIGHT per buffer):
```
on exit/signal:
  guard: (buffer-live-p buf) ∧ (eq proc buffer's --process)   ; else: cancelled/dead — dispose io buffers only
  with-current-buffer buf:
    --process ← nil
    signal or exit ≥ 2 → log (with stderr); NO rotate, tick untouched → next idle retries
    exit 0             → rotate(ptick)                        ; reverted burst, no entry
    exit 1             → span ← --hunk-span(stdout)
                         span nil                → log; rotate          ; binary/unparseable
                         span > max-region-lines → log skip; rotate
                         else                    → push stripped entry; rotate
  finally: kill stdout/stderr buffers
```
Cancellation protocol everywhere (clear/disable/kill-buffer): nil the var first, then `delete-process` — the late sentinel sees the eq mismatch and only cleans its buffers. Files are owned by the buffer lifecycle, never by the sentinel.

Public API:
- `minuet-duet-history-flush` — bounded-wait **loop**: `deadline = float-time + flush-timeout`; loop { if no in-flight ∧ dirty → `--flush-buffer-safely`; exit when no in-flight or past deadline; `accept-process-output --process 0.05`, re-reading the var each iteration }. The loop shape means that if edits arrived after the in-flight process's pending tick, a second flush starts within the same deadline — the freshest burst is captured. Never signals. Note `accept-process-output` can run the idle timer reentrantly; the "skip when in-flight" guard in `--flush-all`/`--start-flush` makes that safe.
- `minuet-duet-history-clear` — keep oversize branch; else `--cancel-process`, reset entries, `--take-snapshot` (rewrite snapshot file in place).
- `minuet-duet-history-prompt-text` — **unchanged**.

Lifecycle:
- `--on-clone` — the clone inherits buffer-locals that alias the parent's files/process: `setq`-local `--process` nil (do **not** delete-process — it's the parent's), nil both file vars, then `--take-snapshot` (fresh files) + `--register`. Inherited entries kept (matches current behavior).
- `--register` / `--deregister` — additionally add/remove `kill-emacs-hook` → `--cleanup-all` alongside the timer.
- `--cleanup-all ()` — new: cancel processes in live tracked buffers, then delete every path left in the registry (covers hookless-dead buffers).
- `--on-kill-buffer` — `--cancel-process`, `--delete-files`, deregister.
- Mode definition:
  - New refusal arm after the oversize one: `(not (executable-find minuet-duet-history-diff-program))` → set mode nil, deregister, `minuet--log` with message-p t (mirror lines 378–386).
  - Intact-state re-enable arm: condition becomes `(and (memq buf --buffers) --snapshot-file (file-exists-p --snapshot-file))`; the fall-through re-init must `--delete-files` first to drop stale registry entries.
  - Disable arm: additionally `--cancel-process` + `--delete-files`; drop the `--snapshot-lines` reset.

## 2. Tests

Infrastructure:
- Move the bounded-wait helper (minuet-duet-tests.el:29–37) into test-helper.el as a shared `wait-until`.
- Extend `minuet-duet-history-test--with-buffer` (tests:19–30): wrap body so the temp buffer disables the mode in an unwind step — `with-temp-buffer` uses `inhibit-buffer-hooks`, so without this every test leaks two temp files and possibly a live process.
- Add `minuet-duet-history-test--flush`: let-bind `flush-timeout` to ~5 s and call the public flush, so flush-behavior tests stay synchronous-looking.

Delete (~12): the five `--common-affixes` tests, the formatter tests via `test--udiff`, and that helper — they unit-test removed internals.

Keep: `push-entry-bounded`, the four prompt-text tests, the chat-input tests, oversized-buffer refusal tests, `timer-lifecycle`, `predict-flushes-and-includes-history` (works via the public flush).

Rewrite (mostly mechanical `--flush-buffer` → `test--flush`): flush-records-entries, ignores-reverted-edit, skips-clean-buffer, skips-oversized-region (observable behavior identical: no entry, snapshot rotated), disables-on-oversized-buffer, widens-around-narrowing, sees-silent-modifications, multi-hunk-entry, reenable-keeps-history, reenable-after-local-wipe (assert on `--snapshot-file`/`file-exists-p` instead of `--snapshot-lines`), flush-api-never-signals (mock `--start-flush`), clear tests (also assert file deletion on the oversize path), clone + flush-all tests (`wait-until` entry counts after `--flush-all`, which now only *starts* processes). Caution on exact-string assertions: GNU diff omits `,1` counts (`@@ -2 +2 @@`) — prefer regexps except where all counts are >1.

New (~11): header stripping (no `---`/`+++`, no temp paths in entries); `--hunk-span` unit tests (multi-hunk, omitted-count, zero-count `-1,0`, hunkless → nil); missing diff program → mode stays off, nothing registered/allocated; exit-2 fixture → no entry, tick stays dirty, real diff then succeeds; bounded wait with a sleeping fixture → flush returns promptly, entry arrives later via sentinel; in-flight skip → no second process spawned; clone file separation + independent flush + clone disable deletes only its files; non-ASCII round-trip (latin-1 buffer with `héllo / 世界`); cleanup on disable and kill (files gone, process dead); `--cleanup-all` empties registry; re-enable after external snapshot deletion re-initializes. Fixture scripts in `tests/scripts/` (`slow-diff.sh`, `diff-exit-2.sh`), guarded by `skip-unless`.

## 3. Benchmarks

- Workloads already call the public flush — correct entry point. **Let-bind `minuet-duet-history-flush-timeout` to a large value (e.g. 30)** around the run: otherwise the 0.2 s cap truncates the measured work and leaks an in-flight process into the next repetition.
- Update Commentary: "whole rewrite: tracked/skip" now measures write + full external diff + post-hoc skip (no early affix bail); alloc-MiB now mostly measures stdout strings.

## 4. Docs

- Commentary (minuet-duet-history.el:25–37): snapshots are temp files via `write-region`; diffs by an external program, async; build-context does a bounded synchronous wait and proceeds with slightly-stale history past the deadline.
- README Edit History (~592–650): rewrite the "Tracking is lightweight" paragraph; replace "roughly doubling that buffer's memory footprint" with "each tracked buffer keeps two snapshot files in `temporary-file-directory`" (mention the disk-privacy tradeoff in one sentence, same class as auto-save); document `minuet-duet-history-diff-program` (Windows note) and `minuet-duet-history-flush-timeout`; adjust the benchmark description.

## Verification

1. `make test` — full ERT suite in batch mode.
2. `make benchmark` — confirm alloc MiB/run and retained KiB drop sharply vs the numbers on record (8.5 ms / 2.4 MiB "one flush"; +1469 KiB enable), wall time comparable.
3. Byte-compile + checkdoc via the Makefile's compile target — no new warnings.
4. Manual smoke test: enable the mode in a real buffer, type a burst, wait for idle, `M-x minuet-duet-history-prompt-text` shows a clean entry (no temp paths); check `temporary-file-directory` for exactly two `minuet-duet-history-` files per tracked buffer, gone after disabling.
