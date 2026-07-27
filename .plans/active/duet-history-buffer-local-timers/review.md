# Review: commit a597108 — make duet history tracking state fully per-buffer

Reviewed: `a5971085f35ac1bf119f02927b59742c4f6d6bae` on
`feat/recent-edit-history-V2`.

Scope: `minuet-duet-history.el`, its timer and snapshot lifecycle tests, the
benchmark cleanup change, the implementation plan, and related user-facing
documentation.

## Verdict

**Changes requested.** The per-buffer timer chain itself is sound: using a
fresh one-shot timer and activating it without `dont-wait` avoids both
duplicate chains and the same-idle-period busy loop, and the clone, disable,
local-wipe, and hook-inhibited-death paths are handled correctly. Two cleanup
paths still need isolation/cross-platform hardening; the README also retains
the old timer topology.

## Verification performed

- `make check`: 114/114 tests pass.
- `make compile`: clean byte-compilation with no warnings.
- `make benchmark`: completes successfully.
- Checked the scheduling logic against Emacs 30.2 `timer.el`
  (`timer--activate`, `timer-activate-when-idle`, and
  `timer-event-handler`).
- Reproduced the interactive benchmark issue by keeping an unrelated tracked
  buffer alive while running a reduced benchmark: afterwards its mode and
  timer were still live, but its snapshot directory and files had been
  deleted, and a subsequent flush remained dirty without recording an entry.

## Findings

### 1. [P2] Cancel live diffs before deleting the session directory

`minuet-duet-history.el:252-259` — on native Windows, if Emacs exits while a
configured diff process still has either snapshot open, `kill-emacs-hook` runs
before Emacs tears down subprocesses and `delete-directory` cannot unlink the
open file. `ignore-errors` then hides the failure and the directory variable is
cleared, so the content-bearing snapshot directory survives shutdown. The
previous `minuet-duet-history--cleanup-all` canceled every in-flight diff
before deleting its files; preserve equivalent cancellation for Minuet-owned
processes before the recursive deletion (and avoid discarding the directory
path when deletion fails).

### 2. [P2] Isolate benchmark snapshot cleanup from live buffers

`benchmarks/minuet-duet-history-benchmarks.el:252-254` — when
`minuet-duet-history-benchmark-run` is invoked interactively in an Emacs
session that already has tracked buffers, the benchmark reuses the global
`minuet-duet-history--directory`, then its unwind cleanup recursively deletes
those unrelated buffers' snapshots and sets the shared variable to nil while
their modes and timers remain enabled. Their later flushes repeatedly fail
until tracking is explicitly re-enabled. Dynamically bind an isolated
directory for the whole benchmark run, as the test helper does, or otherwise
delete only a directory created and owned by this run.

### 3. [P3] Update the README's obsolete shared-timer description

`minuet-duet-history.el:29-35` — the updated Commentary correctly describes
per-buffer chained one-shot timers and a shared session directory, but
`README.md:602-605` still tells users that tracking uses one shared idle timer.
Update the Edit History overview so the documented lifecycle and performance
model match this rewrite.

## Additional correctness notes

- `minuet-duet-history--schedule-timer` creates a new timer before each
  activation and cancels the buffer-local predecessor, so re-enable and manual
  callback paths cannot create parallel chains.
- The no-`dont-wait` activation is load-bearing and correct: the successor is
  marked triggered for the current idle period and becomes eligible only when
  Emacs next starts idling.
- The timer callback rechecks liveness and the mode before selecting the
  buffer, and rechecks the mode after flushing; this correctly ends chains for
  hook-inhibited deaths and for size-cap auto-disable.
- Resetting, rather than canceling, the inherited timer in an indirect clone
  avoids touching the parent and gives the clone independent files and a timer.
- Orderly disable, kill, and major-mode-change paths cancel the process and
  timer and delete both files. The accepted hook-inhibited-kill trade-off is
  bounded per dead buffer and covered by the session-directory sweep.

## Test coverage

Coverage of the new topology is strong: distinct timers per buffer, selective
cancellation, fresh-timer rescheduling, clone independence, local-variable
wipes, size refusals, and dead-buffer chain termination are all asserted. The
two functional findings above are not covered: shutdown cleanup is only tested
with no in-flight process, and benchmark cleanup is only run in an otherwise
isolated batch Emacs.

## Fix summaries

### 1. [P2] Shutdown cleanup — resolved

Each asynchronous diff now records the snapshot directory it owns. The
session-directory sweep cancels only live diffs associated with the directory
being removed, clearing each buffer's process slot before cancellation so its
late sentinel remains harmless. Recursive deletion happens only after those
processes are stopped, and the directory variable is cleared only on success;
if cleanup raises an error, the path is retained for a later retry.

Regression coverage verifies that cancellation occurs before
`delete-directory`, that the owner state and process are cleared, and that a
simulated deletion failure preserves the directory path.

### 2. [P2] Benchmark snapshot isolation — resolved

`minuet-duet-history-benchmark-run` now dynamically binds a fresh snapshot
directory for the entire run. Its unwind cleanup therefore sweeps only
benchmark-owned snapshots and cannot remove files belonging to unrelated
tracked buffers.

The regression test runs a reduced benchmark alongside an existing tracked
buffer, then verifies that the buffer's directory, two snapshot files, mode,
and timer remain intact and that a subsequent edit still flushes into history.

### 3. [P3] Shared-timer documentation — resolved

The README Edit History overview now describes the implemented topology:
every tracked buffer owns a one-shot idle timer that detects modification-tick
changes and schedules that buffer's next check.

### Verification after fixes

