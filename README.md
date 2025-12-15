- [Minuet](#minuet)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start: LLM Provider Examples](#quick-start-llm-provider-examples)
  - [Ollama Qwen-2.5-coder:3b](#ollama-qwen-25-coder3b)
  - [OpenRouter Kimi-K2](#openrouter-kimi-k2)
  - [Llama.cpp Qwen-2.5-coder:1.5b](#llamacpp-qwen-25-coder15b)
- [API Keys](#api-keys)
- [Selecting a Provider or Model](#selecting-a-provider-or-model)
  - [Understanding Model Speed](#understanding-model-speed)
- [Prompt](#prompt)
- [Configuration](#configuration)
  - [minuet-provider](#minuet-provider)
  - [minuet-context-window](#minuet-context-window)
  - [minuet-context-ratio](#minuet-context-ratio)
  - [minuet-request-timeout](#minuet-request-timeout)
  - [minuet-show-error-message-on-minibuffer](#minuet-show-error-message-on-minibuffer)
  - [minuet-add-single-line-entry](#minuet-add-single-line-entry)
  - [minuet-n-completions](#minuet-n-completions)
  - [minuet-auto-suggestion-block-predicates](#minuet-auto-suggestion-block-predicates)
  - [minuet-auto-suggestion-debounce-delay](#minuet-auto-suggestion-debounce-delay)
  - [minuet-auto-suggestion-throttle-delay](#minuet-auto-suggestion-throttle-delay)
- [Provider Options](#provider-options)
  - [OpenAI](#openai)
  - [Claude](#claude)
  - [Codestral](#codestral)
  - [Gemini](#gemini)
  - [OpenAI-compatible](#openai-compatible)
  - [OpenAI-FIM-Compatible](#openai-fim-compatible)
    - [Non-OpenAI-FIM-Compatible APIs](#non-openai-fim-compatible-apis)
- [Troubleshooting](#troubleshooting)
- [Contributions](#contributions)
- [Acknowledgement](#acknowledgement)

# Minuet

[![GNU ELPA badge][gnu-elpa-badge]][gnu-elpa-link]
[![MELPA badge][melpa-badge]][melpa-link]

[gnu-elpa-link]: https://elpa.gnu.org/packages/minuet.html
[gnu-elpa-badge]: https://elpa.gnu.org/packages/minuet.svg
[melpa-link]: https://melpa.org/#/minuet
[melpa-badge]: https://melpa.org/packages/minuet-badge.svg

Minuet: Dance with LLM in Your Code 💃.

`Minuet` brings the grace and harmony of a minuet to your coding process. Just
as dancers move during a minuet.

# Features

- LLM-powered code completion with dual modes:
  - Specialized prompts and various enhancements for chat-based LLMs on code
    completion tasks.
  - Fill-in-the-middle (FIM) completion for compatible models (DeepSeek,
    Codestral, and some Ollama models).
- Support for multiple LLM providers (OpenAI, Claude, Gemini, Codestral, Ollama,
  Llama.cpp and OpenAI-compatible providers)
- Customizable configuration options
- Streaming support to enable completion delivery even with slower LLMs
- Accept completions continuously, one line at a time, so longer suggestions
  can be pulled in incrementally.
- When your typed text matches the start of a suggestion, Minuet keeps the
  completion in sync of your typed text instead of clearing it, to avoid unnecessary
  LLM requests and conserving resources.

**With minibuffer frontend**:

Note: Previewing insertion results within the buffer requires the `consult`
package.

![example-completion-in-region](./assets/minuet-completion-in-region.jpg)

**With overlay ghost text frontend**:

![example-overlay](./assets/minuet-overlay.jpg)

https://github.com/user-attachments/assets/04716eab-9acc-46f4-a47d-d6c763eca4c2

<!-- The link above is a showcase video for the virtual text feature, hosted -->
<!-- externally on GitHub. -->

# Requirements

- emacs 29+ compiled with native JSON support (verify with `json-available-p`).
- plz 0.9+
- dash
- An API key for at least one of the supported LLM providers

# Installation

`minuet` is available on ELPA and MELPA and can be installed using your
preferred package managers.

```elisp

;; install with package.el
(package-install 'minuet)
;; install with straight
(straight-use-package 'minuet)

(use-package minuet
    :bind
    (("M-y" . #'minuet-complete-with-minibuffer) ;; use minibuffer for completion
     ("M-i" . #'minuet-show-suggestion) ;; use overlay for completion
     ("C-c m" . #'minuet-configure-provider)
     :map minuet-active-mode-map
     ;; These keymaps activate only when a minuet suggestion is displayed in the current buffer
     ("M-p" . #'minuet-previous-suggestion) ;; invoke completion or cycle to next completion
     ("M-n" . #'minuet-next-suggestion) ;; invoke completion or cycle to previous completion
     ("M-A" . #'minuet-accept-suggestion) ;; accept whole completion
     ;; Accept the first line of completion, or N lines with a numeric-prefix:
     ;; e.g. C-u 2 M-a will accepts 2 lines of completion.
     ("M-a" . #'minuet-accept-suggestion-line)
     ("M-e" . #'minuet-dismiss-suggestion))

    :init
    ;; if you want to enable auto suggestion.
    ;; Note that you can manually invoke completions without enable minuet-auto-suggestion-mode
    (add-hook 'prog-mode-hook #'minuet-auto-suggestion-mode)

    :config
    ;; You can use M-x minuet-configure-provider to interactively configure provider and model
    (setq minuet-provider 'openai-fim-compatible)

    (minuet-set-optional-options minuet-openai-fim-compatible-options :max_tokens 64))

    ;; For Evil users: When defining `minuet-ative-mode-map` in insert
    ;; or normal states, the following one-liner is required.

    ;; (add-hook 'minuet-active-mode-hook #'evil-normalize-keymaps)

    ;; This is *not* necessary when defining `minuet-active-mode-map`.

    ;; To minimize frequent overhead, it is recommended to avoid adding
    ;; `evil-normalize-keymaps` to `minuet-active-mode-hook`. Instead,
    ;; bind keybindings directly within `minuet-active-mode-map` using
    ;; standard Emacs key sequences, such as `M-xxx`. This approach should
    ;; not conflict with Evil's keybindings, as Evil primarily avoids
    ;; using `M-xxx` bindings.

```

# Quick Start: LLM Provider Examples

## Ollama Qwen-2.5-coder:3b

<details>

```elisp
(use-package minuet
    :config
    (setq minuet-provider 'openai-fim-compatible)
    (setq minuet-n-completions 1) ; recommended for Local LLM for resource saving
    ;; I recommend beginning with a small context window size and incrementally
    ;; expanding it, depending on your local computing power. A context window
    ;; of 512, serves as an good starting point to estimate your computing
    ;; power. Once you have a reliable estimate of your local computing power,
    ;; you should adjust the context window to a larger value.
    (setq minuet-context-window 512)
    (plist-put minuet-openai-fim-compatible-options :end-point "http://localhost:11434/v1/completions")
    ;; an arbitrary non-null environment variable as placeholder.
    ;; For Windows users, TERM may not be present in environment variables.
    ;; Consider using APPDATA instead.
    (plist-put minuet-openai-fim-compatible-options :name "Ollama")
    (plist-put minuet-openai-fim-compatible-options :api-key "TERM")
    (plist-put minuet-openai-fim-compatible-options :model "qwen2.5-coder:3b")

    (minuet-set-optional-options minuet-openai-fim-compatible-options :max_tokens 56))
```

</details>

## OpenRouter Kimi-K2

<details>

```elisp
(use-package minuet
    :config
    (setq minuet-provider 'openai-compatible)
    (setq minuet-request-timeout 2.5)
    (setq minuet-auto-suggestion-throttle-delay 1.5) ;; Increase to reduce costs and avoid rate limits
    (setq minuet-auto-suggestion-debounce-delay 0.6) ;; Increase to reduce costs and avoid rate limits

    (plist-put minuet-openai-compatible-options :end-point "https://openrouter.ai/api/v1/chat/completions")
    (plist-put minuet-openai-compatible-options :api-key "OPENROUTER_API_KEY")
    (plist-put minuet-openai-compatible-options :model "moonshotai/kimi-k2")


    ;; Prioritize throughput for faster completion
    (minuet-set-optional-options minuet-openai-compatible-options :provider '(:sort "throughput"))
    (minuet-set-optional-options minuet-openai-compatible-options :max_tokens 56)
    (minuet-set-optional-options minuet-openai-compatible-options :top_p 0.9))
```

</details>

## Llama.cpp Qwen-2.5-coder:1.5b

<details>

First, launch the `llama-server` with your chosen model.

Here's an example of a bash script to start the server if your system has less
than 8GB of VRAM:

```bash
llama-server \
    -hf ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

```elisp
(use-package minuet
    :config
    (setq minuet-provider 'openai-fim-compatible)
    (setq minuet-n-completions 1) ; recommended for Local LLM for resource saving
    ;; I recommend beginning with a small context window size and incrementally
    ;; expanding it, depending on your local computing power. A context window
    ;; of 512, serves as an good starting point to estimate your computing
    ;; power. Once you have a reliable estimate of your local computing power,
    ;; you should adjust the context window to a larger value.
    (setq minuet-context-window 512)
    (plist-put minuet-openai-fim-compatible-options :end-point "http://localhost:8012/v1/completions")
    ;; an arbitrary non-null environment variable as placeholder
    ;; For Windows users, TERM may not be present in environment variables.
    ;; Consider using APPDATA instead.
    (plist-put minuet-openai-fim-compatible-options :name "Llama.cpp")
    (plist-put minuet-openai-fim-compatible-options :api-key "TERM")
    ;; The model is set by the llama-cpp server and cannot be altered
    ;; post-launch.
    (plist-put minuet-openai-fim-compatible-options :model "PLACEHOLDER")

    ;; Llama.cpp does not support the `suffix` option in FIM completion.
    ;; Therefore, we must disable it and manually populate the special
    ;; tokens required for FIM completion.
    (minuet-set-nested-plist minuet-openai-fim-compatible-options nil :template :suffix)
    (minuet-set-optional-options
     minuet-openai-fim-compatible-options
     :prompt
     (defun minuet-llama-cpp-fim-qwen-prompt-function (ctx)
         (format "<|fim_prefix|>%s\n%s<|fim_suffix|>%s<|fim_middle|>"
                 (plist-get ctx :language-and-tab)
                 (plist-get ctx :before-cursor)
                 (plist-get ctx :after-cursor)))
     :template)

    (minuet-set-optional-options minuet-openai-fim-compatible-options :max_tokens 56))
```

For additional example bash scripts to run llama.cpp based on your local
computing power, please refer to [recipes.md](./recipes.md).

</details>

# API Keys

Minuet requires API keys to function. Set the following environment variables:

- `OPENAI_API_KEY` for OpenAI
- `GEMINI_API_KEY` for Gemini
- `ANTHROPIC_API_KEY` for Claude
- `CODESTRAL_API_KEY` for Codestral
- Custom environment variable for OpenAI-compatible services (as specified in
  your configuration)

**Note:** Provide the name of the environment variable to Minuet inside the
provider options, not the actual value. For instance, pass `OPENAI_API_KEY` to
Minuet, not the value itself (e.g., `sk-xxxx`).

If using Ollama, you need to assign an arbitrary, non-null environment variable
as a placeholder for it to function.

Alternatively, you can provide a function that returns the API key. This
function should return the result instantly as it will be called with each
completion request.

```lisp
;; Good
(plist-put minuet-openai-compatible-options :api-key "FIREWORKS_API_KEY")
(plist-put minuet-openai-compatible-options :api-key (defun my-fireworks-api-key () "sk-xxxx"))
;; Bad
(plist-put minuet-openai-compatible-options :api-key "sk-xxxxx")
```

# Selecting a Provider or Model

The `gemini-2.0-flash` and `codestral` models offer high-quality output with
free and fast processing. For optimal quality, though with significantly slower
generation speed, consider using the `deepseek-chat` model, which is compatible
with both `openai-fim-compatible` and `openai-compatible` providers. For local
LLM inference, you can deploy either `qwen-2.5-coder` or `deepseek-coder-v2`
through Ollama using the `openai-fim-compatible` provider.

Note: as of January 27, 2025, the high server demand from deepseek may
significantly slow down the default provider used by Minuet
(`openai-fim-compatible` with deepseek). We recommend trying alternative
providers instead.

We **do not** recommend using thinking models, as this mode
significantly increases latency—even with the fastest models. However,
if you choose to use thinking models, please ensure that their
thinking capabilities are disabled.  Refer to the following examples
for guidance on how to disable the thinking feature.

Note: You can review the buffer contents in `*minuet*` to identify any
errors returned by the provider in case of misconfiguration in your
options.

## Understanding Model Speed

For cloud-based providers,
[Openrouter](https://openrouter.ai/google/gemini-2.0-flash-001/providers) offers
a valuable resource for comparing the speed of both closed-source and
open-source models hosted by various cloud inference providers.

When assessing model speed, two key metrics are latency (time to first token)
and throughput (tokens per second). Latency is often a more critical factor than
throughput.

Ideally, one would aim for a latency of less than 1 second and a throughput
exceeding 100 tokens per second.

For local LLM,
[llama.cpp#4167](https://github.com/ggml-org/llama.cpp/discussions/4167)
provides valuable data on model speed for 7B models running on Apple M-series
chips. The two crucial metrics are `Q4_0 PP [t/s]`, which measures latency
(tokens per second to process the KV cache, equivalent to the time to generate
the first token), and `Q4_0 TG [t/s]`, which indicates the tokens per second
generation speed.

# Prompt

See [prompt](./prompt.md) for the default prompt used by `minuet` and
instructions on customization.

Note that `minuet` employs two distinct prompt systems:

1. A system designed for chat-based LLMs (OpenAI, OpenAI-Compatible, Claude, and
   Gemini)
2. A separate system designed for Codestral and OpenAI-FIM-compatible models

# Configuration

Below are commonly used configuration options. To view the complete list of
available settings, search for `minuet` through the `customize` interface.

## minuet-provider

Set the provider you want to use for completion with minuet, available options:
`openai`, `openai-compatible`, `claude`, `gemini`, `openai-fim-compatible`, and
`codestral`.

The default is `openai-fim-compatible` using the deepseek endpoint.

You can use `ollama` with either `openai-compatible` or `openai-fim-compatible`
provider, depending on your model is a chat model or code completion (FIM)
model.

## minuet-context-window

The maximum total characters of the context before and after cursor. This limits
how much surrounding code is sent to the LLM for context.

The default is 16000, which roughly equates to 4000 tokens after tokenization.

## minuet-context-ratio

Ratio of context before cursor vs after cursor. When the total characters exceed
the context window, this ratio determines how much context to keep before vs
after the cursor. A larger ratio means more context before the cursor will be
used. The ratio should between 0 and `1`, and default is `0.75`.

## minuet-request-timeout

Maximum timeout in seconds for sending completion requests. In case of the
timeout, the incomplete completion items will be delivered. The default is `3`.

## minuet-show-error-message-on-minibuffer

Whether to show the error messages in minibuffer. The default value is `nil`.
When non-nil, if a request fails or times out without generating even a single
token, the error message will be shown in the minibuffer. Note that you can
always inspect `minuet-buffer-name` to view the complete error log.

## minuet-add-single-line-entry

For `minuet-complete-with-minibuffer` function, Whether to create additional
single-line completion items. When non-nil and a completion item has multiple
lines, create another completion item containing only its first line. This
option has no impact for overlay-based suggesion.

## minuet-n-completions

For FIM model, this is the number of requests to send. For chat LLM , this is
the number of completions encoded as part of the prompt. Note that when
`minuet-add-single-line-entry` is true, the actual number of returned items may
exceed this value. Additionally, the LLM cannot guarantee the exact number of
completion items specified, as this parameter serves only as a prompt guideline.
The default is `3`.

If resource efficiency is imporant, it is recommended to set this value to `1`.

## minuet-auto-suggestion-block-predicates

List of predicate functions that decide whether auto-suggestions should be
suppressed. Each function is called before requesting a suggestion; if any
returns non-nil no suggestion is requested for that moment.

## minuet-auto-suggestion-debounce-delay

The delay in seconds before sending a completion request after typing stops. The
default is `0.4` seconds.

## minuet-auto-suggestion-throttle-delay

The minimum time in seconds between 2 completion requests. The default is `1.0`
seconds.

# Provider Options

You can customize the provider options using `plist-put`, for example:

```lisp
(with-eval-after-load 'minuet
    ;; change openai model to gpt-4.1
    (plist-put minuet-openai-options :model "gpt-4.1")

    ;; change openai-compatible provider to use fireworks
    (setq minuet-provider 'openai-compatible)
    (plist-put minuet-openai-compatible-options :end-point "https://api.fireworks.ai/inference/v1/chat/completions")
    (plist-put minuet-openai-compatible-options :api-key "FIREWORKS_API_KEY")
    (plist-put minuet-openai-compatible-options :model "accounts/fireworks/models/llama-v3p3-70b-instruct")
)
```

To pass optional parameters (like `max_tokens` and `top_p`) to send to the curl
request, you can use function `minuet-set-optional-options`:

```lisp
(minuet-set-optional-options minuet-openai-options :max_tokens 256)
(minuet-set-optional-options minuet-openai-options :top_p 0.9)
```

## OpenAI

<details>

Below is the default value:

```lisp
(defvar minuet-openai-options
    `(:model "gpt-4.1-mini"
      :api-key "OPENAI_API_KEY"
      :system
      (:template minuet-default-system-template
       :prompt minuet-default-prompt
       :guidelines minuet-default-guidelines
       :n-completions-template minuet-default-n-completion-template)
      :fewshots minuet-default-fewshots
      :chat-input
      (:template minuet-default-chat-input-template
       :language-and-tab minuet--default-chat-input-language-and-tab-function
       :context-before-cursor minuet--default-chat-input-before-cursor-function
       :context-after-cursor minuet--default-chat-input-after-cursor-function)
      :optional nil)
    "config options for Minuet OpenAI provider")

```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lisp
(minuet-set-optional-options minuet-openai-options :max_completion_tokens 128)
;; Optionally configure the reasoning effort if you are using a thinking model.
(minuet-set-optional-options minuet-openai-options :reasoning_effort "minimal")
```

Note: If you intend to use GPT-5 series models (e.g., `gpt-5-mini` or
`gpt-5-nano`), keep the following points in mind:

1. Use `max_completion_tokens` instead of `max_tokens`.
2. These models do not support `top_p` or `temperature` adjustments.
3. Ensure `reasoning_effort` is set to `minimal` and update your request
   options accordingly.

</details>

## Claude

<details>

Below is the default value:

```lisp
(defvar minuet-claude-options
    `(:model "claude-haiku-4-5"
      :max_tokens 256
      :api-key "ANTHROPIC_API_KEY"
      :system
      (:template minuet-default-system-template
       :prompt minuet-default-prompt
       :guidelines minuet-default-guidelines
       :n-completions-template minuet-default-n-completion-template)
      :fewshots minuet-default-fewshots
      :chat-input
      (:template minuet-default-chat-input-template
       :language-and-tab minuet--default-chat-input-language-and-tab-function
       :context-before-cursor minuet--default-chat-input-before-cursor-function
       :context-after-cursor minuet--default-chat-input-after-cursor-function)
      :optional nil)
    "config options for Minuet Claude provider")
```

</details>

## Codestral

<details>

Codestral is a text completion model, not a chat model, so the system prompt and
few shot examples does not apply. Note that you should use the
`CODESTRAL_API_KEY`, not the `MISTRAL_API_KEY`, as they are using different
endpoint. To use the Mistral endpoint, simply modify the `end_point` and
`api_key` parameters in the configuration.

Below is the default value:

```lisp
(defvar minuet-codestral-options
    '(:model "codestral-latest"
      :end-point "https://codestral.mistral.ai/v1/fim/completions"
      :api-key "CODESTRAL_API_KEY"
      :template (:prompt minuet--default-fim-prompt-function
                 :suffix minuet--default-fim-suffix-function)
      :optional nil)
    "config options for Minuet Codestral provider")
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lisp
(minuet-set-optional-options minuet-codestral-options :stop ["\n\n"])
(minuet-set-optional-options minuet-codestral-options :max_tokens 256)
```

</details>

## Gemini

You should register the account and use the service from Google AI Studio
instead of Google Cloud. You can get an API key via their
[Google API page](https://makersuite.google.com/app/apikey).

<details>

The following config is the default.

```lisp
(defvar minuet-gemini-options
    `(:model "gemini-2.0-flash"
      :api-key "GEMINI_API_KEY"
      :system
      (:template minuet-default-system-template
       :prompt minuet-default-prompt-prefix-first
       :guidelines minuet-default-guidelines
       :n-completions-template minuet-default-n-completion-template)
      :fewshots minuet-default-fewshots-prefix-first
      :chat-input
      (:template minuet-default-chat-input-template-prefix-first
       :language-and-tab minuet--default-chat-input-language-and-tab-function
       :context-before-cursor minuet--default-chat-input-before-cursor-function
       :context-after-cursor minuet--default-chat-input-after-cursor-function)
      :optional nil)
    "config options for Minuet Gemini provider")
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens. You can also adjust the safety
settings following the example:

```lisp
(minuet-set-optional-options
 minuet-gemini-options :generationConfig
 '(:maxOutputTokens 256
   :topP 0.9
   ;; When using `gemini-2.5-flash`, it is recommended to entirely
   ;; disable thinking for faster completion retrieval.
   :thinkingConfig (:thinkingBudget 0)))

(minuet-set-optional-options
 minuet-gemini-options :safetySettings
 [(:category "HARM_CATEGORY_DANGEROUS_CONTENT"
   :threshold "BLOCK_NONE")
  (:category "HARM_CATEGORY_HATE_SPEECH"
   :threshold "BLOCK_NONE")
  (:category "HARM_CATEGORY_HARASSMENT"
   :threshold "BLOCK_NONE")
  (:category "HARM_CATEGORY_SEXUALLY_EXPLICIT"
   :threshold "BLOCK_NONE")])
```

We recommend using `gemini-2.0-flash` over `gemini-2.5-flash`, as the 2.0
version offers significantly lower costs with comparable performance. The
primary improvement in version 2.5 lies in its extended thinking mode, which
provides minimal value for code completion scenarios. Furthermore, the thinking
mode substantially increases latency, so we recommend disabling it entirely.

</details>

## OpenAI-compatible

Use any providers compatible with OpenAI's chat completion API.

For example, you can set the `end_point` to
`http://localhost:11434/v1/chat/completions` to use `ollama`.

<details>

The following config is the default.

```lisp
(defvar minuet-openai-compatible-options
    `(:end-point "https://openrouter.ai/api/v1/chat/completions"
      :api-key "OPENROUTER_API_KEY"
      :model "mistralai/devstral-small"
      :system
      (:template minuet-default-system-template
       :prompt minuet-default-prompt
       :guidelines minuet-default-guidelines
       :n-completions-template minuet-default-n-completion-template)
      :fewshots minuet-default-fewshots
      :chat-input
      (:template minuet-default-chat-input-template
       :language-and-tab minuet--default-chat-input-language-and-tab-function
       :context-before-cursor minuet--default-chat-input-before-cursor-function
       :context-after-cursor minuet--default-chat-input-after-cursor-function)
      :optional nil)
    "Config options for Minuet OpenAI compatible provider.")
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lisp
(minuet-set-optional-options minuet-openai-compatible-options :max_tokens 256)
(minuet-set-optional-options minuet-openai-compatible-options :top_p 0.9)
;; Optionally configure the reasoning effort if you are using a thinking model.
(minuet-set-optional-options
  minuet-openai-compatible-options
  :reasoning
  ;; '(:max_tokens 0) for Anthropic style
  '(:effort "minimal")) ; for OpenAI style
;; Alternatively, disable reasoning entirely if the model supports it.
(minuet-set-optional-options
  minuet-openai-compatible-options
  :reasoning
  '(:enabled :false))
```

</details>

## OpenAI-FIM-Compatible

Use any provider compatible with OpenAI's completion API. This request uses the
text `/completions` endpoint, **not** `/chat/completions` endpoint, so system
prompts and few-shot examples are not applicable.

For example, you can set the `end_point` to
`http://localhost:11434/v1/completions` to use `ollama`, or set it to
`http://localhost:8012/v1/completions` to use `llama.cpp`.

<details>

Refer to the
[Completions Legacy](https://platform.openai.com/docs/api-reference/completions)
section of the OpenAI documentation for details.

Additionally, for Ollama users, it is essential to verify whether the model's
template supports FIM completion. For example, qwen2.5-coder offers FIM support,
as suggested in its
[template](https://ollama.com/library/qwen2.5-coder/blobs/e94a8ecb9327). However
it may come as a surprise to some users that, `deepseek-coder` does not support
the FIM template, and you should use `deepseek-coder-v2` instead.

The following config is the default.

```lisp
(defvar minuet-openai-fim-compatible-options
    '(:model "deepseek-chat"
      :end-point "https://api.deepseek.com/beta/completions"
      :api-key "DEEPSEEK_API_KEY"
      :name "Deepseek"
      :template (:prompt minuet--default-fim-prompt-function
                 :suffix minuet--default-fim-suffix-function)
      :optional nil)
    "config options for Minuet OpenAI FIM compatible provider")
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lisp
(minuet-set-optional-options minuet-openai-fim-compatible-options :max_tokens 256)
(minuet-set-optional-options minuet-openai-fim-compatible-options :top_p 0.9)
```

For example bash scripts to run llama.cpp based on your local computing power,
please refer to [recipes.md](./recipes.md). Note that the model for `llama.cpp`
must be determined when you launch the `llama.cpp` server and cannot be changed
thereafter.

</details>

### Non-OpenAI-FIM-Compatible APIs

For providers like **DeepInfra FIM**
(`https://api.deepinfra.com/v1/inference/`), refer to [recipes.md](./recipes.md)
for advanced configuration instructions.

# Troubleshooting

If your setup failed, there are two most likely reasons:

1. You may set the API key incorrectly. Checkout the [API Key](#api-keys)
   section to see how to correctly specify the API key.
2. You are using a model or a context window that is too large, causing
   completion items to timeout before returning any tokens. This is particularly
   common with local LLM. It is recommended to start with the following settings
   to have a better understanding of your provider's inference speed.
   - Begin by testing with manual completions.
   - Use a smaller context window (e.g., `context-window = 768`)
   - Use a smaller model
   - Set a longer request timeout (e.g., `request-timeout = 5`)

To diagnose issues, examine the buffer content from `*minuet*`.

# Contributions

Since this package is part of GNU ELPA, substantial contributions require a
copyright assignment to the Free Software Foundation (FSF).

However, minor contributions—such as small bug fixes or documentation
improvements—are welcome even without copyright assignment. If you're unsure
where to begin, feel free to open an issue for guidance.

# Acknowledgement

- [continue.dev](https://www.continue.dev): not a emacs plugin, but I find a lot
  LLM models from here.
- [llama.vim](https://github.com/ggml-org/llama.vim): Reference for CLI
  parameters used to launch the llama-cpp server.
