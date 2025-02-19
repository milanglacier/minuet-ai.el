# Launching the llama.cpp Server: Example Script

This guide provides several configuration variants for the `qwen2.5-coder`
based on local computing power, specifically the available VRAM.

### **For Systems with More Than 16GB VRAM**

```bash
llama-server \
    -hf ggml-org/Qwen2.5-Coder-7B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

### **For Systems with Less Than 16GB VRAM**

```bash
llama-server \
    -hf ggml-org/Qwen2.5-Coder-3B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

### **For Systems with Less Than 8GB VRAM**

```bash
llama-server \
    -hf ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

## Example minuet config

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
    (plist-put minuet-openai-fim-compatible-options :name "Llama.cpp")
    (plist-put minuet-openai-fim-compatible-options :api-key "TERM")
    ;; The model is set by the llama-cpp server and cannot be altered
    ;; post-launch.
    (plist-put minuet-openai-fim-compatible-options :model "PLACEHOLDER")

    ;; Llama.cpp does not support the `suffix` option in FIM completion.
    ;; Therefore, we must disable it and manually populate the special
    ;; tokens required for FIM completion.
    (minuet-set-optional-options minuet-openai-fim-compatible-options :suffix nil :template)
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

> [!NOTE]
> Symbols like `<|fim_begin|>` and `<|fim_suffix|>` are special tokens
> that serve as prompt boundaries. Some LLMs, like Qwen2.5-Coder, have
> been trained with specific tokens to better understand prompt
> composition. Different LLMs use different special tokens during
> training, so you should adjust these tokens according to your
> preferred LLM.

## **Acknowledgment**

- [llama.vim](https://github.com/ggml-org/llama.vim): A reference for CLI parameters used in launching the `llama.cpp` server.
