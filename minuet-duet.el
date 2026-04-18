;;; minuet-duet.el --- Next-edit prediction for minuet -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Milan Glacier <dev@milanglacier.com>
;; Maintainer: Milan Glacier <dev@milanglacier.com>

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

;; Next-edit prediction (NES / duet) module for minuet-ai.

;;; Code:

(require 'cl-lib)
(require 'plz)
(require 'dash)
(require 'minuet-diff)

(require 'minuet)

;;;;;
;; Customization
;;;;;

(defgroup minuet-duet nil
  "Minuet duet (next-edit prediction) settings."
  :group 'minuet)

(defcustom minuet-duet-provider 'gemini
  "Provider for duet predictions."
  :type '(choice (const :tag "OpenAI" openai)
                 (const :tag "Claude" claude)
                 (const :tag "Gemini" gemini)
                 (const :tag "OpenAI Compatible" openai-compatible)))

(defcustom minuet-duet-request-timeout 15
  "Maximum timeout in seconds for duet requests."
  :type 'integer)

(defcustom minuet-duet-editable-region-lines-before 8
  "Number of lines before point to include in the editable region."
  :type 'integer)

(defcustom minuet-duet-editable-region-lines-after 15
  "Number of lines after point to include in the editable region."
  :type 'integer)

(defcustom minuet-duet-editable-region-start-marker "<editable_region>"
  "Marker indicating the start of the editable region."
  :type 'string)

(defcustom minuet-duet-editable-region-end-marker "</editable_region>"
  "Marker indicating the end of the editable region."
  :type 'string)

(defcustom minuet-duet-cursor-position-marker "<cursor_position/>"
  "Marker indicating the cursor position."
  :type 'string)

(defcustom minuet-duet-preview-cursor "\xf246"
  "Character used to render the predicted cursor position."
  :type 'string)

(defcustom minuet-duet-filter-region-before-length 30
  "Minimum match length to trigger prefix filtering in duet editable region.

When the beginning of the editable region text matches the end of the
non-editable region before it, and the match length meets or exceeds
this threshold, the overlapping portion is trimmed from the editable
region text.

Set to 0 to disable prefix filtering."
  :type 'integer)

(defcustom minuet-duet-filter-region-after-length 30
  "Minimum match length to trigger suffix filtering in duet editable region.

When the end of the editable region text matches the beginning of the
non-editable region after it, and the match length meets or exceeds
this threshold, the overlapping portion is trimmed from the editable
region text.

Set to 0 to disable suffix filtering."
  :type 'integer)

(defvar minuet-duet-active-mode-map
  (let ((map (make-sparse-keymap))) map)
  "Keymap used when `minuet-duet-active-mode' is enabled.")

(define-minor-mode minuet-duet-active-mode
  "Activated when there is an active duet preview in Minuet."
  :init-value nil
  :keymap minuet-duet-active-mode-map)

;; Faces

(defface minuet-duet-add-face
  '((t :inherit diff-refine-added))
  "Face for proposed (added) lines in duet preview."
  )

(defface minuet-duet-delete-face
  '((t :inherit diff-removed))
  "Face for lines to be deleted in duet preview."
  )

(defface minuet-duet-cursor-face
  '((t :inherit isearch))
  "Face for the predicted cursor glyph in duet preview."
  )

;;;;;
;; Default prompts & templates
;;;;;

(defun minuet-duet--render-markers (text)
  "Replace marker placeholders in TEXT with configured marker strings."
  (setq text (replace-regexp-in-string
              (regexp-quote "{{{:editable_region_start}}}")
              minuet-duet-editable-region-start-marker text t t))
  (setq text (replace-regexp-in-string
              (regexp-quote "{{{:editable_region_end}}}")
              minuet-duet-editable-region-end-marker text t t))
  (setq text (replace-regexp-in-string
              (regexp-quote "{{{:cursor_position}}}")
              minuet-duet-cursor-position-marker text t t))
  text)

(defun minuet-duet--default-prompt ()
  "Build the default duet system prompt."
  (minuet-duet--render-markers
   "You are an AI editing engine that rewrites only the editable region in a document.

Input markers:
- `{{{:editable_region_start}}}` and `{{{:editable_region_end}}}` wrap the editable region.
- `{{{:cursor_position}}}` marks the current cursor position inside that editable region."))

(defun minuet-duet--default-guidelines ()
  "Build the default duet guidelines."
  (minuet-duet--render-markers
   "Guidelines:
1. Return only the rewritten editable region, wrapped in `{{{:editable_region_start}}}` and `{{{:editable_region_end}}}`.
2. Include exactly one `{{{:cursor_position}}}` marker inside the rewritten editable region.
3. Preserve indentation, formatting, blank lines, and surrounding syntax conventions. Keep the exact number of empty lines unless you are intentionally changing them.
4. For any text or code inside the editable region that is not intended to change, copy it verbatim. Do not paraphrase, refactor, reformat, or otherwise alter unchanged content.
5. Make only the smallest changes necessary to satisfy the requested edit.
6. Do not return explanations, markdown fences, or any content outside the editable region block.
7. Make the rewrite coherent with the surrounding non-editable text."))

(defvar minuet-duet-default-system-template
  "{{{:prompt}}}\n{{{:guidelines}}}"
  "Default system template for duet.")

(defvar minuet-duet-default-system
  `(:template minuet-duet-default-system-template
    :prompt minuet-duet--default-prompt
    :guidelines minuet-duet--default-guidelines)
  "Default system prompt spec for duet.")

(defun minuet-duet--default-chat-input-template ()
  "Build the default chat input template with rendered markers."
  (minuet-duet--render-markers
   "{{{:non_editable_region_before}}}
{{{:editable_region_start}}}
{{{:editable_region_before_cursor}}}{{{:cursor_position}}}{{{:editable_region_after_cursor}}}
{{{:editable_region_end}}}
{{{:non_editable_region_after}}}"))

(defun minuet-duet--chat-input-non-editable-region-before (context)
  "Return the non-editable region before the editable region from CONTEXT."
  (plist-get context :non-editable-region-before))

(defun minuet-duet--chat-input-editable-region-before-cursor (context)
  "Return the editable region before point from CONTEXT."
  (plist-get context :editable-region-before-cursor))

(defun minuet-duet--chat-input-editable-region-after-cursor (context)
  "Return the editable region after point from CONTEXT."
  (plist-get context :editable-region-after-cursor))

(defun minuet-duet--chat-input-non-editable-region-after (context)
  "Return the non-editable region after the editable region from CONTEXT."
  (plist-get context :non-editable-region-after))

(defvar minuet-duet-default-chat-input
  '(:template minuet-duet--default-chat-input-template
    :non_editable_region_before
    minuet-duet--chat-input-non-editable-region-before
    :editable_region_before_cursor
    minuet-duet--chat-input-editable-region-before-cursor
    :editable_region_after_cursor
    minuet-duet--chat-input-editable-region-after-cursor
    :non_editable_region_after
    minuet-duet--chat-input-non-editable-region-after)
  "Default chat input spec for duet.")

(defun minuet-duet--default-fewshots ()
  "Build the default few-shot examples for duet."
  (list
   (list :role "user"
         :content (minuet-duet--render-markers
                   "type User = {
    id: string;
    name: string;
    role?: string;
    active?: boolean;
};

async function buildRequest(user: User, overrides: Record<string, any> = {}) {
    const baseHeaders = { 'content-type': 'application/json' };

{{{:editable_region_start}}}
    const payload = {
        id: user.id,
        name: user.name,
    };

    return {
        method: 'POST',
        headers: baseHeaders,
        body: JSON.stringify(payload{{{:cursor_position}}}),
    };
{{{:editable_region_end}}}
}

export async function sendUser(user: User, overrides = {}) {
    const request = await buildRequest(user, overrides);
    return fetch('/api/users', request);
}"))
   (list :role "assistant"
         :content (minuet-duet--render-markers
                   "{{{:editable_region_start}}}
    const payload = {
        id: user.id,
        name: user.name,
        role: overrides.role ?? user.role ?? \"viewer\",
        active: overrides.active ?? user.active ?? true,
    };

    return {
        method: 'POST',
        headers: {
            ...baseHeaders,
            ...overrides.headers,
        },
        body: JSON.stringify(payload),
        signal: overrides.signal,
        keepalive: overrides.keepalive ?? false,{{{:cursor_position}}}
    };
{{{:editable_region_end}}}"))))

;;;;;
;; Provider option variables
;;;;;

(defvar minuet-duet-openai-options
  `(:model "gpt-5.4-mini"
    :api-key "OPENAI_API_KEY"
    :end-point "https://api.openai.com/v1/chat/completions"
    :system ,minuet-duet-default-system
    :fewshots minuet-duet--default-fewshots
    :chat-input ,minuet-duet-default-chat-input
    :optional nil
    :transform ())
  "Provider options for duet OpenAI backend.")

(defvar minuet-duet-claude-options
  `(:model "claude-haiku-4-5"
    :api-key "ANTHROPIC_API_KEY"
    :end-point "https://api.anthropic.com/v1/messages"
    :max_tokens 8192
    :system ,minuet-duet-default-system
    :fewshots minuet-duet--default-fewshots
    :chat-input ,minuet-duet-default-chat-input
    :optional nil
    :transform ())
  "Provider options for duet Claude backend.")

(defvar minuet-duet-gemini-options
  `(:model "gemini-3-flash-preview"
    :api-key "GEMINI_API_KEY"
    :end-point "https://generativelanguage.googleapis.com/v1beta/models"
    :system ,minuet-duet-default-system
    :fewshots minuet-duet--default-fewshots
    :chat-input ,minuet-duet-default-chat-input
    :optional nil
    :transform ())
  "Provider options for duet Gemini backend.")

(defvar minuet-duet-openai-compatible-options
  `(:model "minimax/minimax-m2.7"
    :api-key "OPENROUTER_API_KEY"
    :end-point "https://openrouter.ai/api/v1/chat/completions"
    :name "Openrouter"
    :system ,minuet-duet-default-system
    :fewshots minuet-duet--default-fewshots
    :chat-input ,minuet-duet-default-chat-input
    :optional nil
    :transform ())
  "Provider options for duet OpenAI-compatible backend.")

;;;;;
;; Buffer-local state
;;;;;

(defvar-local minuet-duet--request-seq 0
  "Monotonically increasing request counter for staleness detection.")

(defvar-local minuet-duet--pending-seq nil
  "Sequence number of the pending duet request, or nil.")

(defvar-local minuet-duet--overlays nil
  "List of active duet preview overlays in this buffer.")

(defvar-local minuet-duet--chars-modified-tick nil
  "Buffer `buffer-chars-modified-tick' when the current preview was computed.")

(defvar-local minuet-duet--region-start nil
  "Buffer position of the editable region start.")

(defvar-local minuet-duet--region-end nil
  "Buffer position of the editable region end.")

(defvar-local minuet-duet--original-lines nil
  "List of original lines in the editable region.")

(defvar-local minuet-duet--proposed-lines nil
  "List of proposed replacement lines.")

(defvar-local minuet-duet--proposed-cursor nil
  "Plist (:row-offset N :col N) for the predicted cursor position.")

(defvar-local minuet-duet--current-request nil
  "The plz process object for the current duet request.")

(defvar-local minuet-duet--after-change-active nil
  "Non-nil when the duet after-change hook is installed.")

;;;;;
;; System prompt builder
;;;;;

(defun minuet-duet--make-system-prompt (template)
  "Build system prompt string from duet TEMPLATE plist.
TEMPLATE must be a plist with :template plus replacement keys."
  (let* ((tmpl (minuet--eval-value (plist-get template :template)))
         (keys (copy-sequence template)))
    (setq keys (plist-put keys :template nil))
    (cl-loop for (key val) on keys by #'cddr
             when key do
             (let* ((rendered (minuet--eval-value val))
                    (rendered (if (stringp rendered) rendered "")))
               (setq tmpl (replace-regexp-in-string
                           (regexp-quote (format "{{{%s}}}" key))
                           rendered tmpl t t))))
    ;; Remove unresolved placeholders
    (replace-regexp-in-string "{{{[^}]*}}}" "" tmpl)))

;;;;;
;; Chat input builder
;;;;;

(defun minuet-duet--make-chat-input (context chat-input)
  "Build the user chat input string from CONTEXT and CHAT-INPUT spec."
  (let* ((template (minuet--eval-value (plist-get chat-input :template)))
         (parts nil))
    (unless (stringp template)
      (setq template ""))
    (cl-loop with last-pos = 0
             for match = (string-match "{{{\\(.+?\\)}}}" template last-pos)
             until (not match)
             for start-pos = (match-beginning 0)
             for end-pos = (match-end 0)
             for key = (match-string 1 template)
             do
             (when (> start-pos last-pos)
               (push (substring template last-pos start-pos) parts))
             (when-let* ((repl-fn (plist-get chat-input (intern key)))
                         (value (funcall repl-fn context)))
               (push value parts))
             (setq last-pos end-pos)
             finally
             (push (substring template last-pos) parts))
    (apply #'concat (nreverse parts))))

;;;;;
;; Context builder
;;;;;

(defun minuet-duet--build-context ()
  "Build duet context plist from the current buffer and point.
Returns a plist with:
  :chars-modified-tick
  :non-editable-region-before
  :editable-region-before-cursor
  :editable-region-after-cursor
  :non-editable-region-after
  :original-lines
  :region-start  (buffer position)
  :region-end    (buffer position)"
  (let* ((lines-before (max minuet-duet-editable-region-lines-before 0))
         (lines-after (max minuet-duet-editable-region-lines-after 0))
         ;; Current line number (1-based)
         (cur-line (line-number-at-pos (point)))
         (total-lines (count-lines (point-min) (point-max)))
         ;; If buffer is empty, ensure at least 1 line
         (total-lines (max total-lines 1))
         ;; Editable region line bounds (1-based, inclusive)
         (start-line (max 1 (- cur-line lines-before)))
         (end-line (min total-lines (+ cur-line lines-after)))
         ;; Convert to positions
         (region-start (save-excursion
                         (goto-char (point-min))
                         (forward-line (1- start-line))
                         (line-beginning-position)))
         (region-end (save-excursion
                       (goto-char (point-min))
                       (forward-line (1- end-line))
                       (line-end-position)))
         ;; Four text segments
         (non-editable-before (buffer-substring-no-properties (point-min) region-start))
         (editable-before-cursor (buffer-substring-no-properties region-start (point)))
         (editable-after-cursor (buffer-substring-no-properties (point) region-end))
         (non-editable-after (buffer-substring-no-properties region-end (point-max)))
         ;; Original lines in editable region
         (editable-text (buffer-substring-no-properties region-start region-end))
         (original-lines (split-string editable-text "\n")))
    (list :chars-modified-tick (buffer-chars-modified-tick)
          :non-editable-region-before non-editable-before
          :editable-region-before-cursor editable-before-cursor
          :editable-region-after-cursor editable-after-cursor
          :non-editable-region-after non-editable-after
          :original-lines original-lines
          :region-start region-start
          :region-end region-end)))

;;;;;
;; Response parser
;;;;;

(defun minuet-duet--count-occurrences (text needle)
  "Count the number of non-overlapping occurrences of NEEDLE in TEXT."
  (let ((count 0)
        (start 0))
    (while (setq start (cl-search needle text :start2 start))
      (cl-incf count)
      (setq start (+ start (length needle))))
    count))

(defun minuet-duet--extract-editable-region (text)
  "Return the editable region content from duet response TEXT.
Return nil and log when the editable region markers are invalid."
  (let ((start-marker minuet-duet-editable-region-start-marker)
        (end-marker minuet-duet-editable-region-end-marker))
    (cond
     ((/= (minuet-duet--count-occurrences text start-marker) 1)
      (minuet--log "Minuet duet: expected exactly one editable region start marker:"
                   minuet-show-error-message-on-minibuffer)
      (minuet--log text)
      nil)
     ((/= (minuet-duet--count-occurrences text end-marker) 1)
      (minuet--log "Minuet duet: expected exactly one editable region end marker:"
                   minuet-show-error-message-on-minibuffer)
      (minuet--log text)
      nil)
     (t
      (let* ((s-start (cl-search start-marker text))
             (s-end (+ s-start (length start-marker)))
             (e-start (cl-search end-marker text :start2 s-end))
             (inner (substring text s-end e-start)))
        ;; Trim one leading and one trailing newline as they are part of the markers' formatting.
        (string-trim inner "\n" "\n"))))))

(defun minuet-duet--trim-duplicated-prefix (inner context)
  "Remove duplicated non-editable prefix CONTEXT from INNER."
  (when-let* ((non-editable-before (plist-get context :non-editable-region-before))
              (non-editable-before (string-trim-right non-editable-before "\n"))
              (should-filter (> minuet-duet-filter-region-before-length 0))
              (match (minuet-find-longest-match inner non-editable-before))
              (should-filter (and (not (string-empty-p match))
                                  (>= (length match)
                                      minuet-duet-filter-region-before-length))))
    (setq inner (substring inner (length match)))
    ;; Drop the separator newline left behind by line-oriented prefix dedup.
    (setq inner (string-trim-left inner "\n")))
  inner)

(defun minuet-duet--remove-cursor-marker (inner)
  "Return (TEXT . CURSOR-POS) for editable region INNER.
If INNER has no cursor marker, place the cursor at the end and log the
fallback.  Return nil and log when INNER has multiple cursor markers."
  (let* ((cursor-marker minuet-duet-cursor-position-marker)
         (cursor-count (minuet-duet--count-occurrences inner cursor-marker))
         (c-pos (cl-search cursor-marker inner)))
    (cond
     ((= cursor-count 0)
      (minuet--log "Minuet duet: cursor marker missing; using editable region end")
      (cons inner (length inner)))
     ((= cursor-count 1)
      (cons (concat (substring inner 0 c-pos)
                    (substring inner (+ c-pos (length cursor-marker))))
            c-pos))
     (t
      (minuet--log "Minuet duet: expected at most one cursor marker inside editable region"
                   minuet-show-error-message-on-minibuffer)
      (minuet--log inner)
      nil))))

(defun minuet-duet--trim-duplicated-suffix (text context)
  "Remove duplicated non-editable suffix CONTEXT from TEXT."
  (when-let* ((non-editable-after (plist-get context :non-editable-region-after))
              (non-editable-after (string-trim-left non-editable-after "\n"))
              (should-filter (> minuet-duet-filter-region-after-length 0))
              (match (minuet-find-longest-match non-editable-after text))
              (should-filter (and (not (string-empty-p match))
                                  (>= (length match)
                                      minuet-duet-filter-region-after-length))))
    (setq text (substring text 0 (- (length text) (length match))))
    ;; Drop the separator newline left behind by line-oriented suffix dedup.
    (setq text (string-trim-right text "\n")))
  text)

(defun minuet-duet--build-lines-and-cursor-result (text cursor-pos)
  "Build the parser return value for TEXT with cursor at CURSOR-POS."
  (setq cursor-pos (min cursor-pos (length text)))
  (let* ((cursor-prefix (substring text 0 cursor-pos))
         (cursor-lines (split-string cursor-prefix "\n"))
         (replacement-lines (split-string text "\n"))
         (row-offset (1- (length cursor-lines)))
         (col (length (car (last cursor-lines)))))
    (cons replacement-lines
          (list :row-offset row-offset :col col))))

(cl-defun minuet-duet--parse-response (text &optional context)
  "Parse a duet LLM response TEXT.
CONTEXT is an optional plist with :non-editable-region-before and
:non-editable-region-after fields, used to filter duplicated text
from the editable region.
Returns (LINES . CURSOR) on success where LINES is a list of
replacement strings and CURSOR is (:row-offset N :col N).
Returns nil on failure and logs the reason."
  (when (or (not (stringp text)) (string-empty-p text))
    (minuet--log "Minuet duet: empty response")
    (cl-return-from minuet-duet--parse-response nil))
  (when-let* ((inner (minuet-duet--extract-editable-region text))
              (inner (minuet-duet--trim-duplicated-prefix inner context))
              (cursor-state (minuet-duet--remove-cursor-marker inner))
              (text-without-cursor
               (minuet-duet--trim-duplicated-suffix (car cursor-state)
                                                    context)))
    (minuet-duet--build-lines-and-cursor-result text-without-cursor
                                                (cdr cursor-state))))

;;;;;
;; Preview rendering
;;;;;

(defun minuet-duet--clear-overlays ()
  "Remove all duet preview overlays in the current buffer."
  (dolist (ov minuet-duet--overlays)
    (when (overlay-buffer ov)
      (delete-overlay ov)))
  (setq minuet-duet--overlays nil))

(defun minuet-duet--make-overlay (beg end &rest props)
  "Create a duet overlay from BEG to END with PROPS, and track it."
  (let ((ov (make-overlay beg end)))
    (while props
      (overlay-put ov (pop props) (pop props)))
    (push ov minuet-duet--overlays)
    ov))

(defun minuet-duet--append-overlay-string (overlay property suffix)
  "Append SUFFIX to OVERLAY PROPERTY."
  (overlay-put overlay property
               (concat (or (overlay-get overlay property) "")
                       suffix)))

(defun minuet-duet--make-chunks (text hl-face cursor-col cursor-char)
  "Build a propertized string for TEXT with HL-FACE.
When CURSOR-COL is non-nil, insert CURSOR-CHAR at that byte
position with `minuet-duet-cursor-face'."
  (if (null cursor-col)
      (propertize text 'face hl-face)
    (let ((before (substring text 0 (min cursor-col (length text))))
          (after (substring text (min cursor-col (length text)))))
      (concat
       (when (> (length before) 0)
         (propertize before 'face hl-face))
       (propertize cursor-char 'face 'minuet-duet-cursor-face)
       (when (> (length after) 0)
         (propertize after 'face hl-face))))))

(defun minuet-duet--cursor-col-for (proposed-idx)
  "Return cursor column if PROPOSED-IDX (0-based) carries the cursor, else nil."
  (when-let* ((c minuet-duet--proposed-cursor)
              (matches (= proposed-idx (plist-get c :row-offset))))
    (plist-get c :col)))

(defun minuet-duet--line-bol (pos)
  "Return the beginning-of-line position for POS."
  (save-excursion (goto-char pos) (line-beginning-position)))

(defun minuet-duet--line-eol (pos)
  "Return the end-of-line position for POS."
  (save-excursion (goto-char pos) (line-end-position)))

(defun minuet-duet--nth-line-pos (region-start n)
  "Return the beginning of the Nth line (0-based) from REGION-START."
  (save-excursion
    (goto-char region-start)
    (forward-line n)
    (point)))

(defun minuet-duet--render-hunk (hunk cursor-char)
  "Render a single diff HUNK using overlays.
HUNK is a plist from `minuet-diff-line-hunks'.
CURSOR-CHAR is the cursor glyph string."
  (let* ((orig-start (plist-get hunk :original-start))
         (orig-count (plist-get hunk :original-count))
         (prop-start (plist-get hunk :proposed-start))
         (prop-count (plist-get hunk :proposed-count))
         (pair-count (min orig-count prop-count))
         (region-start minuet-duet--region-start)
         (original-line-count (length minuet-duet--original-lines))
         (last-paired-overlay nil))
    ;; Replaced lines: mark original with delete-face, show proposed at eol
    (dotimes (offset pair-count)
      (let* ((buf-line-start (minuet-duet--nth-line-pos region-start (+ orig-start offset)))
             (buf-line-end (minuet-duet--line-eol buf-line-start))
             (proposed-idx (+ prop-start offset))
             (col (minuet-duet--cursor-col-for proposed-idx))
             (chunks (minuet-duet--make-chunks
                      (or (nth proposed-idx minuet-duet--proposed-lines) "")
                      'minuet-duet-add-face col cursor-char)))
        (setq last-paired-overlay
              (minuet-duet--make-overlay buf-line-start buf-line-end
                                         'face 'minuet-duet-delete-face
                                         'after-string chunks))))
    ;; Extra deleted lines (orig-count > pair-count)
    (cl-loop for offset from pair-count below orig-count do
             (let* ((buf-line-start (minuet-duet--nth-line-pos region-start (+ orig-start offset)))
                    (buf-line-end (minuet-duet--line-eol buf-line-start)))
               (minuet-duet--make-overlay buf-line-start buf-line-end
                                          'face 'minuet-duet-delete-face)))
    ;; Extra inserted lines (prop-count > pair-count)
    (when (> prop-count pair-count)
      (let ((virt-text
             (mapconcat
              (lambda (offset)
                (let* ((proposed-idx (+ prop-start offset))
                       (col (minuet-duet--cursor-col-for proposed-idx)))
                  (minuet-duet--make-chunks
                   (or (nth proposed-idx minuet-duet--proposed-lines) "")
                   'minuet-duet-add-face col cursor-char)))
              (number-sequence pair-count (1- prop-count))
              "\n")))
        (cond
         ;; Append to existing paired overlay.  When multiple
         ;; `after-string' overlays share an anchor on an indented blank
         ;; line, Emacs can render them out of order.
         ((and (> orig-count 0) last-paired-overlay)
          (minuet-duet--append-overlay-string last-paired-overlay 'after-string
                                              (concat "\n" virt-text)))
         ;; Empty original buffer — place before region-start
         ((= original-line-count 0)
          (minuet-duet--make-overlay region-start region-start
                                     'before-string virt-text))
         ;; Insert before the anchor line
         ((< orig-start original-line-count)
          (let ((anchor (minuet-duet--nth-line-pos region-start orig-start)))
            (minuet-duet--make-overlay anchor anchor
                                       'before-string (concat virt-text "\n"))))
         ;; Append after the last original line
         (t
          (let ((anchor (minuet-duet--line-eol
                         (minuet-duet--nth-line-pos region-start (1- original-line-count)))))
            (minuet-duet--make-overlay anchor anchor
                                       'after-string (concat "\n" virt-text)))))))))

(defun minuet-duet--render-cursor-on-unchanged-line (hunks cursor-char)
  "Render the cursor on an unchanged line not covered by any HUNKS.
CURSOR-CHAR is the cursor glyph string."
  (when-let* ((c minuet-duet--proposed-cursor)
              (proposed-row (plist-get c :row-offset))
              ;; Bail out if cursor row falls inside any hunk
              (not-in-hunk
               (not (cl-loop for h in hunks
                             for ps = (plist-get h :proposed-start)
                             for pc = (plist-get h :proposed-count)
                             thereis (and (>= proposed-row ps)
                                          (< proposed-row (+ ps pc))))))
              ;; Map proposed row to original row by undoing cumulative shift
              (shift (cl-loop for h in hunks
                              for oc = (plist-get h :original-count)
                              for ps = (plist-get h :proposed-start)
                              for pc = (plist-get h :proposed-count)
                              when (<= (+ ps pc) proposed-row)
                              sum (- pc oc)))
              (original-row (- proposed-row shift))
              (buf-line-start (minuet-duet--nth-line-pos minuet-duet--region-start original-row))
              (buf-line-end (minuet-duet--line-eol buf-line-start))
              (line-text (or (nth proposed-row minuet-duet--proposed-lines) ""))
              (chunks (minuet-duet--make-chunks line-text 'shadow (plist-get c :col) cursor-char)))
    (minuet-duet--make-overlay buf-line-end buf-line-end
                               'after-string chunks)))

(defun minuet-duet--render-preview ()
  "Render the duet preview overlays for the current prediction."
  (minuet-duet--clear-overlays)
  (let* ((hunks (minuet-diff-line-hunks minuet-duet--original-lines
                                        minuet-duet--proposed-lines))
         (cursor-char minuet-duet-preview-cursor))
    (if hunks
        (dolist (hunk hunks)
          (minuet-duet--render-hunk hunk cursor-char))
      (unless minuet-duet--proposed-cursor
        (minuet--log "Minuet duet predicts no text changes."
                     minuet-show-error-message-on-minibuffer)))
    (minuet-duet--render-cursor-on-unchanged-line hunks cursor-char)
    (minuet-duet-active-mode (if (minuet-duet-visible-p) 1 -1))))

;;;;;
;; After-change hook
;;;;;

(defun minuet-duet--on-after-change (_beg _end _len)
  "Clear duet preview/state when the buffer is modified."
  (minuet-duet--clear-state))

(defun minuet-duet--install-after-change-hook ()
  "Install the duet after-change hook if not already active."
  (unless minuet-duet--after-change-active
    (add-hook 'after-change-functions #'minuet-duet--on-after-change nil t)
    (setq minuet-duet--after-change-active t)))

(defun minuet-duet--remove-after-change-hook ()
  "Remove the duet after-change hook."
  (when minuet-duet--after-change-active
    (remove-hook 'after-change-functions #'minuet-duet--on-after-change t)
    (setq minuet-duet--after-change-active nil)))

;;;;;
;; State management
;;;;;

(defun minuet-duet--cancel-request ()
  "Cancel the current duet request if any."
  (when (and minuet-duet--current-request
             (process-live-p minuet-duet--current-request))
    (minuet--log "Minuet duet: terminating pending request")
    (signal-process minuet-duet--current-request 'SIGTERM))
  (setq minuet-duet--current-request nil))

(defun minuet-duet--clear-state ()
  "Clear all duet state: cancel request, remove overlays, reset variables."
  (minuet-duet--cancel-request)
  (minuet-duet--clear-overlays)
  (minuet-duet--remove-after-change-hook)
  (minuet-duet-active-mode -1)
  (setq minuet-duet--pending-seq nil
        minuet-duet--chars-modified-tick nil
        minuet-duet--region-start nil
        minuet-duet--region-end nil
        minuet-duet--original-lines nil
        minuet-duet--proposed-lines nil
        minuet-duet--proposed-cursor nil))

;;;;;
;; Request backends
;;;;;

(defun minuet-duet--openai-complete-base (options context callback)
  "Send a duet request using OpenAI-compatible API.
OPTIONS is the provider plist, CONTEXT from `minuet-duet--build-context',
CALLBACK receives the full response text or nil."
  (let* ((system (minuet-duet--make-system-prompt (plist-get options :system)))
         (prompt (minuet-duet--make-chat-input context (plist-get options :chat-input)))
         (fewshots (copy-tree (minuet--eval-value (plist-get options :fewshots))))
         (messages (vconcat
                    `((:role "system" :content ,system))
                    fewshots
                    `((:role "user" :content ,prompt))))
         (end-point (plist-get options :end-point))
         (body `(,@(plist-get options :optional)
                 :stream t
                 :model ,(plist-get options :model)
                 :messages ,messages))
         (headers `(("Content-Type" . "application/json")
                    ("Accept" . "application/json")
                    ("Authorization" . ,(concat "Bearer " (minuet--get-api-key (plist-get options :api-key))))))
         (transformed (minuet--apply-request-transform options end-point headers body))
         (end-point (plist-get transformed :end-point))
         (headers (plist-get transformed :headers))
         (body-json (json-serialize (plist-get transformed :body))))
    (minuet--with-temp-response
      (setq minuet-duet--current-request
            (plz 'post end-point
              :headers headers
              :timeout minuet-duet-request-timeout
              :body body-json
              :as 'string
              :filter (minuet--make-process-stream-filter --response--)
              :then
              (lambda (json)
                (setq minuet-duet--current-request nil)
                (let ((text (minuet--stream-decode json #'minuet--openai-get-text-fn)))
                  (funcall callback text)))
              :else
              (lambda (err)
                (setq minuet-duet--current-request nil)
                (if (equal (car (plz-error-curl-error err)) 28)
                    (progn
                      (minuet--log "Minuet duet OpenAI: request timeout")
                      (let ((text (minuet--stream-decode-raw --response-- #'minuet--openai-get-text-fn)))
                        (funcall callback text)))
                  (minuet--log "Minuet duet OpenAI: request error"
                               minuet-show-error-message-on-minibuffer)
                  (minuet--log err)
                  (funcall callback nil))))))))

(defun minuet-duet--openai-complete (context callback)
  "Send a duet request using OpenAI API.
CONTEXT is the chat context from `minuet-duet--build-context'.
CALLBACK is a function that receives the full response text or nil."
  (minuet-duet--openai-complete-base minuet-duet-openai-options context callback))

(defun minuet-duet--openai-compatible-complete (context callback)
  "Send a duet request using an OpenAI-compatible API.
CONTEXT is the chat context from `minuet-duet--build-context'.
CALLBACK is a function that receives the full response text or nil."
  (minuet-duet--openai-complete-base minuet-duet-openai-compatible-options
                                     context callback))

(cl-defun minuet-duet--claude-complete (context callback)
  "Send a duet request using Claude API.
CONTEXT and CALLBACK as in `minuet-duet--openai-complete-base'."
  (let* ((options (copy-tree minuet-duet-claude-options))
         (api-key (minuet--get-api-key (plist-get options :api-key))))
    (unless api-key
      (minuet--log "Minuet duet: Anthropic API key is not set"
                   minuet-show-error-message-on-minibuffer)
      (funcall callback nil)
      (cl-return-from minuet-duet--claude-complete))
    (let* ((system (minuet-duet--make-system-prompt (plist-get options :system)))
           (prompt (minuet-duet--make-chat-input context (plist-get options :chat-input)))
           (fewshots (copy-tree (minuet--eval-value (plist-get options :fewshots))))
           (messages (vconcat fewshots `((:role "user" :content ,prompt))))
           (end-point (plist-get options :end-point))
           (body `(,@(plist-get options :optional)
                   :stream t
                   :model ,(plist-get options :model)
                   :system ,system
                   :max_tokens ,(plist-get options :max_tokens)
                   :messages ,messages))
           (headers `(("Content-Type" . "application/json")
                      ("x-api-key" . ,api-key)
                      ("anthropic-version" . "2023-06-01")))
           (transformed (minuet--apply-request-transform options end-point headers body))
           (end-point (plist-get transformed :end-point))
           (headers (plist-get transformed :headers))
           (body-json (json-serialize (plist-get transformed :body))))
      (minuet--with-temp-response
        (setq minuet-duet--current-request
              (plz 'post end-point
                :headers headers
                :timeout minuet-duet-request-timeout
                :body body-json
                :as 'string
                :filter (minuet--make-process-stream-filter --response--)
                :then
                (lambda (json)
                  (setq minuet-duet--current-request nil)
                  (let ((text (minuet--stream-decode json #'minuet--claude-get-text-fn)))
                    (funcall callback text)))
                :else
                (lambda (err)
                  (setq minuet-duet--current-request nil)
                  (if (equal (car (plz-error-curl-error err)) 28)
                      (progn
                        (minuet--log "Minuet duet Claude: request timeout")
                        (let ((text (minuet--stream-decode-raw --response-- #'minuet--claude-get-text-fn)))
                          (funcall callback text)))
                    (minuet--log "Minuet duet Claude: request error"
                                 minuet-show-error-message-on-minibuffer)
                    (minuet--log err)
                    (funcall callback nil)))))))))

(cl-defun minuet-duet--gemini-complete (context callback)
  "Send a duet request using Gemini API.
CONTEXT and CALLBACK as in `minuet-duet--openai-complete-base'."
  (let* ((options (copy-tree minuet-duet-gemini-options))
         (api-key (minuet--get-api-key (plist-get options :api-key))))
    (unless api-key
      (minuet--log "Minuet duet: Gemini API key is not set"
                   minuet-show-error-message-on-minibuffer)
      (funcall callback nil)
      (cl-return-from minuet-duet--gemini-complete))
    (let* ((system (minuet-duet--make-system-prompt (plist-get options :system)))
           (prompt (minuet-duet--make-chat-input context (plist-get options :chat-input)))
           (fewshots (minuet--eval-value (plist-get options :fewshots)))
           (fewshots (minuet--transform-openai-chat-to-gemini-chat (copy-tree fewshots)))
           (messages (vconcat fewshots
                              `((:role "user" :parts [(:text ,prompt)]))))
           (end-point (format "%s/%s:streamGenerateContent?alt=sse"
                              (plist-get options :end-point)
                              (plist-get options :model)))
           (body `(,@(plist-get options :optional)
                   :system_instruction (:parts (:text ,system))
                   :contents ,messages))
           (headers `(("Content-Type" . "application/json")
                      ("x-goog-api-key" . ,api-key)
                      ("Accept" . "application/json")))
           (transformed (minuet--apply-request-transform options end-point headers body))
           (end-point (plist-get transformed :end-point))
           (headers (plist-get transformed :headers))
           (body-json (json-serialize (plist-get transformed :body))))
      (minuet--with-temp-response
        (setq minuet-duet--current-request
              (plz 'post end-point
                :headers headers
                :timeout minuet-duet-request-timeout
                :body body-json
                :as 'string
                :filter (minuet--make-process-stream-filter --response--)
                :then
                (lambda (json)
                  (setq minuet-duet--current-request nil)
                  (let ((text (minuet--stream-decode json #'minuet--gemini-get-text-fn)))
                    (funcall callback text)))
                :else
                (lambda (err)
                  (setq minuet-duet--current-request nil)
                  (if (equal (car (plz-error-curl-error err)) 28)
                      (progn
                        (minuet--log "Minuet duet Gemini: request timeout")
                        (let ((text (minuet--stream-decode-raw --response-- #'minuet--gemini-get-text-fn)))
                          (funcall callback text)))
                    (minuet--log "Minuet duet Gemini: request error"
                                 minuet-show-error-message-on-minibuffer)
                    (minuet--log err)
                    (funcall callback nil)))))))))

;;;;;
;; Prediction lifecycle
;;;;;

;;;###autoload
(defun minuet-duet-predict ()
  "Request a duet (next-edit) prediction for the region around point."
  (interactive)
  (minuet-duet--clear-state)
  (let* ((context (minuet-duet--build-context))
         (buffer (current-buffer))
         (provider minuet-duet-provider)
         (complete-fn (intern (format "minuet-duet--%s-complete" provider)))
         (chars-modified-tick (plist-get context :chars-modified-tick))
         (region-start (plist-get context :region-start))
         (region-end (plist-get context :region-end))
         (original-lines (plist-get context :original-lines))
         (seq (cl-incf minuet-duet--request-seq)))
    (setq minuet-duet--pending-seq seq)
    (minuet-duet--install-after-change-hook)
    (funcall
     complete-fn context
     (lambda (text)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (eq minuet-duet--pending-seq seq)
             (setq minuet-duet--pending-seq nil)
             (cond
              ((not text) nil)
              ((/= (buffer-chars-modified-tick) chars-modified-tick)
               (minuet--log "Minuet duet: result arrived after buffer changed; discarded."))
              (t
               (if-let* ((parsed (minuet-duet--parse-response text context)))
                   (progn
                     (setq minuet-duet--chars-modified-tick chars-modified-tick
                           minuet-duet--region-start region-start
                           minuet-duet--region-end region-end
                           minuet-duet--original-lines original-lines
                           minuet-duet--proposed-lines (car parsed)
                           minuet-duet--proposed-cursor (cdr parsed))
                     (minuet-duet--render-preview))
                 (minuet--log "Minuet duet: invalid response"
                              minuet-show-error-message-on-minibuffer)))))))))))

;;;###autoload
(cl-defun minuet-duet-apply ()
  "Apply the current duet prediction, replacing the editable region."
  (interactive)
  (unless (and minuet-duet--proposed-lines
               minuet-duet--region-start
               minuet-duet--region-end
               minuet-duet--proposed-cursor)
    (minuet--log "No Minuet duet prediction to apply." t)
    (cl-return-from minuet-duet-apply))
  (unless (= (buffer-chars-modified-tick) minuet-duet--chars-modified-tick)
    (minuet-duet--clear-state)
    (minuet--log "Minuet duet prediction is stale and has been discarded." t)
    (cl-return-from minuet-duet-apply))
  (let ((region-start minuet-duet--region-start)
        (region-end minuet-duet--region-end)
        (new-text (mapconcat #'identity minuet-duet--proposed-lines "\n"))
        (cursor-offset (let* ((c minuet-duet--proposed-cursor)
                              (row (plist-get c :row-offset))
                              (col (plist-get c :col))
                              (lines minuet-duet--proposed-lines)
                              (char-offset 0))
                         (dotimes (i row)
                           (setq char-offset (+ char-offset (length (nth i lines)) 1)))
                         (+ char-offset (min col (length (nth row lines)))))))
    ;; Remove the after-change hook to avoid recursive clear
    (minuet-duet--remove-after-change-hook)
    (minuet-duet--clear-overlays)
    ;; Replace text
    (replace-region-contents region-start region-end
                             (lambda () new-text))
    ;; Move point to predicted cursor
    (goto-char (+ region-start cursor-offset))
    ;; Reset state
    (minuet-duet-active-mode -1)
    (setq minuet-duet--pending-seq nil
          minuet-duet--chars-modified-tick nil
          minuet-duet--region-start nil
          minuet-duet--region-end nil
          minuet-duet--original-lines nil
          minuet-duet--proposed-lines nil
          minuet-duet--proposed-cursor nil)))

;;;###autoload
(defun minuet-duet-dismiss ()
  "Dismiss the current duet prediction."
  (interactive)
  (minuet-duet--clear-state))

(defun minuet-duet-visible-p ()
  "Return non-nil if a duet preview is currently visible."
  (and minuet-duet--overlays
       (cl-some (lambda (ov) (overlay-buffer ov)) minuet-duet--overlays)))

(provide 'minuet-duet)
;;; minuet-duet.el ends here
