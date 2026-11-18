;;; minuet-context-summary.el --- Cached whole-buffer context summaries -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Experimental proof of concept for discussion #63.  A secondary chat model
;; summarizes the current buffer.  The result is cached and included in chat
;; completion prompts; it is refreshed explicitly, on visiting a file, or after
;; saving, never on every change.

;;; Code:

(require 'json)
(require 'plz)
(require 'minuet)

(defgroup minuet-context-summary nil
  "Cached whole-buffer summaries for Minuet completions."
  :group 'minuet)

(defcustom minuet-context-summary-enabled nil
  "Whether to include a cached summary in chat completion prompts."
  :type 'boolean)

(defcustom minuet-context-summary-provider 'openai-compatible
  "Backend used to generate summaries.
The PoC currently supports `openai-compatible'."
  :type '(choice (const openai-compatible)))

(defcustom minuet-context-summary-target-length 2000
  "Suggested summary length in characters.
This is a prompt hint, not a hard limit."
  :type 'integer)

(defcustom minuet-context-summary-request-timeout 60
  "Maximum time in seconds for a summary request.
Summary generation can be considerably slower than completion requests."
  :type 'number)

(defcustom minuet-context-summary-openai-compatible-options
  '(:model "qwen2.5-coder:7b"
    :end-point "http://localhost:11434/v1/chat/completions"
    :api-key "TERM"
    :system "You produce compact, factual source-file context for a code-completion model."
    :optional nil)
  "Secondary chat-model configuration used for summaries.
`:api-key' names an environment variable, just like Minuet provider options."
  :type 'plist)

(defcustom minuet-context-summary-prompt
  "Analyze this source file as persistent context for an inline code-completion model.

Return only a compact, factual summary with exactly these sections:

OVERVIEW: one very terse sentence describing what this file is about.
STRUCTURE: describe the overall organization and what is already present;
mention important modules, types, functions, methods, state, and data flow.
NOTES: list TODO, FIXME, HACK, WIP, XXX, BUG, and similar markers found in
comments, preserving their meaning and location when possible. Write NONE if
there are no such markers.

Be useful for predicting completions, not for explaining the file to a human.
Mention only facts supported by the source. Do not invent missing APIs,
requirements, behavior, or planned work. Do not include markdown fences or
repeat large portions of the source. Aim for approximately %d characters."
  "Prompt sent to the summary model."
  :type 'string)

(defcustom minuet-context-summary-completion-guidance
  "Use the file summary only as supporting context. Be conservative: complete what the user has started at the cursor; preserve the existing style, names, types, control flow, and local patterns. Prefer a short completion or no completion over speculation. Do not invent new APIs, symbols, requirements, TODOs, or unrelated features. Only suggest code that is a reasonable continuation of the text immediately around the cursor and is supported by the file context."
  "Additional guidance included with cached summaries in completion prompts."
  :type 'string)

(defvar-local minuet-context-summary--text nil)
(defvar-local minuet-context-summary--tick nil
  "Modification tick recorded when the cached summary was generated.
This is informational only; it does not invalidate the cached summary.")
(defvar-local minuet-context-summary--request nil)

(defun minuet-context-summary--api-key (value)
  "Resolve API key environment variable VALUE."
  (cond ((functionp value) (funcall value))
        ((and (stringp value) (getenv value)) (getenv value))
        ((stringp value) value)
        (t nil)))

(defun minuet-context-summary--log (format-string &rest args)
  "Log a context-summary diagnostic using Minuet's log buffer."
  (apply #'minuet--log (apply #'format format-string args) nil))

(defun minuet-context-summary--valid-p ()
  "Return non-nil when a cached summary is available.
The cache remains valid after edits; it is replaced only by a successful
refresh or cleared when the minor mode is disabled."
  (stringp minuet-context-summary--text))

(defun minuet-context-summary--prompt ()
  "Build the summary request prompt from the current buffer."
  (format "%s\n\n<source>\n%s\n</source>"
          (format minuet-context-summary-prompt
                  minuet-context-summary-target-length)
          (buffer-substring-no-properties (point-min) (point-max))))

(defun minuet-context-summary--extract (json)
  "Extract assistant text from an OpenAI-compatible response JSON object."
  (when-let* ((choices (plist-get json :choices))
              (choice (car choices)))
    (or (plist-get (plist-get choice :message) :content)
        (plist-get choice :text)
        (plist-get (plist-get choice :delta) :content))))

(defun minuet-context-summary--finish (buffer tick response)
  "Install RESPONSE in BUFFER after a request started at TICK.
TICK is retained for diagnostics only: edits made while the request runs do
do not invalidate or discard the resulting summary."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq minuet-context-summary--request nil)
      (if (stringp response)
          (setq minuet-context-summary--text response
                minuet-context-summary--tick tick)
        (minuet-context-summary--log
         "Context summary response contained no text; cache unchanged (started at tick %S)"
         tick)))))

(defun minuet-context-summary--request-openai-compatible ()
  "Request a summary using the configured OpenAI-compatible chat backend."
  (let* ((options minuet-context-summary-openai-compatible-options)
         (api-key (minuet-context-summary--api-key
                   (plist-get options :api-key)))
         (endpoint (plist-get options :end-point))
         (tick (buffer-chars-modified-tick))
         (buffer (current-buffer))
         (body `(:model ,(plist-get options :model)
                 :messages [(:role "system" :content
                                  ,(plist-get options :system))
                            (:role "user" :content ,(minuet-context-summary--prompt))]
                 ,@(plist-get options :optional)))
         (headers `(("Content-Type" . "application/json")
                    ("Accept" . "application/json")
                    ("Authorization" . ,(concat "Bearer " api-key)))))
    (minuet-context-summary--log
     "Context summary request started for %s at tick %S using %s"
     (buffer-name buffer) tick endpoint)
    (setq minuet-context-summary--request
          (plz 'post endpoint
            :headers headers
            :timeout minuet-context-summary-request-timeout
            :body (json-serialize body)
            :as 'string
            :then (lambda (response)
                    (with-current-buffer buffer
                      (minuet-context-summary--log
                       "Context summary raw response: %s" response)
                      (condition-case err
                          (let* ((parsed (json-parse-string
                                          response
                                          :object-type 'plist
                                          :array-type 'list))
                                 (text (minuet-context-summary--extract parsed)))
                            (minuet-context-summary--log
                             "Context summary parsed response: %S" parsed)
                            (minuet-context-summary--log
                             "Context summary extracted text: %S" text)
                            (minuet-context-summary--finish buffer tick text))
                        (error
                         (setq minuet-context-summary--request nil)
                         (minuet-context-summary--log
                          "Context summary response parse error: %S" err)))))
            :else (lambda (err)
                    (setq minuet-context-summary--request nil)
                    (minuet-context-summary--log
                     "Context summary request error: %S" err))))))

;;;###autoload
(defun minuet-context-summary-refresh ()
  "Refresh the cached summary for the current buffer.
The existing cache remains available while the asynchronous refresh runs and
is replaced only if the new response contains text."
  (interactive)
  (when (and minuet-context-summary-enabled
             (not (process-live-p minuet-context-summary--request)))
    (pcase minuet-context-summary-provider
      ('openai-compatible (minuet-context-summary--request-openai-compatible)))))

(defun minuet-context-summary--refresh-after-save ()
  "Refresh the summary after saving the current buffer."
  (minuet-context-summary-refresh))

(defun minuet-context-summary--refresh-on-load ()
  "Refresh the summary when a file buffer is visited."
  (when (and minuet-context-summary-enabled buffer-file-name)
    (minuet-context-summary-refresh)))

(defun minuet-context-summary--augment-chat-shot (original context options)
  "Add the cached summary and conservative guidance to ORIGINAL's chat shot."
  (let ((shots (funcall original context options)))
    (if (and minuet-context-summary-enabled
             (minuet-context-summary--valid-p)
             (consp shots))
        (cons (format "<fileSummary>\n%s\n</fileSummary>\n\n<completionGuidance>\n%s\n</completionGuidance>\n\n%s"
                      minuet-context-summary--text
                      minuet-context-summary-completion-guidance
                      (car shots))
              (cdr shots))
      shots)))

(define-minor-mode minuet-context-summary-mode
  "Use a cached secondary-model summary in Minuet chat prompts."
  :group 'minuet-context-summary
  :lighter " Sum"
  (if minuet-context-summary-mode
      (progn
        (setq minuet-context-summary-enabled t)
        (add-hook 'after-save-hook #'minuet-context-summary--refresh-after-save nil t)
        (advice-add 'minuet--make-chat-llm-shot :around
                    #'minuet-context-summary--augment-chat-shot)
        (minuet-context-summary-refresh))
    (remove-hook 'after-save-hook #'minuet-context-summary--refresh-after-save t)
    (advice-remove 'minuet--make-chat-llm-shot
                   #'minuet-context-summary--augment-chat-shot)
    (when (process-live-p minuet-context-summary--request)
      (delete-process minuet-context-summary--request))
    (setq minuet-context-summary--request nil
          minuet-context-summary--text nil
          minuet-context-summary--tick nil)))

(add-hook 'find-file-hook #'minuet-context-summary--refresh-on-load)

(provide 'minuet-context-summary)
;;; minuet-context-summary.el ends here
