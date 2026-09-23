# PoC: cached whole-file summaries

This branch implements a proof of concept for [upstream discussion #63](https://github.com/milanglacier/minuet-ai.el/discussions/63).

## Using this branch from a local Emacs configuration

The context-summary PoC is not part of the released Minuet package. To try it,
check out this repository at the `poc/context-summary-completion` branch and add
the checkout to Emacs' load path. The branch contains both the regular Minuet
package and the additional `minuet-context-summary.el` module.

### 1. Clone the PoC branch

For example, clone it below `~/src`:

```sh
git clone --branch poc/context-summary-completion \
    https://github.com/cehteh/minuet-ai.el.git \
    ~/src/minuet-ai.el
```

If the repository is already cloned, switch it to the PoC branch instead:

```sh
cd ~/src/minuet-ai.el
git fetch origin poc/context-summary-completion
git switch poc/context-summary-completion
git pull --ff-only origin poc/context-summary-completion
```

The branch currently points at the PoC commit
[`c3b5095`](https://github.com/cehteh/minuet-ai.el/commit/c3b50958888ac6a1116db9c14d18257fd416a3f9).

### 2. Install the runtime dependencies

This PoC requires Emacs 29 or newer with native JSON support, plus the `plz` and
`dash` libraries. Install those dependencies through your usual package
manager. For example, with `package.el`:

```elisp
(require 'package)
(package-initialize)

(unless (package-installed-p 'plz)
  (package-refresh-contents)
  (package-install 'plz))
(unless (package-installed-p 'dash)
  (package-refresh-contents)
  (package-install 'dash))
```

`use-package` itself must also be installed and loaded before the configuration
below is evaluated.

### 3. Configure Minuet and the summary backend with `use-package`

Put the following in `init.el` (adjust `my-minuet-directory` to the checkout
location):

```elisp
(require 'use-package)

(defconst my-minuet-directory
  (expand-file-name "~/src/minuet-ai.el")
  "Local checkout of the Minuet context-summary PoC.")

;; Load Minuet from the local PoC checkout, rather than from ELPA or MELPA.
(use-package minuet
  :load-path my-minuet-directory
  :commands (minuet-show-suggestion
             minuet-complete-with-minibuffer)
  :bind (("M-i" . minuet-show-suggestion)
         ("M-y" . minuet-complete-with-minibuffer))
  :init
  ;; This is optional. Remove it if completions should only be requested
  ;; manually with M-i or M-y.
  (add-hook 'prog-mode-hook #'minuet-auto-suggestion-mode)
  :config
  ;; Use a chat provider here: the cached file summary is added only to chat
  ;; completion prompts, not to FIM requests.
  (setq minuet-provider 'openai-compatible)
  (setq minuet-openai-compatible-options
        '(:end-point "http://localhost:11434/v1/chat/completions"
          :api-key "TERM"
          :model "qwen2.5-coder:7b"))
  (minuet-set-optional-options minuet-openai-compatible-options
                               :max_tokens 256))

;; Load the PoC module from the same checkout and enable it for programming
;; buffers. It requests a summary when a file is visited and after it is saved.
(use-package minuet-context-summary
  :load-path my-minuet-directory
  :after minuet
  :commands (minuet-context-summary-refresh)
  :config
  (setq minuet-context-summary-provider 'openai-compatible)
  (setq minuet-context-summary-target-length 2000)
  (setq minuet-context-summary-openai-compatible-options
        '(:model "qwen2.5-coder:7b"
          :end-point "http://localhost:11434/v1/chat/completions"
          ;; The PoC expects the name of an environment variable. Ollama does
          ;; not need authentication, so TERM is used as a non-empty placeholder.
          :api-key "TERM"
          :system "Summarize source files for a code completion assistant."))
  (add-hook 'prog-mode-hook #'minuet-context-summary-mode))
```

For a cloud or other OpenAI-compatible service, replace `:end-point`, `:model`,
and `:api-key`. The `:api-key` value is normally the **name** of an environment
variable, not the secret itself. For example:

```elisp
(setq minuet-openai-compatible-options
      '(:end-point "https://openrouter.ai/api/v1/chat/completions"
        :api-key "OPENROUTER_API_KEY"
        :model "your/provider-model"))
(setq minuet-context-summary-openai-compatible-options
      '(:end-point "https://openrouter.ai/api/v1/chat/completions"
        :api-key "OPENROUTER_API_KEY"
        :model "your/summary-model"
        :system "Summarize source files for a code completion assistant."))
```

Set the corresponding variable before starting Emacs, for example:

```sh
export OPENROUTER_API_KEY='your-secret-key'
```

The summary model and completion model are configured independently. They may
use the same endpoint and model, or the summary model may be a cheaper/local
model while the primary completion model is a different service.

### 4. Start the local Ollama example

If using the example above, install and start Ollama, then download the model:

```sh
ollama pull qwen2.5-coder:7b
```

Ollama normally serves the configured endpoint at
`http://localhost:11434/v1/chat/completions`.

### 5. Try the PoC

1. Restart Emacs or evaluate the configuration.
2. Visit a source file. `minuet-context-summary-mode` requests a summary for the
   file asynchronously.
3. Wait for the request to finish, then invoke `M-i` for an overlay suggestion
   or `M-y` for the minibuffer completion UI.
4. Save the file to request a fresh summary.
5. To request one manually, run `M-x minuet-context-summary-refresh`.
6. Inspect the `*minuet*` buffer if a provider request fails.

A summary is cached only while it matches the buffer's current
`buffer-chars-modified-tick`. Editing the buffer invalidates the cached summary;
the PoC does not send a request on every change. A new summary is obtained on a
file visit, after saving, or through the explicit refresh command.

## Design

`minuet-context-summary.el` introduces a **secondary chat-model configuration**. It is intentionally independent of `minuet-provider`, so a FIM completion model can remain the primary model while a
chat model produces file summaries.

The summary is:

- opt-in via `minuet-context-summary-mode`;
- cached buffer-locally and guarded by `buffer-chars-modified-tick`;
- refreshed explicitly with `M-x minuet-context-summary-refresh`, on visiting a file, or after saving;
- never requested from `after-change-functions`;
- treated as a prompt hint, with `minuet-context-summary-target-length` passed to the model rather than enforced locally;
- included only in chat completion prompts, not FIM requests;
- discarded when the buffer changes until the next explicit/load/save refresh.

The PoC backend is OpenAI-compatible, which covers Ollama, llama.cpp chat endpoints, OpenRouter, and similar services.

## Example

The equivalent direct setup, without `use-package`, is:

```elisp
(require 'minuet-context-summary)

(setq minuet-context-summary-provider 'openai-compatible)
(setq minuet-context-summary-target-length 2000)
(setq minuet-context-summary-openai-compatible-options
      '(:model "qwen2.5-coder:7b"
        :end-point "http://localhost:11434/v1/chat/completions"
        :api-key "TERM"
        :system "Summarize source code for completion."))

(add-hook 'prog-mode-hook #'minuet-context-summary-mode)
```

For a cloud backend, change `:end-point`, `:model`, and `:api-key`. The API-key value follows Minuet's convention: it is normally the name of an environment variable.

## Follow-up work

- Share the existing provider transport and response extraction instead of maintaining a PoC-specific OpenAI-compatible request.
- Add native Claude and Gemini summary backends.
- Add project/include discovery with explicit privacy controls.
- Add latency and acceptance-rate benchmarks against baseline context windows.
- Decide whether summary refresh should be debounced after save or remain explicitly user-controlled.
