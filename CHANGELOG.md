# Version 0.4.3 (2025-02-18)

## Documentation

- Added recipes for llama.cpp.

# Version 0.4.2 (2025-02-13)

## Breaking Changes
- Change claude default model to haiku-3.5.

## Features
- Add command `minuet-configure-provider`.

## Bug Fixes
- Ensure overlay is put after cursor.

# Version 0.4.1 (2025-02-10)

## Bug Fixes

- Fix minuet version.

# Version 0.4.0 (2025-02-10)

## Breaking Changes

- Remove deprecated `minuet-completion-in-region` command.
- Change default gemini model to gemini-2.0-flash.
- Change default debounce delay to 0.4 seconds.

## Features

- Add consult support for `minuet-complete-with-minibuffer`.

# Version 0.3.0 (2025-01-26)

## Breaking Changes

- Change default context window to 16000.

## Features

- Add numeric prefix support to minuet-accept-suggestion-line.
- Add chat input template for chat-based LLMs.
- Truncate incomplete lines at window boundaries for chat input.

## Bug Fixes

- Ensure symbol-value is only called on symbols in `minuet--eval-value`.

## Refactoring

- Update prompt system for FIM models.

# Version 0.2 (2025-01-19)

## Breaking Changes

- Replace `minuet-completion-in-region` with `minuet-complete-with-mini-buffer`.

## Features

- API key can now be customized via a function.
- Add `minuet-active-mode` for better keybinding management.

# Version 0.1 (2025-01-13)

- Initial release.