- `make check`: 117/117 tests pass.
- `make compile`: clean byte-compilation with no warnings.
- `make benchmark`: all production-sized benchmark scenarios complete
  successfully.
- `git diff --check`: clean.

## Follow-up adjustment

At maintainer request, the benchmark module is no longer loaded by the ERT
suite and the benchmark-specific integration test described above has been
removed. The reason for dynamically isolating the benchmark directory is
documented inline beside the binding instead. The two shutdown-cleanup
regressions remain. After this adjustment, `make check` passes 116/116 tests
and `make benchmark` still completes successfully.

## Follow-up decision: retain the original shutdown cleanup

At maintainer request, the directory-owned process tagging, process
cancellation helper, and two related regression tests have been removed.
`minuet-duet-history--delete-directory` again uses the original simple
recursive deletion and relies on `:noquery` diff processes dying with Emacs.
Its docstring now acknowledges that native Windows may refuse to delete an
open snapshot and records that this behavior is untested because no Windows
machine is available. Accordingly, finding 1's Windows cleanup risk is
accepted rather than resolved.

After this decision, `make check` passes 114/114 tests, byte-compilation is
clean, and `make benchmark` completes successfully.

## Next-round review: current HEAD `1bba188`

Reviewed: `1bba188f8f979c1c5ec20c536232d7e24276de36` on
`feat/recent-edit-history-V2`, including the follow-up benchmark isolation and
documentation changes.

### Verdict

**Changes requested.** The per-buffer timer chain and normal enable, disable,
clone, and teardown paths remain sound, and the benchmark no longer deletes
snapshots belonging to buffers that were already tracked when it started.
Two shared-directory lifecycle cases still break recovery or cleanup.

### Verification performed

- `make check`: 114/114 tests pass.
- `make compile`: clean byte-compilation with no warnings.
- `make benchmark`: all production-sized scenarios complete successfully.
- `git diff --check`: clean.
- Reproduced deletion of the session directory beneath an enabled buffer:
  repeated public flushes leave the modification tick dirty and record no
  entry.
- Reproduced shutdown inside the benchmark's dynamic directory binding: the
  benchmark directory is removed, but the pre-existing live session directory
  and its two snapshots remain after Emacs exits.

### Findings

#### 1. [P2] Reallocate snapshots when the shared directory disappears

`minuet-duet-history.el:245-248` — if a temp cleaner or the user removes the
session directory while an already-enabled buffer remains live, this recovery
check is never reached for that buffer: `--take-snapshot` sees two non-nil path
variables and does not allocate again. Every idle or prediction flush then
tries `write-region` below the missing parent, logs an error, leaves the tick
dirty, and repeats indefinitely; creating a replacement directory for a later
buffer does not repair the old paths. Detect the missing directory/snapshot
state before flushing and re-baseline each affected live buffer.

#### 2. [P2] Preserve the outer directory for shutdown during benchmarks

`benchmarks/minuet-duet-history-benchmarks.el:204` — if the interactive
benchmark is run while ordinary buffers are tracked and Emacs exits before the
benchmark returns, this dynamic binding shadows the live session directory
while `kill-emacs-hook` runs. The hook deletes only the benchmark directory
(or nothing before one is created), so the original content-bearing directory
survives process exit. Keep the outer directory reachable by shutdown cleanup,
or isolate benchmark ownership without dynamically hiding state consumed by
the global exit hook.

### Additional notes

- The previously reported README mismatch is fixed.
- The normal benchmark unwind now isolates its own snapshots correctly.
- The native-Windows in-flight shutdown behavior remains an explicitly
  accepted risk from the preceding review and is not repeated as a new
  finding here.

## Fix summaries for the next-round findings

### 1. [P2] Missing shared-directory recovery — resolved

Snapshot state is now validated before it is reused: the shared directory and
both buffer-local snapshot files must still exist, with both paths naming
regular files.

`minuet-duet-history--take-snapshot` discards stale paths and allocates fresh
files when this invariant is broken. Before a dirty buffer starts a diff, it
uses that path to re-baseline its current contents. The unavailable burst
cannot be reconstructed after its baseline has been deleted, but earlier
in-memory history entries are retained, the snapshot tick becomes clean, and
later edits are recorded normally.

Regression coverage deletes the session directory beneath an enabled buffer
and verifies the new directory, files, retained history, unchanged timer
chain, and subsequent successful diff. A second test covers two live buffers:
after the first creates the replacement directory, the second independently
replaces its paths from the deleted directory and joins the new one.

### 2. [P2] Benchmark shutdown directory ownership — resolved

The benchmark now reuses the normal session snapshot directory without
dynamically binding `minuet-duet-history--directory`. Each measured case
already disables its own buffer in an unwind and thereby deletes only that
buffer's two files, so the benchmark's outer recursive directory sweep has
been removed. The shared directory remains owned by the normal
`kill-emacs-hook`, which can now always see and remove the live session
directory if Emacs exits during the benchmark.

Per the earlier maintainer decision, the benchmark module remains outside the
ERT suite. A reduced interactive benchmark was run beside an existing tracked
buffer and left its directory, files, mode, and timer intact. A forced
`kill-emacs` from inside the benchmark confirmed that the pre-existing
content-bearing directory was removed and the global directory state cleared.

### Verification after fixes

- `make check`: 116/116 tests pass.
- `make compile`: clean byte-compilation with no warnings.
- `make benchmark`: all production-sized scenarios complete successfully.
- Reduced interactive benchmark alongside a tracked buffer:
  `live-state-after-benchmark=t`.
- Forced shutdown from inside the benchmark:
  `shutdown-live-directory-exists=nil shared-directory=nil`.
- `git diff --check`: clean.
