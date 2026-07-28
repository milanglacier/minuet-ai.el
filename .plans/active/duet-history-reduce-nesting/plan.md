# Reduce nesting in minuet-duet-history.el

## Context

`minuet-duet-history.el` has several functions with deep nesting of the form
`let → if/when → let(…)`, which is hard to read. The goal is to flatten these
using `if-let*`/`when-let*` (the style already used throughout `minuet.el`),
including the `(_ (condition))` bool-only binding idiom where useful, and —
where the depth comes from `unwind-protect`/`condition-case`/
`with-current-buffer` structure that let-forms can't flatten — by extracting
small helper functions (approved by the user). No behavior changes; all
existing function names and signatures are kept (the test file references
`--start-flush`, `--sentinel`-adjacent state, `--on-timer`, etc.).

Only file modified: `minuet-duet-history.el`.

## Changes

### 1. `minuet-duet-history--cancel-process` (~line 297)

`let → setq → when (and process (process-live-p …))` becomes:

```elisp
(when-let* ((process minuet-duet-history--process))
  (setq minuet-duet-history--process nil)
  (when (process-live-p process)
    (delete-process process)))
```

Equivalent: when the variable is already nil, the original's `setq` was a
no-op. The docstring's "cleared before the process is deleted" ordering is
preserved.

### 2. `minuet-duet-history--write-snapshot` (~line 221)

The outer `let ((tick …))` exists only to return the tick after the write.
Replace with `prog1`, removing one level:

```elisp
(prog1 (buffer-chars-modified-tick)
  (save-restriction
    (widen)
    (let ((coding-system-for-write 'utf-8-unix) …)
      (write-region (point-min) (point-max) file nil 0))))
```

(`write-region` doesn't modify the buffer, so reading the tick first is
equivalent.)

### 3. `minuet-duet-history--start-flush` (~line 324)

Two changes:

- The outer `let ((tick (buffer-chars-modified-tick)))` binds a value used
  only inside the `when` condition — drop the `let` entirely and inline
  `(buffer-chars-modified-tick)` into the condition. The body only uses
  `pending-tick`, never `tick`.
- Extract the `t` branch of the `cond` (pending-snapshot write +
  buffer allocation + `condition-case`-wrapped `make-process`, lines
  348–379) into a new helper, e.g. `minuet-duet-history--start-diff`,
  which keeps its current internals (`let → condition-case → let*` is fine
  once it starts at depth 1). Move the relevant parts of the docstring/
  comments with it.

Result: `--start-flush` becomes `when → cond` with three flat branches.

### 4. `minuet-duet-history--sentinel` (~line 381)

Currently reaches ~8 levels. Extract two helpers, keeping the sentinel
itself as the lifecycle guard:

- `minuet-duet-history--record-result (process stdout stderr)` — the body
  of the `with-current-buffer` block: clears `--process`, binds
  status/code/pending-tick, and runs the existing 3-way `cond`
  (signal/error → log with stderr; exit 0 → rotate; else → record entry
  then rotate). Documented as "called with the tracked buffer current".
- `minuet-duet-history--record-entry (stdout)` — the inner `t`-branch
  `let ((span …)) → cond` (nil span / oversized span / push entry).
  The `let → cond` shape inside it is acceptable and stays.

The sentinel body becomes:

```elisp
(let ((stdout …) (stderr …) (buffer …))
  (unwind-protect
      (when (and (memq (process-status process) '(exit signal))
                 (buffer-live-p buffer)
                 (eq process (buffer-local-value … buffer)))
        (with-current-buffer buffer
          (minuet-duet-history--record-result process stdout stderr)))
    (when (buffer-live-p stdout) (kill-buffer stdout))
    (when (buffer-live-p stderr) (kill-buffer stderr))))
```

Distribute the current docstring between the sentinel (lifecycle/ownership
notes) and the helpers (result-recording notes).

### Explicitly left as-is (not the objectionable pattern)

- `--hunk-span`: `let → while → let` is loop accumulation, not
  `let → if/when → let`.
- `minuet-duet-history-flush`: `condition-case → let → catch → while` — the
  bindings span the retry loop; no let-form can flatten it.
- `minuet-duet-history-prompt-text`: `when → let → cl-loop` — `selected`
  starts nil so it cannot move into `when-let*`.
- `--on-timer`, `--clear`, the `define-minor-mode` body: already flat
  `when/cond` shapes.

## Verification

From the repo root:

1. `make compile` — byte-compile all files cleanly (no new warnings).
2. `make check` — run the full ERT suite, including
   `tests/minuet-duet-history-tests.el`, which exercises `--start-flush`,
   `--on-timer`, `--push-entry`, `--entry-string`, `--hunk-span`, and the
   kill/teardown paths; all referenced names are unchanged.
