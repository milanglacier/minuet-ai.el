# Version 0.5.4 (2025-04-13)

## Features
- Add option to show error message on minibuffer and improve error message

## Bug Fixes
- Fix overlay positioning when not at the end-of-line

# Version 0.5.3 (2025-04-08)

## Features

- Added `transform` option for OpenAI-FIM-compatible providers.

  This feature enables support for non-OpenAI-FIM-compatible APIs with
  OpenAI-FIM-compatible provider, such as the DeepInfra FIM API. Example
  configurations are available in [recipes.md](./recipes.md).

# Version 0.5.2 (2025-04-03)

This maintenance release focuses on reducing the ELPA tarball size.

## Chores

- Added `.elpaignore` file to exclude unnecessary files from tarball.

# Version 0.5.1 (2025-04-03)

Minuet is now available on GNU ELPA.

## Breaking Changes

- The default service for `openai_compatible` provider is now OpenRouter.

## Documentation

- Updated to note the policy of GNU ELPA. The contribution section has also been
  revised.

# Version 0.5.0 (2025-03-28)

## Breaking Changes

- Modified the Gemini provider's default prompt strategy to use the new **Prefix
  First** structure.
- Other providers will continue to use their previous default prompt
  configurations.

## Features

- Add a new "Prefix-First" prompt structure for chat LLMs.

# Version 0.4.4 (2025-03-10)

## Features

- `minuet-configure-provider` can configure api-key as a named function.

## Documentation

- Update LLM provider example from Fireworks to Openrouter.

## Chore

- Reformat the code using 2 spaces indent.

# Version 0.4.3 (2025-02-18)

## Documentation

- Add recipes for llama.cpp.

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
