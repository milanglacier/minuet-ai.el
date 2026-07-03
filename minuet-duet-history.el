;;; minuet-duet-history.el --- Recent edit history for minuet-duet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

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

;; Per-buffer recent edit history tracking for minuet-duet.
;;
;; Enable `minuet-duet-history-mode' in a buffer to record the user's
;; recent edits as unified diffs.  The `after-change-functions' hook
;; only sets a dirty flag; the actual diff between the previous
;; snapshot and the current buffer content is computed by a repeating
;; idle timer, producing one coalesced history entry per editing
;; burst.  `minuet-duet-predict' flushes pending edits synchronously
;; before building its context, and includes the formatted history in
;; the prompt via `minuet-duet-history-prompt-text'.

;;; Code:

(require 'cl-lib)
(require 'minuet-diff)
(require 'minuet)

;;;;;
;; Customization
;;;;;

(defcustom minuet-duet-history-idle-delay 1.5
  "Idle seconds before pending edits are flushed into a history entry.
The value is read when the shared idle timer is created, i.e. when
tracking starts in the first buffer.  Changing it while buffers are
tracked takes effect only after the mode is disabled in all of them."
  :type 'number
  :group 'minuet-duet)

(defcustom minuet-duet-history-max-entries 8
  "Maximum number of history entries kept per buffer.
The oldest entries are dropped first."
  :type 'integer
  :group 'minuet-duet)

(defcustom minuet-duet-history-max-region-lines 200
  "Maximum changed-region size (in lines) recorded as a history entry.

After trimming the common leading and trailing lines between the
previous snapshot and the current buffer content, if either remaining
middle region exceeds this many lines, the edit is skipped (the
snapshot is still updated).  This bounds the diff cost and avoids
recording mass edits such as large pastes, reverts, or whole-buffer
reformatting, which are poor signals of user intent."
  :type 'integer
  :group 'minuet-duet)

(defcustom minuet-duet-history-diff-context-lines 2
  "Number of unchanged context lines around each hunk in history diffs.
Hunks whose context ranges touch or overlap are merged into a single
hunk group."
  :type 'integer
  :group 'minuet-duet)

(defcustom minuet-duet-history-max-prompt-chars 6000
  "Maximum total characters of edit history included in duet prompts.
The newest entry is always included; older entries are added until
this budget is exhausted."
  :type 'integer
  :group 'minuet-duet)

(defcustom minuet-duet-history-max-buffer-size 1000000
  "Buffers larger than this many characters are not tracked.
`minuet-duet-history-mode' refuses to enable in such buffers, and
auto-disables if a tracked buffer grows past this size."
  :type 'integer
  :group 'minuet-duet)

;;;;;
;; State
;;;;;

(defvar minuet-duet-history--timer nil
  "Repeating idle timer that flushes pending edits, or nil.")

(defvar minuet-duet-history--buffers nil
  "List of live buffers with `minuet-duet-history-mode' enabled.")

(defvar-local minuet-duet-history--snapshot-lines nil
  "Vector of buffer lines at the last snapshot.")

(defvar-local minuet-duet-history--snapshot-tick nil
  "Buffer `buffer-chars-modified-tick' at the last snapshot.")

(defvar-local minuet-duet-history--dirty nil
  "Non-nil when the buffer changed since the last flush.")

(defvar-local minuet-duet-history--entries nil
  "List of formatted unified diff strings, newest first.")

;;;;;
;; Pure helpers
;;;;;

(defun minuet-duet-history--common-affixes (old new)
  "Return (PREFIX-LEN . SUFFIX-LEN) of common affix lines of OLD and NEW.
OLD and NEW are vectors of lines.  SUFFIX-LEN is clamped so that the
prefix and suffix regions never overlap in either vector."
  (let* ((old-len (length old))
         (new-len (length new))
         (max-affix (min old-len new-len))
         (prefix 0))
    (while (and (< prefix max-affix)
                (equal (aref old prefix) (aref new prefix)))
      (cl-incf prefix))
    (let ((suffix 0)
          (max-suffix (- max-affix prefix)))
      (while (and (< suffix max-suffix)
                  (equal (aref old (- old-len suffix 1))
                         (aref new (- new-len suffix 1))))
        (cl-incf suffix))
      (cons prefix suffix))))

(defun minuet-duet-history--format-udiff (old new prefix hunks n-context)
  "Format HUNKS as a unified diff string between OLD and NEW.

OLD and NEW are vectors of lines holding the full old and new buffer
contents.  HUNKS are as returned by `minuet-diff-line-hunks', computed
on the middle regions obtained by removing PREFIX common leading lines
and any number of common trailing lines from both.  N-CONTEXT unchanged
lines are shown around each hunk; hunks whose context ranges touch or
overlap are merged into a single @@ group.  Line numbers in @@ headers
are 1-based."
  (let* ((n-context (max 0 n-context))
         (abs-hunks
          (mapcar (lambda (h)
                    (list :a-start (+ prefix (plist-get h :original-start))
                          :a-count (plist-get h :original-count)
                          :b-start (+ prefix (plist-get h :proposed-start))
                          :b-count (plist-get h :proposed-count)))
                  hunks))
         (groups nil))
    ;; Group hunks whose expanded context ranges touch or overlap.
    (dolist (hunk abs-hunks)
      (if (and groups
               (let ((prev (caar groups)))
                 (<= (- (plist-get hunk :a-start)
                        (+ (plist-get prev :a-start) (plist-get prev :a-count)))
                     (* 2 n-context))))
          (setcar groups (cons hunk (car groups)))
        (push (list hunk) groups)))
    (setq groups (mapcar #'nreverse (nreverse groups)))
    (mapconcat
     (lambda (group)
       (let* ((first (car group))
              (last (car (last group)))
              (a-start (plist-get first :a-start))
              (b-start (plist-get first :b-start))
              (a-end (+ (plist-get last :a-start) (plist-get last :a-count)))
              (b-end (+ (plist-get last :b-start) (plist-get last :b-count)))
              (before (min n-context a-start b-start))
              (after (min n-context
                          (- (length old) a-end)
                          (- (length new) b-end)))
              (start-a (- a-start before))
              (start-b (- b-start before))
              (count-a (+ before (- a-end a-start) after))
              (count-b (+ before (- b-end b-start) after))
              (lines nil))
         (push (format "@@ -%d,%d +%d,%d @@"
                       (if (> count-a 0) (1+ start-a) start-a) count-a
                       (if (> count-b 0) (1+ start-b) start-b) count-b)
               lines)
         (cl-loop for i from start-a below a-start
                  do (push (concat " " (aref old i)) lines))
         (cl-loop for (hunk . rest) on group do
                  (cl-loop for i from (plist-get hunk :a-start)
                           below (+ (plist-get hunk :a-start)
                                    (plist-get hunk :a-count))
                           do (push (concat "-" (aref old i)) lines))
                  (cl-loop for i from (plist-get hunk :b-start)
                           below (+ (plist-get hunk :b-start)
                                    (plist-get hunk :b-count))
                           do (push (concat "+" (aref new i)) lines))
                  (when rest
                    (cl-loop for i from (+ (plist-get hunk :a-start)
                                           (plist-get hunk :a-count))
                             below (plist-get (car rest) :a-start)
                             do (push (concat " " (aref old i)) lines))))
         (cl-loop for i from a-end below (+ a-end after)
                  do (push (concat " " (aref old i)) lines))
         (mapconcat #'identity (nreverse lines) "\n")))
     groups
     "\n")))

(defun minuet-duet-history--push-entry (entry)
  "Push ENTRY onto the buffer's history, dropping the oldest past the cap."
  (push entry minuet-duet-history--entries)
  (setq minuet-duet-history--entries
        (seq-take minuet-duet-history--entries
                  minuet-duet-history-max-entries)))

;;;;;
;; Snapshot & flush
;;;;;

(defun minuet-duet-history--buffer-lines ()
  "Return the whole buffer content as a vector of lines.
The buffer is widened so that snapshots and diffs are unaffected by
narrowing; otherwise narrowing between flushes would record the hidden
text as a spurious mass deletion or insertion."
  (save-restriction
    (widen)
    (vconcat (split-string
              (buffer-substring-no-properties (point-min) (point-max)) "\n"))))

(defun minuet-duet-history--take-snapshot ()
  "Snapshot the current buffer content and modification tick."
  (setq minuet-duet-history--snapshot-lines (minuet-duet-history--buffer-lines)
        minuet-duet-history--snapshot-tick (buffer-chars-modified-tick)
        minuet-duet-history--dirty nil))

(defun minuet-duet-history--flush-buffer ()
  "Record pending edits in the current buffer as a history entry.
Diffs the buffer content against the last snapshot and updates the
snapshot.  Does nothing when nothing changed since the last flush."
  (when (and minuet-duet-history-mode minuet-duet-history--dirty)
    (setq minuet-duet-history--dirty nil)
    (if (> (buffer-size) minuet-duet-history-max-buffer-size)
        (progn
          (minuet-duet-history-mode -1)
          (minuet--log
           (format "Minuet duet history: buffer %s exceeds `minuet-duet-history-max-buffer-size'; tracking disabled."
                   (buffer-name))))
      (let ((tick (buffer-chars-modified-tick)))
        ;; Unchanged tick means property-only changes; nothing to record.
        (unless (eql tick minuet-duet-history--snapshot-tick)
          (let* ((old minuet-duet-history--snapshot-lines)
                 (new (minuet-duet-history--buffer-lines))
                 (affixes (minuet-duet-history--common-affixes old new))
                 (prefix (car affixes))
                 (suffix (cdr affixes))
                 (old-mid-len (- (length old) prefix suffix))
                 (new-mid-len (- (length new) prefix suffix)))
            (if (> (max old-mid-len new-mid-len)
                   minuet-duet-history-max-region-lines)
                (minuet--log
                 (format "Minuet duet history: edit in %s exceeds `minuet-duet-history-max-region-lines'; skipped."
                         (buffer-name)))
              (when-let* ((hunks (minuet-diff-line-hunks
                                  (cl-subseq old prefix (- (length old) suffix))
                                  (cl-subseq new prefix (- (length new) suffix)))))
                (minuet-duet-history--push-entry
                 (minuet-duet-history--format-udiff
                  old new prefix hunks
                  minuet-duet-history-diff-context-lines))))
            (setq minuet-duet-history--snapshot-lines new
                  minuet-duet-history--snapshot-tick tick)))))))

(defun minuet-duet-history--flush-all ()
  "Flush pending edits in all tracked buffers.
Prunes dead buffers and buffers where the mode is no longer enabled."
  (dolist (buffer (copy-sequence minuet-duet-history--buffers))
    (if (not (and (buffer-live-p buffer)
                  (buffer-local-value 'minuet-duet-history-mode buffer)))
        (minuet-duet-history--deregister buffer)
      (with-current-buffer buffer
        (condition-case err
            (minuet-duet-history--flush-buffer)
          (error
           (minuet--log
            (format "Minuet duet history: flush error in %s: %s"
                    (buffer-name buffer) (error-message-string err)))))))))

;;;;;
;; Hooks & timer lifecycle
;;;;;

(defun minuet-duet-history--on-change (_beg _end _len)
  "Mark the buffer as having pending edits."
  (setq minuet-duet-history--dirty t))

(defun minuet-duet-history--on-kill-buffer ()
  "Deregister the current buffer from history tracking."
  (minuet-duet-history--deregister (current-buffer)))

(defun minuet-duet-history--register (buffer)
  "Register BUFFER for tracking and ensure the idle timer is running."
  (cl-pushnew buffer minuet-duet-history--buffers)
  (unless minuet-duet-history--timer
    (setq minuet-duet-history--timer
          (run-with-idle-timer minuet-duet-history-idle-delay t
                               #'minuet-duet-history--flush-all))))

(defun minuet-duet-history--deregister (buffer)
  "Deregister BUFFER; cancel the idle timer when no buffers remain."
  (setq minuet-duet-history--buffers
        (delq buffer minuet-duet-history--buffers))
  (when (and (null minuet-duet-history--buffers)
             minuet-duet-history--timer)
    (cancel-timer minuet-duet-history--timer)
    (setq minuet-duet-history--timer nil)))

;;;###autoload
(define-minor-mode minuet-duet-history-mode
  "Track recent edits in this buffer for duet next-edit prediction.

While enabled, edits are recorded as unified diffs, one coalesced
entry per editing burst, computed on idle.  `minuet-duet-predict'
includes the recorded history in its prompt so the model can infer the
user's intent from what they have been doing."
  :init-value nil
  :lighter nil
  (if minuet-duet-history-mode
      (cond
       ;; Re-enabling in an already-tracked buffer keeps the recorded
       ;; history instead of wiping it (e.g. a mode hook re-firing).
       ((memq (current-buffer) minuet-duet-history--buffers))
       ((> (buffer-size) minuet-duet-history-max-buffer-size)
        (setq minuet-duet-history-mode nil)
        (minuet--log
         (format "Minuet duet history: buffer %s exceeds `minuet-duet-history-max-buffer-size'; not tracking."
                 (buffer-name))
         t))
       (t
        (setq minuet-duet-history--entries nil)
        (minuet-duet-history--take-snapshot)
        (add-hook 'after-change-functions #'minuet-duet-history--on-change nil t)
        (add-hook 'kill-buffer-hook #'minuet-duet-history--on-kill-buffer nil t)
        (minuet-duet-history--register (current-buffer))))
    (remove-hook 'after-change-functions #'minuet-duet-history--on-change t)
    (remove-hook 'kill-buffer-hook #'minuet-duet-history--on-kill-buffer t)
    (setq minuet-duet-history--snapshot-lines nil
          minuet-duet-history--snapshot-tick nil
          minuet-duet-history--dirty nil
          minuet-duet-history--entries nil)
    (minuet-duet-history--deregister (current-buffer))))

;;;;;
;; Public API
;;;;;

(defun minuet-duet-history-flush ()
  "Flush pending edits into the history immediately.
No-op when `minuet-duet-history-mode' is disabled."
  (when minuet-duet-history-mode
    (minuet-duet-history--flush-buffer)))

(defun minuet-duet-history-clear ()
  "Discard the recorded edit history of the current buffer."
  (interactive)
  (when minuet-duet-history-mode
    (setq minuet-duet-history--entries nil)
    (minuet-duet-history--take-snapshot)))

(defun minuet-duet-history-prompt-text ()
  "Return the edit history of the current buffer formatted for prompts.
Returns nil when `minuet-duet-history-mode' is disabled or no edits
have been recorded.  The newest entry is always included; older
entries are added while the total length stays within
`minuet-duet-history-max-prompt-chars'.  Entries are rendered oldest
first."
  (when (and minuet-duet-history-mode minuet-duet-history--entries)
    (let ((selected nil)
          (total 0))
      (cl-loop for entry in minuet-duet-history--entries
               for newest = t then nil
               if (or newest
                      (<= (+ total (length entry))
                          minuet-duet-history-max-prompt-chars))
               do (progn (push entry selected)
                         (cl-incf total (length entry)))
               else return nil)
      (concat
       "<edit_history>\n"
       "Recent edits made by the user, oldest first, as unified diffs (line numbers refer to the buffer at the time of each edit):\n\n"
       (mapconcat #'identity selected "\n\n")
       "\n</edit_history>"))))

(provide 'minuet-duet-history)
;;; minuet-duet-history.el ends here
