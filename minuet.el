;;; minuet.el --- Code completion using LLM -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Milan Glacier <dev@milanglacier.com>
;; Maintainer: Milan Glacier <dev@milanglacier.com>
;; Version: 0.6.0
;; URL: https://github.com/milanglacier/minuet-ai.el
;; Package-Requires: ((emacs "29") (plz "0.9") (dash "2.19.1"))

;; This file is part of GNU Emacs

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;; Commentary:

;; LLM-powered code completion with dual modes:
;;
;; - Specialized prompts and various enhancements for chat-based LLMs
;;   on code completion tasks.
;; - Fill-in-the-middle (FIM) completion for compatible models
;;   (DeepSeek, Codestral, and some Ollama models).
;;
;; Minuet supports multiple LLM providers (OpenAI, Claude, Gemini,
;; Codestral, Ollama, Llama.cpp, and OpenAI-compatible providers)
;;
;; You can use it with overlay-based ghost text via
;; `minuet-show-suggestion' or selecting the candidates via
;; `minuet-complete-with-minibuffer'.  You can toggle automatic
;; suggestion popup with `minuet-auto-suggestion-mode'.

;;; Code:

(require 'plz)
(require 'dash)
(require 'cl-lib)

(defgroup minuet nil
  "Minuet group."
  :group 'applications)

(declare-function evil-emacs-state-p "evil-states")
(declare-function evil-insert-state-p "evil-states")
(declare-function consult--read "consult")
(declare-function consult--insertion-preview "consult")

(defcustom minuet-auto-suggestion-debounce-delay 0.4
  "Debounce delay in seconds for auto-suggestions."
  :type 'number)

(defcustom minuet-auto-suggestion-block-functions '(minuet-evil-not-insert-state-p)
  "List of functions to determine whether auto-suggestions should be blocked.

Each function should return non-nil if auto-suggestions should be
blocked.  If any function in this list returns non-nil,
auto-suggestions will not be shown."
  :type '(repeat function))

(defcustom minuet-auto-suggestion-throttle-delay 1.0
  "Minimum time in seconds between auto-suggestions."
  :type 'number)

(defface minuet-suggestion-face
  '((t :inherit shadow))
  "Face used for displaying inline suggestions.")


(defvar-local minuet--current-overlay nil
  "Overlay used for displaying the current suggestion.")


(defvar-local minuet--last-point nil
  "Last known cursor position for suggestion overlay.")

(defvar-local minuet--auto-last-point nil
  "Last known cursor position for auto-suggestion.")


(defvar-local minuet--current-suggestions nil
  "List of current completion suggestions.")

(defvar-local minuet--current-suggestion-index 0
  "Index of currently displayed suggestion.")

(defvar-local minuet--current-requests nil
  "List of current active request processes for this buffer.")


(defvar-local minuet--last-auto-suggestion-time nil
  "Timestamp of last auto-suggestion.")

(defvar-local minuet--debounce-timer nil
  "Timer for debouncing auto-suggestions.")

(defvar minuet-buffer-name "*minuet*" "The basename for minuet buffers.")

(defcustom minuet-provider 'openai-fim-compatible
  "The provider to use for code completion.
Must be one of the supported providers: codestral, openai, claude, etc."
  :type '(choice (const :tag "Codestral" codestral)
                 (const :tag "OpenAI" openai)
                 (const :tag "Claude" claude)
                 (const :tag "OpenAI Compatible" openai-compatible)
                 (const :tag "OpenAI FIM Compatible" openai-fim-compatible)
                 (const :tag "Gemini" gemini)))

(defcustom minuet-context-window 16000
  "The maximum total characters of the context before and after cursor.
This limits how much surrounding code is sent to the LLM for context.
The default is 16000 characters which would roughly equate 4000
tokens."
  :type 'integer)

(defcustom minuet-context-ratio 0.75
  "Ratio of context before cursor vs after cursor.
When the total characters exceed the context window, this ratio
determines how much context to keep before vs after the cursor.  A
larger ratio means more context before the cursor will be used."
  :type 'float)

(defcustom minuet-request-timeout 3
  "Maximum timeout in seconds for sending completion requests."
  :type 'integer)

(defcustom minuet-add-single-line-entry t
  "Whether to create additional single-line completion items.
When non-nil and a completion item has multiple lines, create another
completion item containing only its first line."
  :type 'boolean)

(defcustom minuet-show-error-message-on-minibuffer nil
  "Whether to show the error messages in minibuffer.
When non-nil, if a request fails or times out without generating even
a single token, the error message will be shown in the minibuffer.
Note that you can always inspect `minuet-buffer-name' to view the
complete error log."
  :type 'boolean)

