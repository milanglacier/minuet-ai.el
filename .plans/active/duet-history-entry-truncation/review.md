# Review: duet history entry truncation

Reviewed: `13d9c3a36274` on `feat/recent-edit-history-V2`.

Scope: `minuet-duet-history.el`, the new hunk-truncation tests and benchmark
workload, and the related plan and documentation.

## Verdict

**One change requested.** The hunk-truncation algorithm is coherent, and the
default test suite, byte-compilation, and benchmark pass. The buffer-local
entry budgets must be captured while the tracked buffer is current. No change
is needed to support undersized inputs for the pressure-test benchmark.

## Findings and decisions

### 1. [P2] Read entry budgets before switching buffers — accepted

`minuet-duet-history.el:433-436` — when either budget option is buffer-local,
evaluating the budget expression with the temporary STDOUT buffer current uses
the global defaults instead of the tracked buffer's values. This can record an
entry larger than the tracked buffer's local prompt budget, after which the
newest-entry rule includes it despite that local cap.

This finding makes sense. Capture the buffer-local values of
`minuet-duet-history-max-entry-chars` and
`minuet-duet-history-max-prompt-chars` while the tracked buffer is current,
before entering the STDOUT buffer, and pass the resulting budget to the entry
parser.

### 2. [P3] Reject line counts too small for the scattered workload — no change

`benchmarks/minuet-duet-history-benchmarks.el:110-113` — a sufficiently small
`MINUET_BENCH_LINES` value can make the fixed scattered-edit range extend
outside the generated buffer.

No fix is needed. This benchmark is intended for pressure testing, and the
line-count override is expected to provide a workload large enough for the
configured scattered edits. Scaling the workload or validating small
line-count values is outside the intended benchmark use.

## Fix summaries

### 1. [P2] Buffer-local entry budgets — resolved

`minuet-duet-history--record-entry` now computes the effective entry budget
while the tracked buffer is current, before switching to the diff process's
STDOUT buffer. Both `minuet-duet-history-max-entry-chars` and
`minuet-duet-history-max-prompt-chars` therefore honor buffer-local values
during recording.

A regression test independently makes each option buffer-local while leaving
a larger default visible in STDOUT, then verifies that the recorded entry is
truncated at the tracked buffer's smaller budget.

### 2. [P3] Undersized scattered benchmark workloads — unchanged

Per the decision above, no line-count validation or workload scaling was added
to the pressure-test benchmark.

### Verification after the fix

- `make check`: 118/118 tests pass.
- `make compile`: clean byte-compilation with no warnings.
- `make benchmark`: all default production-sized scenarios complete
  successfully.
