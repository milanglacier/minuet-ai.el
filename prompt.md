# FIM LLM Prompt Structure

The prompt sent to the FIM LLM follows this structure:

```lisp
'(:template (:prompt minuet--default-fim-prompt-function
             :suffix minuet--default-fim-suffix-function))
```

The template contains two main functions:

- `:prompt`: return language and the indentation style, followed by the
  `context_before_cursor` verbatim.
- `:suffix`: return `context_after_cursor` verbatim.

Both functions can be customized to supply additional context to the LLM. The
`suffix` function can be disabled by setting `:suffix` to `nil` via `plist-put`,
resulting in a request containing only the prompt.

Note: for Ollama users: Do not include special tokens (e.g., `<|fim_begin|>`)
within the prompt or suffix functions, as these will be automatically populated
by Ollama. If your use case requires special tokens not covered by Ollama's
default template, disable the `:suffix` function by setting it to `nil` and
incorporate the necessary special tokens within the prompt function.

# Default Template

`{{{:prompt}}}\n{{{:guidelines}}}\n{{{:n_completion_template}}}`

# Default Prompt

You are the backend of an AI-powered code completion engine. Your task is to
provide code suggestions based on the user's input. The user's code will be
enclosed in markers:

- `<contextAfterCursor>`: Code context after the cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Code context before the cursor

Note that the user's code will be prompted in reverse order: first the code
after the cursor, then the code before the cursor.

# Default Guidelines

Guidelines:

1. Offer completions after the `<cursorPosition>` marker.
2. Make sure you have maintained the user's existing whitespace and indentation.
   This is REALLY IMPORTANT!
3. Provide multiple completion options when possible.
4. Return completions separated by the marker `<endCompletion>`.
5. The returned message will be further parsed and processed. DO NOT include
   additional comments or markdown code block fences. Return the result
   directly.
6. Keep each completion option concise, limiting it to a single line or a few
   lines.
7. Create entirely new code completion that DO NOT REPEAT OR COPY any user's
   existing code around `<cursorPosition>`.

# Default `:n_completions` template

8. Provide at most %d completion items.

# Default Few Shots Examples

```lisp
`((:role "user"
       :content "# language: python
<contextAfterCursor>

fib(5)
<contextBeforeCursor>
def fibonacci(n):
    <cursorPosition>")
      (:role "assistant"
       :content "    '''
    Recursive Fibonacci implementation
    '''
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
<endCompletion>
    '''
    Iterative Fibonacci implementation
    '''
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
<endCompletion>
"))
```

# Customization

You can customize the `:template` by encoding placeholders within triple braces.
These placeholders will be interpolated using the corresponding key-value pairs
from the table. The value can be a function that takes no argument and returns a
string, or a symbol whose value is a string.

Here's a simplified example for illustrative purposes (not intended for actual
configuration):

```lisp
(setq my-minuet-simple-template "{{{:assistant}}}\n{{{:role}}}")
(setq my-minuet-simple-role "you are also a computer scientist")
(defun my-simple-assistant-prompt () "" "you are a helpful assistant.")

(plist-put
 minuet-openai-options
 :system
 '(:template my-minuet-simple-template ; note: you do not need the comma , for interpolation
   :assistant my-simple-assistant-prompt
   :role my-minuet-simple-role))
```

Note that `:n_completion_template` is a special placeholder as it contains one
`%d` which will be encoded with `minuet-n-completions`, if you want to customize
this template, make sure your prompt also contains only one `%d`.

Similarly, `:fewshots` can be a plist in the following form or a function that
takes no argument and returns a plist in the following form:

```lisp
`((:role "user"
       :content "# language: python
<contextAfterCursor>

fib(5)
<contextBeforeCursor>
def fibonacci(n):
    <cursorPosition>")
      (:role "assistant"
       :content "    '''
    Recursive Fibonacci implementation
    '''
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
<endCompletion>
    '''
    Iterative Fibonacci implementation
    '''
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
<endCompletion>
"))
```

Below is an example to configure the prompt based on major mode:

```lisp
(defun my-minuet-few-shots ()
    (if (derived-mode-p 'js-mode)
            (list '(:role "user"
                    :content "// language: javascript
<contextAfterCursor>

fib(5)
<contextBeforeCursor>
function fibonacci(n) {
    <cursorPosition>")
                  '(:role "assistant"
                    :content "    // Recursive Fibonacci implementation
    if (n < 2) {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
<endCompletion>
    // Iterative Fibonacci implementation
    let a = 0, b = 1;
    for (let i = 0; i < n; i++) {
        [a, b] = [b, a + b];
    }
    return a;
<endCompletion>
"))
        minuet-default-fewshots))

(plist-put minuet-openai-options :fewshots #'my-minuet-few-shots)
```