(defcustom minuet-after-cursor-filter-length 15
  "Length of context after cursor used to filter completion text.

This setting helps prevent the language model from generating
redundant text.  When filtering completions, the system compares the
suffix of a completion candidate with the text immediately following
the cursor.

If the length of the longest common substring between the end of the
candidate and the beginning of the post-cursor context exceeds this
value, that common portion is trimmed from the candidate.

For example, if the value is 15, and a completion candidate ends with
a 20-character string that exactly matches the 20 characters following
the cursor, the candidate will be truncated by those 20 characters
before being delivered."
  :type 'integer)

(defcustom minuet-before-cursor-filter-length 1
  "Length of context before cursor used to filter completion text.

This setting helps prevent the language model from generating
redundant text at the beginning of completion.  When filtering
completions, the system compares the prefix of a completion candidate
with the text immediately before the cursor.

If the length of the longest common substring between the beginning of
the candidate and the end of the pre-cursor context exceeds this
value, that common portion is trimmed from the candidate.

For example, if the value is 3, and a completion candidate starts with
a 10-character string where the last 3 characters exactly match the 3
characters before the cursor, the candidate will be truncated by those
3 characters before being delivered."
  :type 'integer)

(defcustom minuet-n-completions 3
  "Number of completion items.
For FIM model, this is the number of requests to send.  For chat LLM ,
this is the number of completions encoded as part of the prompt.  Note
that when `minuet-add-single-line-entry` is true, the actual number of
returned items may exceed this value.  Additionally, the LLM cannot
guarantee the exact number of completion items specified, as this
parameter serves only as a prompt guideline.  The default is `3`."
  :type 'integer)

(defvar minuet-default-prompt-prefix-first
  "You are an AI code completion engine. Provide contextually appropriate completions:
- Code completions in code context
- Comment/documentation text in comments
- String content in string literals
- Prose in markdown/documentation files

Input markers:
- `<contextAfterCursor>`: Context after cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Context before cursor
"
  "The default prefix-first style prompt for minuet completion.")

(defvar minuet-default-prompt
  (concat minuet-default-prompt-prefix-first
          "
Note that the user input will be provided in **reverse** order: first the
context after cursor, followed by the context before cursor.
") "The default prompt for minuet completion.")

(defvar minuet-default-guidelines
  "Guidelines:
1. Offer completions after the `<cursorPosition>` marker.
2. Make sure you have maintained the user's existing whitespace and indentation.
   This is REALLY IMPORTANT!
3. Provide multiple completion options when possible.
4. Return completions separated by the marker <endCompletion>.
5. The returned message will be further parsed and processed. DO NOT include
   additional comments or markdown code block fences. Return the result directly.
6. Keep each completion option concise, limiting it to a single line or a few lines.
7. Create entirely new code completion that DO NOT REPEAT OR COPY any user's existing code around <cursorPosition>."
  "The default guidelines for minuet completion.")

(defvar minuet-default-n-completion-template
  "8. Provide at most %d completion items."
  "The default prompt for minuet for number of completions request.")

(defvar minuet-default-system-template
  "{{{:prompt}}}\n{{{:guidelines}}}\n{{{:n-completions-template}}}"
  "The default template for minuet system template.")

(defvar minuet-default-chat-input-template
  "{{{:language-and-tab}}}
<contextAfterCursor>
{{{:context-after-cursor}}}
<contextBeforeCursor>
{{{:context-before-cursor}}}<cursorPosition>"
  "The default template for minuet chat input.")

(defvar minuet-default-chat-input-template-prefix-first
  "{{{:language-and-tab}}}
<contextBeforeCursor>
{{{:context-before-cursor}}}<cursorPosition>
<contextAfterCursor>
{{{:context-after-cursor}}}"
  "The default prefix-first style template for minuet chat input.")

(defvar minuet-default-fewshots
  `((:role "user"
     :content "# language: javascript
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>")
    (:role "assistant"
     :content "let processed = item;
        if (options.uppercase) {
            processed = processed.toUpperCase();
        }
        if (options.removeSpaces) {
            processed = processed.replace(/\s+/g, '');
        }
        result.push(processed);
    }
<endCompletion>
if (typeof item === 'string') {
            let processed = item;
            if (options.uppercase) {
                processed = processed.toUpperCase();
            }
            if (options.removeSpaces) {
                processed = processed.replace(/\s+/g, '');
            }
            result.push(processed);
        } else {
            result.push(item);
        }
    }
<endCompletion>
")))

(defvar minuet-default-fewshots-prefix-first
  `((:role "user"
     :content "# language: javascript
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});")
    ,(cadr minuet-default-fewshots)))

(defvar minuet-claude-options
  `(:model "claude-3-5-haiku-20241022"
    :end-point "https://api.anthropic.com/v1/messages"
    :max_tokens 512
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
  "Config options for Minuet Claude provider.")

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
  "Config options for Minuet OpenAI provider.")

(defvar minuet-codestral-options
  '(:model "codestral-latest"
    :end-point "https://codestral.mistral.ai/v1/fim/completions"
    :api-key "CODESTRAL_API_KEY"
    :template (:prompt minuet--default-fim-prompt-function
               :suffix minuet--default-fim-suffix-function)
    ;; a list of functions to transform the end-point, headers, and body
    :transform ()
    ;; function to extract LLM-generated text from JSON output
    :get-text-fn minuet--openai-get-text-fn
    :optional nil)
  "Config options for Minuet Codestral provider.")

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

(defvar minuet-openai-fim-compatible-options
  '(:model "deepseek-chat"
    :end-point "https://api.deepseek.com/beta/completions"
    :api-key "DEEPSEEK_API_KEY"
    :name "Deepseek"
    :template (:prompt minuet--default-fim-prompt-function
               :suffix minuet--default-fim-suffix-function)
    ;; a list of functions to transform the end-point, headers, and body
    :transform ()
    ;; function to extract LLM-generated text from JSON output
    :get-text-fn minuet--openai-fim-get-text-fn
    :optional nil)
  "Config options for Minuet OpenAI FIM compatible provider.")

(defvar minuet-gemini-options
  `(:model "gemini-2.0-flash"
    :end-point "https://generativelanguage.googleapis.com/v1beta/models"
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
  "Config options for Minuet Gemini provider.")


(defun minuet-evil-not-insert-state-p ()
  "Return non-nil if evil is loaded and not in insert or Emacs state."
  (and (bound-and-true-p evil-local-mode)
       (not (or (evil-insert-state-p)
                (evil-emacs-state-p)))))

(defmacro minuet-set-nested-plist (plist val &rest attributes)
  "Set or delete a PLIST's nested ATTRIBUTES.
PLIST is the plist to set.  If VAL is non-nil, set the nested
attribute to VAL.  If VAL is nil, delete the final attribute from its
parent plist.
Example usage:
\(minuet-set-nested-plist `minuet-openai-options' 256 :optional :max-tokens)
;; delete :max-tokens field
\(minuet-set-nested-plist `minuet-openai-options' nil :optional :max-tokens)"
  (if (null attributes)
      (error "Minuet-set-nested-plist requires at least one attribute key"))
  (if val
      (let ((access-form plist))
        (dolist (attr attributes)
          (setq access-form `(plist-get ,access-form ,attr)))
        `(setf ,access-form ,val))
    ;; If val is nil, delete the key from its parent plist.
    (let* ((all-but-last-attributes (butlast attributes))
           (last-attribute (car (last attributes)))
           (parent-plist-accessor plist))
      (dolist (attr all-but-last-attributes)
        (setq parent-plist-accessor `(plist-get ,parent-plist-accessor ,attr)))
      `(setf ,parent-plist-accessor (map-delete ,parent-plist-accessor ,last-attribute)))))

(defun minuet-set-optional-options (options key val &optional parent-key)
  "Set the value of KEY in the PARENT-KEY of OPTIONS to VAL.
If PARENT-KEY is not provided, it defaults to :optional.  If VAL is nil,
then remove KEY from OPTIONS.  This helper function simplifies setting
values in a two-level nested plist structure."
  (let ((parent-key (or parent-key :optional)))
    (minuet-set-nested-plist options val parent-key key)))

(defun minuet--eval-value (value)
  "Eval a VALUE for minuet.
If value is a function (either lambda or a callable symbol), eval the
function (with no argument) and return the result.  Else if value is a
symbol, return its value.  Else return itself."
  (cond ((functionp value) (funcall value))
        ((and (symbolp value) (boundp value)) (symbol-value value))
        (t value)))

(defun minuet--cancel-requests ()
  "Cancel all current minuet requests for this buffer."
  (when minuet--current-requests
    (dolist (proc minuet--current-requests)
      (when (process-live-p proc)
        (minuet--log (format "%s process terminated" (prin1-to-string proc)))
        (signal-process proc 'SIGTERM)))
    (setq minuet--current-requests nil)))

(defun minuet--cleanup-suggestion (&optional no-cancel)
  "Remove the current suggestion overlay.
Also cancel any pending requests unless NO-CANCEL is t."
  (unless no-cancel
    (minuet--cancel-requests))
  (when minuet--current-overlay
    (delete-overlay minuet--current-overlay)
    (setq minuet--current-overlay nil)
    (minuet-active-mode -1))
  (remove-hook 'post-command-hook #'minuet--on-cursor-moved t)
  (setq minuet--last-point nil))

(defun minuet--cursor-moved-p ()
  "Check if cursor moved from last suggestion position."
  (and minuet--last-point
       (not (eq minuet--last-point (point)))))

(defun minuet--on-cursor-moved ()
  "Minuet event on cursor moved."
  (when (minuet--cursor-moved-p)
    (minuet--cleanup-suggestion)))

(defun minuet--display-suggestion (suggestions &optional index)
  "Display suggestion from SUGGESTIONS at INDEX using an overlay at point."
  ;; we only cancel requests when cursor is moved. Because the
  ;; completion items may be accumulated during multiple concurrent
  ;; curl requests.
  (minuet--cleanup-suggestion t)
  (add-hook 'post-command-hook #'minuet--on-cursor-moved nil t)
  (when-let* ((suggestions suggestions)
              (cursor-not-moved (not (minuet--cursor-moved-p)))
              (index (or index 0))
              (total (length suggestions))
              (suggestion (nth index suggestions))
              ;; 'Display' is used when not at the end-of-line to
              ;; ensure proper overlay positioning. Other methods,
              ;; such as `after-string' or `before-string', fail to
              ;; correctly position the cursor (which should precede
              ;; the overlay) and the overlay itself.
              (ov-method (if (eolp) 'after-string 'display))
              (ov-start (point))
              (ov-end (if (eq ov-method 'display) (1+ ov-start) ov-start))
              ;; When using 'display', we include the character next
              ;; to the current point into the overlay to ensure its
              ;; visibility, as the overlay otherwise conceals it.
              (offset-char (if (eq ov-method 'after-string)
                               ""
                             (buffer-substring ov-start ov-end)))
              (ov (make-overlay ov-start ov-end)))
    (setq minuet--current-suggestions suggestions
          minuet--current-suggestion-index index
          minuet--last-point ov-start)
    ;; HACK: Adapted from copilot.el We add a 'cursor text property to the
    ;; first character of the suggestion to simulate the visual effect of
    ;; placing the overlay after the cursor
    (put-text-property 0 1 'cursor t suggestion)
    (overlay-put ov ov-method
                 (concat
                  (propertize
                   (format "%s%s"
                           suggestion
                           (if (= total minuet-n-completions 1) ""
                             (format " (%d/%d)" (1+ index) total)))
                   'face 'minuet-suggestion-face)
                  offset-char))
    (overlay-put ov 'minuet t)
    (setq minuet--current-overlay ov)
    (minuet-active-mode 1)))

;;;###autoload
(defun minuet-next-suggestion ()
  "Cycle to next suggestion."
  (interactive)
  (if (and minuet--current-suggestions
           minuet--current-overlay)
      (let ((next-index (mod (1+ minuet--current-suggestion-index)
                             (length minuet--current-suggestions))))
        (minuet--display-suggestion minuet--current-suggestions next-index))
    (minuet-show-suggestion)))

;;;###autoload
(defun minuet-previous-suggestion ()
  "Cycle to previous suggestion."
  (interactive)
  (if (and minuet--current-suggestions
           minuet--current-overlay)
      (let ((prev-index (mod (1- minuet--current-suggestion-index)
                             (length minuet--current-suggestions))))
        (minuet--display-suggestion minuet--current-suggestions prev-index))
    (minuet-show-suggestion)))

;;;###autoload
(defun minuet-show-suggestion ()
  "Show code suggestion using overlay at point."
  (interactive)
  (minuet--cleanup-suggestion)
  (setq minuet--last-point (point))
  (let ((current-buffer (current-buffer))
        (available-p-fn (intern (format "minuet--%s-available-p" minuet-provider)))
        (complete-fn (intern (format "minuet--%s-complete" minuet-provider)))
        (context (minuet--get-context)))
    (unless (funcall available-p-fn)
      (minuet--log (format "Minuet provider %s is not available" minuet-provider))
      (error "Minuet provider %s is not available" minuet-provider))
    (funcall complete-fn
             context
             (lambda (items)
               (setq items (seq-uniq items))
               (with-current-buffer current-buffer
                 (when (and items (not (minuet--cursor-moved-p)))
                   (minuet--display-suggestion items 0)))))))

(defun minuet--log (message &optional message-p)
  "Log minuet messages into `minuet-buffer-name'.
Also print the MESSAGE when MESSAGE-P is t."
  (with-current-buffer (get-buffer-create minuet-buffer-name)
    (goto-char (point-max))
    (insert (format "%s %s\n" message (format-time-string "%Y-%02m-%02d %02H:%02M:%02S")))
    (when message-p (message "%s" message))
    ;; make sure this function returns nil
    nil))

(defun minuet--add-tab-comment ()
  "Add comment string for tab use into the prompt."
  (if-let* ((language-p (derived-mode-p 'prog-mode 'text-mode 'conf-mode))
            (commentstring (format "%s %%s%s"
                                   (or (replace-regexp-in-string "^%" "%%" comment-start) "#")
                                   (or comment-end ""))))
      (if indent-tabs-mode
          (format commentstring "indentation: use \t for a tab")
        (format commentstring (format "indentation: use %d spaces for a tab" tab-width)))
    ""))

(defun minuet--add-language-comment ()
  "Add comment string for language use into the prompt."
  (if-let* ((language-p (derived-mode-p 'prog-mode 'text-mode 'conf-mode))
            (mode (symbol-name major-mode))
            (mode (replace-regexp-in-string "-ts-mode" "" mode))
            (mode (replace-regexp-in-string "-mode" "" mode))
            (commentstring (format "%s %%s%s"
                                   (or (replace-regexp-in-string "^%" "%%" comment-start) "#")
                                   (or comment-end ""))))
      (format commentstring (concat "language: " mode))
    ""))

(defun minuet--add-single-line-entry (data)
  "Add single line entry into the DATA."
  (cl-loop
   for item in data
   when (stringp item)
   append (list (car (split-string item "\n"))
                item)))

(defun minuet--remove-spaces (items)
  "Remove trailing and leading spaces in each item in ITEMS."
  ;; Emacs use \\` and \\' to match the beginning/end of the string,
  ;; ^ and $ are used to match bol or eol
  (setq items (mapcar (lambda (x)
                        (if (or (equal x "")
                                (string-match "\\`[\s\t\n]+\\'" x))
                            nil
                          (string-trim x)))
                      items)
        items (seq-filter #'identity items)))

(defun minuet--get-context ()
  "Get the context for minuet completion."
  (let* ((point (point))
         (n-chars-before point)
         (point-max (point-max))
         (n-chars-after (- point-max point))
         (before-start (point-min))
         (after-end point-max)
         (is-incomplete-before nil)
         (is-incomplete-after nil))
    ;; Calculate context window boundaries before extracting text
    (when (>= (+ n-chars-before n-chars-after) minuet-context-window)
      (cond ((< n-chars-before (* minuet-context-ratio minuet-context-window))
             ;; If context before cursor does not exceed context-window,
             ;; only limit after-cursor content
             (setq after-end (+ point (- minuet-context-window n-chars-before))
                   is-incomplete-after t))
            ((< n-chars-after (* (- 1 minuet-context-ratio) minuet-context-window))
             ;; If context after cursor does not exceed context-window,
             ;; limit before-cursor content
             (setq before-start (- point (- minuet-context-window n-chars-after))
                   is-incomplete-before t))
            (t
             ;; At middle of file, use ratio to determine both boundaries
             (setq is-incomplete-before t
                   is-incomplete-after t
                   after-end (+ point (floor (* minuet-context-window (- 1 minuet-context-ratio))))
                   before-start (+ (point-min)
                                   (max 0 (- n-chars-before
                                             (floor (* minuet-context-window minuet-context-ratio)))))))))
    `(:before-cursor ,(buffer-substring-no-properties before-start point)
      :after-cursor ,(buffer-substring-no-properties point after-end)
      :language-and-tab ,(format "%s\n%s" (minuet--add-language-comment) (minuet--add-tab-comment))
      :is-incomplete-before ,is-incomplete-before
      :is-incomplete-after ,is-incomplete-after)))

(defun minuet--make-chat-llm-shot (context options)
  "Build the final chat input for chat llm.
The CONTEXT is read from the current buffer content.  OPTIONS should
be specified as a plist of provider settings.  The return value will a
list of strings.  It will then be converted into a multi-turn
conversation with alternating `user` and `assistant` roles by
`minuet--create-chat-messages-from-list'"
  (let* ((chat-input (copy-tree (plist-get options :chat-input)))
         (templates (minuet--eval-value (plist-get chat-input :template)))
         (templates (if (stringp templates) (list templates) templates))
         (parts nil)
         (results nil))
    ;; Remove template from options to avoid infinite recursion
    (setq chat-input (plist-put chat-input :template nil))
    ;; Use cl-loop for better control flow
    (dolist (template templates)
      (setq parts nil)
      (cl-loop with last-pos = 0
               for match = (string-match "{{{\\(.+?\\)}}}" template last-pos)
               until (not match)
               for start-pos = (match-beginning 0)
               for end-pos = (match-end 0)
               for key = (match-string 1 template)
               do
               ;; Add text before placeholder
               (when (> start-pos last-pos)
                 (push (substring template last-pos start-pos) parts))
               ;; Get and add replacement value
               (when-let* ((repl-fn (plist-get chat-input (intern key)))
                           (value (funcall repl-fn context)))
                 (push value parts))
               (setq last-pos end-pos)
               finally
               ;; Add remaining text after last match
               (push (substring template last-pos) parts))
      ;; Join parts in reverse order
      (push (apply #'concat (nreverse parts)) results))
    (nreverse results)))

(cl-defun minuet--filter-text (item context)
  "Filter ITEM based on CONTEXT using minuet-find-longest-match.
ITEM is a completion candidate string.
CONTEXT is a plist with :before-cursor and :after-cursor fields.
Returns the filtered item after trimming overlapping parts."
  (when (null item)
    (cl-return-from minuet--filter-text nil))

  (when (null context)
    (cl-return-from minuet--filter-text item))

  (setq item (string-trim item))

  (let* ((before-cursor (plist-get context :before-cursor))
         (after-cursor (plist-get context :after-cursor))
         (filtered-item item))

    ;; Filter against before-cursor context (trim from prefix)
    (when (and before-cursor
               (> minuet-before-cursor-filter-length 0))
      (setq before-cursor (string-trim before-cursor))
      (let* ((match (minuet-find-longest-match filtered-item before-cursor)))
        (when (and match
                   (not (string-empty-p match))
                   (>= (length match) minuet-before-cursor-filter-length))
          (setq filtered-item (substring filtered-item (length match))))))

    ;; Filter against after-cursor context (trim from suffix)
    (when (and after-cursor
               (> minuet-after-cursor-filter-length 0))
      (setq after-cursor (string-trim after-cursor))
      (let* ((match (minuet-find-longest-match after-cursor filtered-item)))
        (when (and match
                   (not (string-empty-p match))
                   (>= (length match) minuet-after-cursor-filter-length))
          (setq filtered-item (substring filtered-item 0 (- (length filtered-item) (length match)))))))

    filtered-item))

(cl-defun minuet-find-longest-match (a b)
  "Find the longest string that is a prefix of A and a suffix of B.
The function iterates from the longest possible match length downwards
for efficiency.  If A or B are not strings, it returns an empty
string."
  (unless (and (stringp a) (stringp b))
    (cl-return-from minuet-find-longest-match ""))
  (let* ((len-a (length a))
         (len-b (length b))
         (max-len (min len-a len-b)))
    (cl-loop for i from max-len downto 1
             for prefix-a = (substring a 0 i)
             for suffix-b = (substring b (- i))
             when (string= prefix-a suffix-b)
             do (cl-return-from minuet-find-longest-match prefix-a))
    ""))

(defun minuet--filter-context-sequence-in-items (items context)
  "Apply the filter sequence in each item in ITEMS.
The filter sequence is obtained from CONTEXT."
  (cl-loop for item in items
           for filtered-item = (minuet--filter-text item context)
           when (and filtered-item
                     (not (string= filtered-item "")))
           collect filtered-item))


(defun minuet--stream-decode (response get-text-fn)
  "Decode the RESPONSE using GET-TEXT-FN."
  (setq response (split-string response "[\r]?\n"))
  (let (result)
    (dolist (line response)
      (when-let* ((json (ignore-errors
                          (json-parse-string
                           (replace-regexp-in-string "^data: " "" line)
                           :object-type 'plist :array-type 'list)))
                  (text (ignore-errors
                          (funcall get-text-fn json))))
        (when (and (stringp text)
                   (not (equal text "")))
          (push text result))))
    (setq result (apply #'concat (nreverse result)))
    (if (equal result "")
        (progn
          (minuet--log "Minuet: Stream decoding failed for response:"
                       minuet-show-error-message-on-minibuffer)
          (minuet--log response))
      result)))

(defmacro minuet--make-process-stream-filter (response)
  "Store the data into RESPONSE which should hold a plain list."
  (declare (debug (gv-place)))
  `(lambda (proc text)
     (funcall #'internal-default-process-filter proc text)
     ;; (setq ,response (append ,response (list text)))
     (push text ,response)))

(defun minuet--stream-decode-raw (response get-text-fn)
  "Decode the raw stream used by minuet.

RESPONSE will be stored in the temp variable create by
`minuet--make-process-stream-filter' parsed by GET-TEXT-FN."
  (if-let* ((response (nreverse response))
            (response (apply #'concat response)))
      (minuet--stream-decode response get-text-fn)
    (minuet--log "Minuet: Empty stream response - no data received"
                 minuet-show-error-message-on-minibuffer)))

(defun minuet--handle-chat-completion-timeout (context err response get-text-fn name callback)
  "Handle the timeout error for chat completion.
This function will decode and send the partial complete response to
the callback, and log the error.  CONTEXT, ERR, RESPONSE, GET-TEXT-FN,
NAME, CALLBACK are used to deliver partial completion items and log
the errors."
  (if (equal (car (plz-error-curl-error err)) 28)
      (progn
        (minuet--log (format "%s Request timeout" name))
        (when-let* ((result (minuet--stream-decode-raw response get-text-fn))
                    (completion-items (minuet--parse-completion-itmes-default result))
                    (completion-items (minuet--filter-context-sequence-in-items
                                       completion-items
                                       context))
                    (completion-items (minuet--remove-spaces completion-items)))
          (funcall callback completion-items)))
    (minuet--log (format "An error occured when sending request to %s" name)
                 minuet-show-error-message-on-minibuffer)
    (minuet--log err)))

(defmacro minuet--with-temp-response (&rest body)
  "Execute BODY with a temporary response collection.
This macro creates a local variable `--response--' that can be used to
collect process output within the BODY.  It's designed to work in
conjunction with `minuet--make-process-stream-filter'.  The
`--response--' variable is initialized as an empty list and can be
used to accumulate text output from a process.  After execution,
`--response--' will contain the collected responses in reverse order."
  (declare (debug t) (indent 0))
  `(let (--response--) ,@body))

;;;###autoload
(defun minuet-accept-suggestion ()
  "Accept the current overlay suggestion."
  (interactive)
  (when (and minuet--current-suggestions
             minuet--current-overlay)
    (let ((suggestion (nth minuet--current-suggestion-index
                           minuet--current-suggestions)))
      (minuet--cleanup-suggestion)
      (insert suggestion))))

;;;###autoload
(defun minuet-dismiss-suggestion ()
  "Dismiss the current overlay suggestion."
  (interactive)
  (minuet--cleanup-suggestion))

;;;###autoload
(defun minuet-accept-suggestion-line (&optional n)
  "Accept N lines of the current suggestion.
When called interactively with a numeric prefix argument, accept that
many lines.  Without a prefix argument, accept only the first line."
  (interactive "p")
  (when (and minuet--current-suggestions
             minuet--current-overlay)
    (let* ((suggestion (nth minuet--current-suggestion-index
                            minuet--current-suggestions))
           (lines (split-string suggestion "\n"))
           (n (or n 1))
           (selected-lines (seq-take lines n)))
      (minuet--cleanup-suggestion)
      (insert (string-join selected-lines "\n")))))

;;;###autoload
(defun minuet-complete-with-minibuffer ()
  "Complete using minibuffer interface."
  (interactive)
  (let ((current-buffer (current-buffer))
        (available-p-fn (intern (format "minuet--%s-available-p" minuet-provider)))
        (complete-fn (intern (format "minuet--%s-complete" minuet-provider)))
        (context (minuet--get-context))
        (completing-read (lambda (items) (completing-read "Complete: " items nil t)))
        (consult--read (lambda (items)
                         (consult--read
                          items
                          :prompt "Complete: "
                          :require-match t
                          :state (consult--insertion-preview (point) (point))))))
    (unless (funcall available-p-fn)
      (minuet--log (format "Minuet provider %s is not available" minuet-provider))
      (error "Minuet provider %s is not available" minuet-provider))
    (funcall complete-fn
             context
             (lambda (items)
               (with-current-buffer current-buffer
                 (setq items (if minuet-add-single-line-entry
                                 (minuet--add-single-line-entry items)
                               items)
                       items (seq-uniq items))
                 ;; close current minibuffer session, if any
                 (when (active-minibuffer-window)
                   (abort-recursive-edit))
                 (when-let* ((items)
                             (selected (funcall
                                        (if (require 'consult nil t) consult--read completing-read)
                                        items)))
                   (unless (string-empty-p selected)
                     (insert selected))))))))

(defun minuet--get-api-key (api-key)
  "Get the api-key from API-KEY.
API-KEY can be a string (as an environment variable) or a function.
Return nil if not exists or is an empty string."
  (let ((key (if (stringp api-key)
                 (getenv api-key)
               (when (functionp api-key)
                 (funcall api-key)))))
    (when (or (null key)
              (string-empty-p key))
      (minuet--log
       (if (stringp api-key)
           (format "%s is not a valid environment variable.
If using ollama you can just set it to 'TERM'." api-key)
         "The api-key function returns nil or returns an empty string")))
    (and (not (equal key "")) key)))


(defun minuet--codestral-available-p ()
  "Check if codestral if available."
  (minuet--get-api-key (plist-get minuet-codestral-options :api-key)))

(defun minuet--openai-available-p ()
  "Check if openai if available."
  (minuet--get-api-key (plist-get minuet-openai-options :api-key)))

(defun minuet--claude-available-p ()
  "Check if claude is available."
  (minuet--get-api-key (plist-get minuet-claude-options :api-key)))

(defun minuet--openai-compatible-available-p ()
  "Check if the specified openai-compatible service is available."
  (when-let* ((options minuet-openai-compatible-options)
              (env-var (plist-get options :api-key))
              (end-point (plist-get options :end-point))
              (model (plist-get options :model)))
    (minuet--get-api-key env-var)))

(defun minuet--openai-fim-compatible-available-p ()
  "Check if the specified openai-fim-compatible service is available."
  (when-let* ((options minuet-openai-fim-compatible-options)
              (env-var (plist-get options :api-key))
              (name (plist-get options :name))
              (end-point (plist-get options :end-point))
              (model (plist-get options :model)))
    (minuet--get-api-key env-var)))

(defun minuet--gemini-available-p ()
  "Check if gemini is available."
  (minuet--get-api-key (plist-get minuet-gemini-options :api-key)))

(defun minuet--parse-completion-itmes-default (items)
  "Parse ITEMS into a list of completion entries."
  (split-string items "<endCompletion>"))

(defun minuet--make-system-prompt (template &optional n-completions)
  "Create system prompt used in chat LLM from TEMPLATE and N-COMPLETIONS."
  (let* ((tmpl (plist-get template :template))
         (tmpl (minuet--eval-value tmpl))
         (n-completions (or n-completions minuet-n-completions 1))
         (n-completions-template (plist-get template :n-completions-template))
         (n-completions-template (minuet--eval-value n-completions-template))
         (n-completions-template (if (stringp n-completions-template)
                                     (format n-completions-template n-completions)
                                   "")))
    (setq tmpl (replace-regexp-in-string "{{{:n-completions-template}}}"
                                         n-completions-template
                                         tmpl)
          tmpl (replace-regexp-in-string
                "{{{\\([^{}]+\\)}}}"
                (lambda (str)
                  (minuet--eval-value (plist-get template (intern (match-string 1 str)))))
                tmpl)
          ;; replace placeholders that are not replaced
          tmpl (replace-regexp-in-string "{{{.*}}}" "" tmpl))))

(defun minuet--openai-fim-complete-base (options get-text-fn context callback)
  "The base function to complete code with openai fim API.
OPTIONS are the provider options.  GET-TEXT-FN are the function to get
the completion items from json.  CONTEXT is to be used to build the
prompt.  CALLBACK is the function to be called when completion items
arrive."
  (let* ((total-try (or minuet-n-completions 1))
         ;; Initialize input components
         (name (plist-get options :name))
         (end-point (plist-get options :end-point))
         (transform-functions (plist-get options :transform))
         (body `(,@(plist-get options :optional)
                 :stream t
                 :model ,(plist-get options :model)
                 :prompt ,(funcall (--> options
                                        (plist-get it :template)
                                        (plist-get it :prompt))
                                   context)
                 ,@(when-let* ((suffix-fn (--> options
                                               (plist-get it :template)
                                               (plist-get it :suffix))))
                     (list :suffix (funcall suffix-fn context)))))
         (headers `(("Content-Type" . "application/json")
                    ("Accept" . "application/json")
                    ("Authorization" .
                     ,(concat "Bearer " (minuet--get-api-key (plist-get options :api-key))))))
         ;; Apply transformations
         (transformed `(:end-point ,end-point
                        :headers ,headers
                        :body ,body))
         (transformed (progn (dolist (fn transform-functions)
                               (setq transformed (or (funcall fn transformed) transformed)))
                             transformed))
         ;; Extract transformed components
         (end-point (plist-get transformed :end-point))
         (headers (plist-get transformed :headers))
         (body (plist-get transformed :body))
         (body-json (json-serialize body))
         ;; placeholder for completion items
         completion-items)
    (dotimes (_ total-try)
      (minuet--with-temp-response
        (push
         (plz 'post end-point
           :headers headers
           :timeout minuet-request-timeout
           :body body-json
           :as 'string
           :filter (minuet--make-process-stream-filter --response--)
           :then
           (lambda (json)
             (when-let* ((result (minuet--stream-decode json get-text-fn)))
               ;; insert the current result into the completion items list
               (push result completion-items))
             (setq completion-items (minuet--filter-context-sequence-in-items
                                     completion-items
                                     context))
             (setq completion-items (minuet--remove-spaces completion-items))
             (funcall callback completion-items))
           :else
           (lambda (err)
             (if (equal (car (plz-error-curl-error err)) 28)
                 (progn
                   (minuet--log (format "%s Request timeout" name))
                   (when-let* ((result (minuet--stream-decode-raw --response-- get-text-fn)))
                     (push result completion-items)))
               (minuet--log (format "An error occured when sending request to %s" name))
               (minuet--log err))
             (setq completion-items
                   (minuet--filter-context-sequence-in-items
                    completion-items
                    context))
             (setq completion-items (minuet--remove-spaces completion-items))
             (funcall callback completion-items)))
         minuet--current-requests)))))

(defun minuet--codestral-complete (context callback)
  "Complete code with codestral.
CONTEXT and CALLBACK will be passed to the base function."
  (minuet--openai-fim-complete-base
   (plist-put (copy-tree minuet-codestral-options) :name "Codestral")
   (plist-get minuet-codestral-options :get-text-fn)
   context
   callback))

(defun minuet--openai-fim-compatible-complete (context callback)
  "Complete code with openai fim API.
CONTEXT and CALLBACK will be passed to the base function."
  (minuet--openai-fim-complete-base
   (copy-tree minuet-openai-fim-compatible-options)
   (plist-get minuet-openai-fim-compatible-options :get-text-fn)
   context
   callback))

(defun minuet--openai-fim-get-text-fn (json)
  "Function to get the completion from a JSON object for openai-fim compatible."
  (--> json
       (plist-get it :choices)
       car
       (plist-get it :text)))

(defun minuet--openai-get-text-fn (json)
  "Function to get the completion from a JSON object for openai compatible service."
  (--> json
       (plist-get it :choices)
       car
       (plist-get it :delta)
       (plist-get it :content)))

(defun minuet--create-chat-messages-from-list (str-list)
  "Convert a list of strings into alternating user/assistant chat messages.
STR-LIST is a list of strings.  Returns a list of plists with :role
and :content keys."
  (let ((result nil)
        (roles '("user" "assistant")))
    (cl-loop for i from 1 to (length str-list)
             for content in str-list
             do (push (list :role (nth (mod (1- i) 2) roles)
                            :content content)
                      result))
    (nreverse result)))

(defun minuet--openai-complete-base (options context callback)
  "The base function to complete code with openai API.
OPTIONS are the provider options.  the completion items from json.
CONTEXT is to be used to build the prompt.  CALLBACK is the function
to be called when completion items arrive."
  (minuet--with-temp-response
    (push
     (plz 'post (plist-get options :end-point)
       :headers
       `(("Content-Type" . "application/json")
         ("Accept" . "application/json")
         ("Authorization" . ,(concat "Bearer " (minuet--get-api-key (plist-get options :api-key)))))
       :timeout minuet-request-timeout
       :body
       (json-serialize
        `(,@(plist-get options :optional)
          :stream t
          :model ,(plist-get options :model)
          :messages ,(vconcat
                      `((:role "system"
                         :content ,(minuet--make-system-prompt (plist-get options :system))))
                      (minuet--eval-value (plist-get options :fewshots))
                      (--> (minuet--make-chat-llm-shot context options)
                           minuet--create-chat-messages-from-list))))
       :as 'string
       :filter (minuet--make-process-stream-filter --response--)
       :then
       (lambda (json)
         (when-let* ((result (minuet--stream-decode json #'minuet--openai-get-text-fn))
                     (completion-items (minuet--parse-completion-itmes-default result))
                     (completion-items (minuet--filter-context-sequence-in-items
                                        completion-items
                                        context))
                     (completion-items (minuet--remove-spaces completion-items)))
           ;; insert the current result into the completion items list
           (funcall callback completion-items)))
       :else
       (lambda (err)
         (minuet--handle-chat-completion-timeout
          context err --response-- #'minuet--openai-get-text-fn "OpenAI" callback)))
     minuet--current-requests)))

(defun minuet--openai-complete (context callback)
  "Complete code with OpenAI.
CONTEXT and CALLBACK will be passed to the base function."
  (minuet--openai-complete-base
   (--> (copy-tree minuet-openai-options)
        (plist-put it :end-point "https://api.openai.com/v1/chat/completions"))
   context callback))

(defun minuet--openai-compatible-complete (context callback)
  "Complete code with OpenAI compatible service.
CONTEXT and CALLBACK will be passed to the base function."
  (minuet--openai-complete-base
   (copy-tree minuet-openai-compatible-options) context callback))

(defun minuet--claude-get-text-fn (json)
  "Function to get the completion from a JSON object for claude."
  (--> json
       (plist-get it :delta)
       (plist-get it :text)))

(defun minuet--claude-complete (context callback)
  "Complete code with Claude.
CONTEXT is to be used to build the prompt.  CALLBACK is the function
to be called when completion items arrive."
  (minuet--with-temp-response
    (push
     (plz 'post (plist-get minuet-claude-options :end-point)
       :headers `(("Content-Type" . "application/json")
                  ("Accept" . "application/json")
                  ("x-api-key" . ,(minuet--get-api-key (plist-get minuet-claude-options :api-key)))
                  ("anthropic-version" . "2023-06-01"))
       :timeout minuet-request-timeout
       :body
       (json-serialize
        (let ((options (copy-tree minuet-claude-options)))
          `(,@(plist-get options :optional)
            :stream t
            :model ,(plist-get options :model)
            :system ,(minuet--make-system-prompt (plist-get options :system))
            :max_tokens ,(plist-get options :max_tokens)
            :messages ,(vconcat
                        (minuet--eval-value (plist-get options :fewshots))
                        (--> (minuet--make-chat-llm-shot context options)
                             minuet--create-chat-messages-from-list)))))
       :as 'string
       :filter (minuet--make-process-stream-filter --response--)
       :then
       (lambda (json)
         (when-let* ((result (minuet--stream-decode json #'minuet--claude-get-text-fn))
                     (completion-items (minuet--parse-completion-itmes-default result))
                     (completion-items (minuet--filter-context-sequence-in-items
                                        completion-items
                                        context))
                     (completion-items (minuet--remove-spaces completion-items)))
           ;; insert the current result into the completion items list
           (funcall callback completion-items)))
       :else
       (lambda (err)
         (minuet--handle-chat-completion-timeout
          context err --response-- #'minuet--claude-get-text-fn "Claude" callback)))
     minuet--current-requests)))

(defun minuet--gemini-get-text-fn (json)
  "Function to get the completion from a JSON object for gemini."
  (--> json
       (plist-get it :candidates)
       car
       (plist-get it :content)
       (plist-get it :parts)
       car
       (plist-get it :text)))

(defun minuet--transform-openai-chat-to-gemini-chat (chat)
  "Convert OpenAI-format chat to Gemini format.
CHAT is a list of plists with :role and :content keys"
  (let (new-chat)
    (dolist (message chat)
      (let ((gemini-message
             (pcase (plist-get message :role)
               ("user"
                `(:role "user" :parts [(:text ,(plist-get message :content))]))
               ("assistant"
                `(:role "model" :parts [(:text ,(plist-get message :content))]))
               (_ nil))))
        (when gemini-message
          (push gemini-message new-chat))))
    (nreverse new-chat)))

(defun minuet--gemini-complete (context callback)
  "Complete code with gemini.
CONTEXT is to be used to build the prompt.  CALLBACK is the function
to be called when completion items arrive."
  (minuet--with-temp-response
    (push
     (plz 'post (format "%s/%s:streamGenerateContent?alt=sse"
                        (plist-get minuet-gemini-options :end-point)
                        (plist-get minuet-gemini-options :model))
       :headers `(("Content-Type" . "application/json")
                  ("x-goog-api-key" . ,(minuet--get-api-key (plist-get minuet-gemini-options :api-key)))
                  ("Accept" . "application/json"))
       :timeout minuet-request-timeout
       :body
       (json-serialize
        (let* ((options (copy-tree minuet-gemini-options))
               (fewshots (minuet--eval-value (plist-get options :fewshots)))
               (fewshots (minuet--transform-openai-chat-to-gemini-chat fewshots)))
          `(,@(plist-get options :optional)
            :system_instruction (:parts (:text ,(minuet--make-system-prompt (plist-get options :system))))
            :contents ,(vconcat
                        fewshots
                        (--> (minuet--make-chat-llm-shot context options)
                             minuet--create-chat-messages-from-list
                             minuet--transform-openai-chat-to-gemini-chat)))))
       :as 'string
       :filter (minuet--make-process-stream-filter --response--)
       :then
       (lambda (json)
         (when-let* ((result (minuet--stream-decode json #'minuet--gemini-get-text-fn))
                     (completion-items (minuet--parse-completion-itmes-default result))
                     (completion-items (minuet--filter-context-sequence-in-items
                                        completion-items
                                        context))
                     (completion-items (minuet--remove-spaces completion-items)))
           (funcall callback completion-items)))
       :else
       (lambda (err)
         (minuet--handle-chat-completion-timeout
          context err --response-- #'minuet--gemini-get-text-fn "Gemini" callback)))
     minuet--current-requests)))


(defun minuet--setup-auto-suggestion ()
  "Setup auto-suggestion with `post-command-hook'."
  (add-hook 'post-command-hook #'minuet--maybe-show-suggestion nil t))

(defun minuet--is-minuet-command ()
  "Return t if current command is a minuet command."
  (and this-command
       (symbolp this-command)
       (string-match-p "^minuet" (symbol-name this-command))))

(defun minuet--is-not-on-throttle ()
  "Return t if current time since last time is larger than the throttle delay."
  (or (null minuet--last-auto-suggestion-time)
      (> (float-time (time-since minuet--last-auto-suggestion-time))
         minuet-auto-suggestion-throttle-delay)))

(defun minuet--maybe-show-suggestion ()
  "Show suggestion with debouncing and throttling."
  (when (and (minuet--is-not-on-throttle)
             (not (minuet--is-minuet-command)))
    (when minuet--debounce-timer
      (cancel-timer minuet--debounce-timer))
    (setq minuet--debounce-timer
          (let ((buffer (current-buffer)))
            (run-with-idle-timer
             minuet-auto-suggestion-debounce-delay nil
             (lambda ()
               (when (and (eq buffer (current-buffer))
                          (or (null minuet--auto-last-point)
                              (not (eq minuet--auto-last-point (point))))
                          (not (run-hook-with-args-until-success 'minuet-auto-suggestion-block-functions)))
                 (setq minuet--last-auto-suggestion-time (current-time)
                       minuet--auto-last-point (point))
                 (minuet-show-suggestion))))))))

(defun minuet--default-fim-prompt-function (ctx)
  "Default function to generate prompt for FIM completions from CTX."
  (format "%s\n%s"
          (plist-get ctx :language-and-tab)
          (plist-get ctx :before-cursor)))

(defun minuet--default-fim-suffix-function (ctx)
  "Default function to generate suffix for FIM completions from CTX."
  (plist-get ctx :after-cursor))

(defun minuet--default-chat-input-language-and-tab-function (ctx)
  "Default function to get language and tab style from CTX."
  (plist-get ctx :language-and-tab))

(defun minuet--default-chat-input-before-cursor-function (ctx)
  "Default function to get before cursor from CTX.
If context is incomplete, remove first line to avoid partial code."
  (let ((text (plist-get ctx :before-cursor))
        (incomplete (plist-get ctx :is-incomplete-before)))
    (when incomplete
      (setq text (replace-regexp-in-string "\\`.*\n" "" text)))
    text))

(defun minuet--default-chat-input-after-cursor-function (ctx)
  "Default function to get after cursor from CTX.
If context is incomplete, remove last line to avoid partial code."
  (let ((text (plist-get ctx :after-cursor))
        (incomplete (plist-get ctx :is-incomplete-after)))
    (when incomplete
      (setq text (replace-regexp-in-string "\n.*\\'" "" text)))
    text))

(defun minuet--cleanup-auto-suggestion ()
  "Clean up auto-suggestion timers and hooks."
  (remove-hook 'post-command-hook #'minuet--maybe-show-suggestion t)
  (when minuet--debounce-timer
    (cancel-timer minuet--debounce-timer)
    (setq minuet--debounce-timer nil))
  (setq minuet--auto-last-point nil))

;;;###autoload
(define-minor-mode minuet-auto-suggestion-mode
  "Toggle automatic code suggestions.
When enabled, Minuet will automatically show suggestions while you type."
  :init-value nil
  :lighter " Minuet"
  (if minuet-auto-suggestion-mode
      (minuet--setup-auto-suggestion)
    (minuet--cleanup-auto-suggestion)))

(defvar minuet-active-mode-map
  (let ((map (make-sparse-keymap))) map)
  "Keymap used when `minuet-active-mode' is enabled.")

(define-minor-mode minuet-active-mode
  "Activated when there is an active suggestion in minuet."
  :init-value nil
  :keymap minuet-active-mode-map)

;;;###autoload
(defun minuet-configure-provider ()
  "Configure a minuet provider interactively.
This command offers an interactive approach to configuring provider
settings, as an alternative to manual configuration via `setq' and
`plist-put'.  When selecting either `openai-compatible' or
`openai-fim-compatible' providers, users will be prompted to specify
their endpoint and API key."
  (interactive)
  (let* ((providers '(("OpenAI" . openai)
                      ("Claude" . claude)
                      ("Codestral" . codestral)
                      ("OpenAI Compatible" . openai-compatible)
                      ("OpenAI FIM Compatible" . openai-fim-compatible)
                      ("Gemini" . gemini)))
         (provider-name (completing-read "Select provider: " providers nil t))
         (provider (alist-get provider-name providers nil nil #'equal))
         (options-sym (intern (format "minuet-%s-options" provider)))
         (options (symbol-value options-sym))
         (current-model (plist-get options :model))
         (model (read-string "Model: " (or current-model ""))))

    (plist-put options :model model)

    ;; For OpenAI compatible providers, also configure endpoint and API key
    (when (memq provider '(openai-compatible openai-fim-compatible))
      (let* ((current-endpoint (plist-get options :end-point))
             (current-api-key (plist-get options :api-key))
             (endpoint (read-string "Endpoint URL: " (or current-endpoint "")))
             (api-key (read-string "API Key Environment Variable or Function: "
                                   (cond ((stringp current-api-key) current-api-key)
                                         ((symbolp current-api-key) (symbol-name current-api-key))
                                         (t ""))))
             ;; If the user enters nothing via `read-string`, retain the current API key.
             (final-api-key (cond ((equal "" api-key) current-api-key)
                                  ((functionp (intern-soft api-key)) (intern-soft api-key))
                                  (t api-key))))
        (plist-put options :end-point endpoint)
        (plist-put options :api-key final-api-key)))

    (setq minuet-provider provider)
    (message "Minuet provider configured to %s with model %s" provider-name model)))

(provide 'minuet)
;;; minuet.el ends here
