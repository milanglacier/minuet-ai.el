# AGENTS.md

## Coding Style

- Prefer clear inline control flow over tiny one-off utility functions. Do not
  introduce a helper when its body is only one or two straightforward lines or
  it is used in only one local place
- Add a helper only when it represents a meaningful concept, is reused, isolates
  nontrivial behavior, or clearly reduces complexity without hiding simple local
  logic.
- Prefer flat control flow over deeper nesting. Use forms such as
  `when-let*`/`if-let*` to bind prerequisites in one level instead of nesting
  `let` -> `when`/`if` -> `let` when the flatter shape stays readable.
