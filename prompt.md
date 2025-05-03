- [FIM LLM Prompt Structure](#fim-llm-prompt-structure)
- [Chat LLM Prompt Structure](#chat-llm-prompt-structure)
  - [Default Template](#default-template)
  - [Default Prompt](#default-prompt)
  - [Default Guidelines](#default-guidelines)
  - [Default `:n_completions` template](#default---n-completions--template)
  - [Default Few Shots Examples](#default-few-shots-examples)
  - [Default Chat Input Example](#default-chat-input-example)
  - [Customization](#customization)
  - [A Practical Example](#a-practical-example)

# FIM LLM Prompt Structure

The prompt sent to the FIM LLM follows this structure:

```lisp
'(:template (:prompt minuet--default-fim-prompt-function
             :suffix minuet--default-fim-suffix-function))
```

This template utilizes two default functions that generate the following:

- `:prompt`: Returns the programming language, indentation style, and the
  verbatim content of the context before the cursor.
- `:suffix`: Returns the verbatim content of the context after cursor.

Both `:prompt` and `:suffix` are implemented as functions, each accepting a
plist `ctx` with these attributes and returning a string:

- `:before-cursor`: The text before the cursor.
- `:after-cursor`: The text after the cursor.
- `:language-and-tab`: The programming language and indentation style.
- `is_incomplete_before`: A boolean indicating whether the content before the
  cursor was truncated.
- `is_incomplete_after`: A boolean indicating whether the content after the
  cursor was truncated.

These functions are customizable to provide additional context to the LLM. The
`:suffix` function can be disabled by setting its value to `nil` using
`plist-put`, resulting in a request containing only the `:prompt` content.

Note: for Ollama users: Do not include special tokens (e.g., `<|fim_begin|>`)
within the prompt or suffix functions, as these will be automatically populated
by Ollama. If your use case requires special tokens not covered by Ollama's
default template, disable the `:suffix` function by setting it to `nil` and
incorporate the necessary special tokens within the prompt function.

# Chat LLM Prompt Structure

We utilize two distinct strategies when constructing prompts:

1. **Prefix First Style**: This involves including the code preceding the cursor
   initially, followed by the code succeeding the cursor. This approach is used
   only for the **Gemini** provider.

2. **Suffix First Style**: This method involves including the code following the
   cursor initially, and then the code preceding the cursor. It is employed for
   **other** providers such as OpenAI, OpenAI-Compatible, and Claude.

The counterpart variables are:

1. `minuet-default-prompt` and `minuet-default-prompt-prefix-first`.
2. `minuet-default-fewshots` and `minuet-default-fewshots-prefix-first`.
3. `minuet-default-chat-input-template` and
   `minuet-default-chat-input-template-prefix-first`.

## Default Template

`{{{:prompt}}}\n{{{:guidelines}}}\n{{{:n_completion_template}}}`

## Default Prompt

**Prefix First Style**:

You are the backend of an AI-powered code completion engine. Your task is to
provide code suggestions based on the user's input. The user's code will be
enclosed in markers:

- `<contextAfterCursor>`: Code context after the cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Code context before the cursor

**Suffix First Style**:

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

;; suffix-first style
(defvar minuet-default-fewshots
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
")))

(defvar minuet-default-fewshots-prefix-first
  `((:role "user"
     :content "# language: python
<contextBeforeCursor>
def fibonacci(n):
    <cursorPosition>
<contextAfterCursor>

fib(5)")
    ,(cadr minuet-default-fewshots)))
```

## Default Chat Input Example

The chat input represents the final prompt delivered to the LLM for completion.

The chat input template follows a structure similar to the system prompt and can
be customized using the following format:

**Suffix First Style**:

```
{{{:language-and-tab}}}
<contextAfterCursor>
{{{:context_after_cursor}}}
<contextBeforeCursor>
{{{:context_before_cursor}}}<cursorPosition>
```

**Prefix First Style**:

```
{{{:language-and-tab}}}
<contextBeforeCursor>
{{{:context_before_cursor}}}<cursorPosition>
<contextAfterCursor>
{{{:context_after_cursor}}}
```

The chat input template can be provided either as a single string or as **a list
of strings**. If supplied as a list, each string will be expanded using the
template and its components. The resulting list will then be transformed into a
multi-turn conversation, with roles alternating between `user` and `assistant`.

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

- `:before-cursor`: The text before the cursor.
- `:after-cursor`: The text after the cursor.
- `:language-and-tab`: The programming language and indentation style.
- `is_incomplete_before`: A boolean indicating whether the content before the
  cursor was truncated.
- `is_incomplete_after`: A boolean indicating whether the content after the
  cursor was truncated.

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

## A Practical Example

Here, we present a practical example for configuring the prompt for Gemini,
aiming to reuse existing components of the default prompt wherever possible.

Please note that you should not copy-paste this into your configuration, as it
represents the **default setting** applied to Gemini.

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
