# Default Template

`{{{:prompt}}}\n{{{:guidelines}}}\n{{{:n_completion_template}}}`

# Default Prompt

You are the backend of an AI-powered code completion engine. Your task is to
provide code suggestions based on the user's input. The user's code will be
enclosed in markers:

- `<contextAfterCursor>`, `</contextAfterCursor>`: Represents the code context following the cursor.
- `<contextBeforeCursor>`, `</contextBeforeCursor>`: Represents the code context preceding the cursor.
- `<cursorPosition/>`: Represents the cursor position.

Please note, the user's code will be presented in reverse order: the
portion of code following the cursor will be shown first, followed by
the code preceding the cursor.

# Default Guidelines

Guidelines:

1. Offer completions after the `<cursorPosition/>` marker.
2. Make sure you have maintained the user's existing whitespace and indentation.
   This is REALLY IMPORTANT!
3. Provide multiple completion options when possible.
4. Return completions separated by the marker `<completion>` and
   `</completion>`.
5. The returned message will be further parsed and processed. DO NOT include
   additional comments or markdown code block fences. Return the result
   directly.
6. Keep each completion option concise, limiting it to a single line or a few
   lines.
7. Create entirely new code completion that DO NOT REPEAT OR COPY any user's
   existing code.

# Default `:n_completions` template

8. Provide at most %d completion items.

# Default Few Shots Examples

```lisp
`((:role "user"
       :content "# language: python
<contextAfterCursor>

fib(5)
</contextAfterCursor>
<contextBeforeCursor>
def fibonacci(n):
    </contextBeforeCursor><cursorPosition/>")
      (:role "assistant"
       :content "<completion>if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
</completion>
<completion>a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
</completion>
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

Similarly, `:fewshots` can be a list of plist in the above mentioned form or a
function that takes no argument and returns a list.

Below is an example to configure the prompt based on major mode:

```lisp
(defun my-minuet-few-shots ()
    (if (derived-mode-p 'js-mode)
            (list '(:role "user"
                    :content "// language: javascript
<contextAfterCursor>

fib(5)
</contextAfterCursor>
<contextBeforeCursor>
function fibonacci(n) {
    </contextBeforeCursor><cursorPosition/>")
                  '(:role "assistant"
                    :content "<completion>if (n < 2) {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
</completion>
<completion>let a = 0, b = 1;
    for (let i = 0; i < n; i++) {
        [a, b] = [b, a + b];
    }
    return a;
</completion>
"))
        minuet-default-fewshots))

(plist-put minuet-openai-options :fewshots #'my-minuet-few-shots)
```
