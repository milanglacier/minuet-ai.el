# Version 0.7.0 (2025-12-11)

## Breaking Changes

- Default value for `minuet-before-cursor-filter-length` has been changed to `2`

## Features

- completion: Preserve remaining suggestion when using
  `minuet-accept-suggestion-line` for continuous suggestion acceptance
- claude: Change default max tokens to 256.
- claude: Update default model to `claude-4.5-haiku`.

## Fixes

- display: Keep user selected index when displaying more results (#47).
- display: Keep completion items order when new items arrived (#46).

# Version 0.6.0 (2025-08-11)

## Breaking Change

- Improve completion filtering with before/after context:
  - Refactors the completion filtering logic to be based on the longest common
    match.
  - Add a new `minuet-before-cursor-filter-length` config option to trim
    duplicated prefixes from completions based on the text before the cursor.
- Change default few-shot example: The default few-shot example has been updated
  to require the AI to combine information from before and after the cursor to
  generate the correct logic.
- Update default system prompt: The system prompt is refined to be more concise
  and provide clearer instructions to the AI on handling various completion
  scenarios like code, comments, and strings.

## Other

- Updated Gemini Authentication: Switched to using the `x-goog-api-key` header
  for Gemini API requests to align with upstream changes.

# Version 0.5.5 (2025-07-24)

This is primarily a maintenance release with minor feature updates and
improvements.

## Features

- Configurable Endpoints for Gemini and Claude: Users can now specify custom API
  endpoints for Gemini and Claude providers.
- The `chat-input-template` can now be a list of strings, which will be
  constructed into multi-turn conversations, allowing for more organized and
  complex prompt structures.
- Added `minuet-set-nested-plist` for easier manipulation of nested plists in
  configurations.
- The default model for the `openai-compatible` provider is now
  `devstral-small-2505`.
- The default model for the `openai` provider has been updated to
  `gpt-4.1-mini`.

## Fixes

- Switched from `delete-process` to sending a `SIGTERM` signal to gracefully
  cancel in-flight requests.

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
