# Per-buffer timers and a snapshot temp directory for minuet-duet-history

## Context

`minuet-duet-history.el` currently mixes buffer-local state (snapshot files,
tick, process, entries) with three globals that exist only to service it: a
shared repeating idle timer (`minuet-duet-history--timer`), a buffer registry
(`--buffers`) the timer loops over, and a flat file registry (`--temp-files`)
that backstops buffers killed with `inhibit-buffer-hooks`. The user finds this
global/buffer-local mix unclean and proposed:

1. **Per-buffer one-shot chained timers** — each tracked buffer owns its
   timer; the handler schedules a fresh one-shot after each run, so a buffer
   that dies without running its kill hooks simply fails the liveness check
   on the next firing and the chain ends. No recurring timer can leak.
2. **A single temp directory** — all snapshot files live under one lazily
   created directory, deleted recursively at `kill-emacs`, replacing the
   `--temp-files` registry.

Both ideas are sound. **One critical correction to (1):** scheduling the next
timer with `run-with-idle-timer` from inside an idle-timer handler fires it
*immediately* (Emacs is already idle ≥ the delay), producing a busy spin for
the whole idle period. `run-with-idle-timer`'s own docstring warns about this
("Using SECS <= N is not recommended if this function is invoked from an idle
timer, because FUNCTION will then be called immediately"). The fix: schedule
via `timer-activate-when-idle` **without** `dont-wait` — that marks the timer
`triggered` for the current idle period, and `internal-timer-start-idle`
clears the flag when Emacs next becomes idle. This gives exactly the
once-per-idle-period semantics of today's repeating timer. Verified against
timer.el in Emacs 30.2 (`timer--activate`, `timer-activate-when-idle`,
`internal-timer-start-idle`).

Accepted behavior changes:
- Files stranded by hook-inhibited buffer kills persist until Emacs exit
  (previously swept when the last tracked buffer deregistered). Bounded by
  2 × `minuet-duet-history-max-buffer-size` per stranded buffer; rare case.
- The `kill-emacs-hook` stays installed once the temp directory exists
  (previously removed on last deregister).
- `minuet-duet-history-idle-delay` is now read each time the next timer is
  scheduled, so changes take effect at the next burst instead of requiring
  the mode to be disabled in all buffers — a strict improvement; update its
  docstring.

## Changes to `minuet-duet-history.el`

### State

- Remove globals `minuet-duet-history--timer`, `--buffers`, `--temp-files`.
- Add global `minuet-duet-history--directory` (defvar, nil): the snapshot
  temp directory, created lazily.
- Add `defvar-local minuet-duet-history--timer`: this buffer's pending
  one-shot idle timer. Non-nil ⇔ the buffer is tracked (replaces the
  `memq ... --buffers` membership test).

### Temp directory

- `minuet-duet-history--ensure-directory`: return `--directory`, creating it
  with `(make-temp-file "minuet-duet-history-" t)` when nil or when the
  directory was deleted externally (`file-directory-p` check); on creation,
  `add-hook 'kill-emacs-hook #'minuet-duet-history--delete-directory`
  (idempotent).
- `minuet-duet-history--delete-directory` (replaces `--cleanup-all`):
  `(ignore-errors (delete-directory dir t))`, reset the var. No process
  iteration is needed at `kill-emacs` — processes have `:noquery t` and die
  with Emacs; POSIX allows deleting files a running diff still has open.
- `--allocate-files`: create both files inside the directory via
  `(make-temp-file (expand-file-name "snapshot-" (…ensure-directory…)))`;
  drop the registry pushes and the register-immediately rationale comment.
- `--delete-files`: unchanged except dropping the registry maintenance.

### Timer

- `minuet-duet-history--schedule-timer`: schedule this buffer's next idle
  check as a fresh one-shot timer — `timer-create`, `timer-set-function` to
  `--on-timer` with the buffer as arg,
  `(timer-set-idle-time timer minuet-duet-history-idle-delay)`, then
  `(timer-activate-when-idle timer)` (NO dont-wait — see Context; this is
  the load-bearing line, comment it). Store in the buffer-local `--timer`.
  Note: `timer--activate` errors with "Timer already activated" if the same
  object is re-activated while still in `timer-idle-list`, so always create
  a fresh timer object and only call `--schedule-timer` when the previous
  one has fired or been cancelled.
- `minuet-duet-history--cancel-timer`: when the buffer-local `--timer` is
  non-nil, `cancel-timer` it (a no-op if already fired) and set nil.
- `minuet-duet-history--on-timer (buffer)` (replaces `--flush-all`; named
  after the existing `--on-kill-buffer`/`--on-clone` convention):
  - If `buffer` is dead or the mode is off in it (`buffer-local-value`):
    do nothing — no next timer is scheduled, the chain ends; this is the
    no-leak guarantee for hook-inhibited kills and wiped locals.
  - Else `with-current-buffer buffer`: unless a diff is in flight or the
    tick equals the snapshot tick, call `--flush-buffer-safely`; then
    schedule the next timer **only if `minuet-duet-history-mode` is still
    enabled** — the flush may have disabled it via
    `--disable-oversized-buffer`.
- Delete `--flush-all`, `--register`, `--deregister`, `--cleanup-all`.

### Mode / hooks

- Enable branch (final `t` case): replace
  `(minuet-duet-history--register ...)` with
  `(minuet-duet-history--schedule-timer)`.
- Re-enable-with-intact-state branch: condition becomes
  `(and minuet-duet-history--timer minuet-duet-history--snapshot-file
  (file-exists-p ...))`; do not schedule another timer (the existing timer
  chain is live).
- Refusal branches (oversized, missing diff program): replace
  `--deregister` with `--cancel-timer`.
- Disable path: replace `--deregister` with `--cancel-timer`.
- `--on-kill-buffer`: replace `--deregister` with `--cancel-timer`.
- `--on-clone`: also reset the inherited `--timer` to nil (it aliases the
  parent's timer object — reset, never cancel, mirroring the process/file
  handling), then schedule the clone's own timer as part of
  re-registration.
- Update the Commentary (repeating shared timer → per-buffer chained
  one-shot timers; temp-file registry → temp directory) and the
  `minuet-duet-history-idle-delay` docstring (read each time the next
  timer is scheduled).

## Changes to `tests/minuet-duet-history-tests.el`

- `minuet-duet-history-test--with-buffer`: let-bind
  `minuet-duet-history--directory` to nil (instead of the three old
  globals); in the unwind, delete the directory recursively when created.
  The existing inner unwind already disables the mode before the buffer
  dies, which now cancels the buffer's timer.
- Mechanical assertion updates across tests:
  - `(memq (current-buffer) minuet-duet-history--buffers)` →
    buffer-local `minuet-duet-history--timer` non-nil (and, where useful,
    `(memq minuet-duet-history--timer timer-idle-list)`).
  - `minuet-duet-history--temp-files` length/emptiness checks →
    `file-exists-p` on the two snapshot files / `directory-files` counts on
    `--directory`.
  - Calls to `minuet-duet-history--flush-all` (in
    `...-flush-skips-while-in-flight`, `...-clone-registers-for-idle-flush`,
    `...-flush-all-flushes-and-prunes`) →
    `(minuet-duet-history--on-timer <buffer>)`.
- Rewrite lifecycle tests:
  - `minuet-duet-history-timer-lifecycle` → each tracked buffer owns a
    distinct timer in `timer-idle-list`; disabling one buffer cancels only
    its timer; killing the other cancels the last one.
  - `minuet-duet-history-cleanup-all-sweeps-registry` → directory
    lifecycle: lazily created on first enable, files land inside it,
    `--delete-directory` removes it (including stranded files).
  - `minuet-duet-history-flush-all-flushes-and-prunes` → hook-inhibited
    kill: run `--on-timer` on the dead buffer — no error, no next timer
    scheduled (the chain ends), stranded files remain until
    `--delete-directory`.
  - Clone test: additionally assert the clone's timer object differs from
    the base buffer's.
- New test worth adding: after `--on-timer` runs on a live tracked buffer,
  a fresh timer is scheduled (`--timer` non-nil, in `timer-idle-list`, not
  `eq` to the fired one).

## Changes to `benchmarks/minuet-duet-history-benchmarks.el`

- Lines ~250–253 cancel the global `--timer` during cleanup; the mode
  disable now cancels per-buffer timers, so drop or adapt that block (check
  surrounding context when editing).

## Not needed

- `minuet-duet.el` only uses the public `minuet-duet-history-flush` /
  `-prompt-text` — unchanged.
- CHANGELOG: the feature is still in Unreleased and its entry doesn't
  mention the timer topology; no update required.

## Verification

- `make check` — full ERT suite (all four test files).
- `make compile` — byte-compilation must be warning-clean (catches removed
  vars/functions still referenced).
- `make benchmark` — still runs after the cleanup-block change.
- Manual sanity check in a live Emacs (`emacs -Q -L . …`): enable the mode,
  type a burst, idle, confirm one entry; kill the buffer and confirm its
  timer left `timer-idle-list`; confirm `timer-idle-list` never grows while
  idling with an unmodified tracked buffer (the spin regression this plan
  guards against).
