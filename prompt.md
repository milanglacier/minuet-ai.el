- [FIM LLM Prompt Structure](#fim-llm-prompt-structure)
- [Chat LLM Prompt Structure](#chat-llm-prompt-structure)
  - [Default Template](#default-template)
  - [Default Prompt](#default-prompt)
  - [Default Guidelines](#default-guidelines)
  - [Default `:n_completions` template](#default---n-completions--template)
  - [Default Few Shots Examples](#default-few-shots-examples)
  - [Default Chat Input Example](#default-chat-input-example)
  - [Customization](#customization)
  - [An Experimental Configuration Setup for Gemini](#an-experimental-configuration-setup-for-gemini)

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

# Chat LLM Prompt Structure

## Default Template

`{{{:prompt}}}\n{{{:guidelines}}}\n{{{:n_completion_template}}}`

## Default Prompt

You are the backend of an AI-powered code completion engine. Your task is to
provide code suggestions based on the user's input. The user's code will be
enclosed in markers:

- `<contextAfterCursor>`: Code context after the cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Code context before the cursor

Note that the user's code will be prompted in reverse order: first the code
after the cursor, then the code before the cursor.

## Default Guidelines

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

## Default `:n_completions` template

8. Provide at most %d completion items.

## Default Few Shots Examples

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

## Default Chat Input Example

The chat input represents the final prompt delivered to the LLM for completion.

The chat input template follows a structure similar to the system prompt and can
be customized using the following format:

```
{{{:language-and-tab}}}
<contextAfterCursor>
{{{:context-after-cursor}}}
<contextBeforeCursor>
{{{:context-before-cursor}}}<cursorPosition>
```

Components:

- `:language-and-tab`: Specifies the programming language and indentation style
  utilized by the user
- `:context-before-cursor`: Contains the text content preceding the cursor
  position
- `:context-after-cursor`: Contains the text content following the cursor
  position

Implementation requires each component to be defined by a function that accepts
a single parameter `context` and returns a string. This context parameter is a
plist containing the following values:

- `:before-cursor`
- `:after-cursor`
- `:language-and-tab`
- `:is-incomplete-before`: indicates whether the context before the cursor is
  incomplete
- `:is-incomplete-after`: indicates whether the context after the cursor is
  incomplete

## Customization

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
takes no argument and returns a plist.

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

## An Experimental Configuration Setup for Gemini

Some observations suggest that Gemini might perform better with a
`Prefix-Suffix` structured input format, specifically
`Before-Cursor -> Cursor-Pos -> After-Cursor`.

This contrasts with other chat-based LLMs, which may yield better results with
the inverse structure: `After-Cursor -> Before-Cursor -> Cursor-Pos`.

This finding remains experimental and requires further validation.

Below is the current configuration used by the maintainer for Gemini:

```lisp
(use-package minuet
    :config
    (setq minuet-provider 'gemini)

    (defvar mg-minuet-gemini-prompt
        "You are the backend of an AI-powered code completion engine. Your task is to
provide code suggestions based on the user's input. The user's code will be
enclosed in markers:

- `<contextAfterCursor>`: Code context after the cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Code context before the cursor
")

    (defvar mg-minuet-gemini-chat-input-template
        "{{{:language-and-tab}}}
<contextBeforeCursor>
{{{:context-before-cursor}}}<cursorPosition>
<contextAfterCursor>
{{{:context-after-cursor}}}")

    (defvar mg-minuet-gemini-fewshots
        `((:role "user"
           :content "# language: python
<contextBeforeCursor>
def fibonacci(n):
    <cursorPosition>
<contextAfterCursor>

fib(5)")
          ,(cadr minuet-default-fewshots)))

    (minuet-set-optional-options minuet-gemini-options
                                 :prompt 'mg-minuet-gemini-prompt
                                 :system)
    (minuet-set-optional-options minuet-gemini-options
                                 :template 'mg-minuet-gemini-chat-input-template
                                 :chat-input)
    (plist-put minuet-gemini-options :fewshots 'mg-minuet-gemini-fewshots)

    (minuet-set-optional-options minuet-gemini-options
                                 :generationConfig
                                 '(:maxOutputTokens 256
                                   :topP 0.9))
    (minuet-set-optional-options minuet-gemini-options
                                 :safetySettings
                                 [(:category "HARM_CATEGORY_DANGEROUS_CONTENT"
                                   :threshold "BLOCK_NONE")
                                  (:category "HARM_CATEGORY_HATE_SPEECH"
                                   :threshold "BLOCK_NONE")
                                  (:category "HARM_CATEGORY_HARASSMENT"
                                   :threshold "BLOCK_NONE")
                                  (:category "HARM_CATEGORY_SEXUALLY_EXPLICIT"
                                   :threshold "BLOCK_NONE")])

    )
```
