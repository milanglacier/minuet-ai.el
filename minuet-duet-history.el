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
;; recent edits as unified diffs.  Nothing runs per keystroke: each
;; tracked buffer owns a one-shot idle timer that detects changes by
;; comparing `buffer-chars-modified-tick' against the last snapshot's
;; tick and then schedules the buffer's next check, so all tracking
;; state is buffer-local.  Snapshots are temporary files under a
;; shared session directory (deleted at `kill-emacs') written with
;; `write-region' (no Lisp string is allocated), and the diff is
;; computed asynchronously by an external program
;; (`minuet-duet-history-diff-program'), producing one coalesced
;; history entry per editing burst.
;; `minuet-duet--build-context' calls `minuet-duet-history-flush',
;; which waits for the in-flight diff up to
;; `minuet-duet-history-flush-timeout' seconds, so the burst typed
;; right before a prediction is normally included; past the deadline
;; the prompt is built with history one burst stale instead of
;; blocking.  The formatted history is included via
;; `minuet-duet-history-prompt-text'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'minuet)

;;;;;
;; Customization
;;;;;

(defcustom minuet-duet-history-idle-delay 1.5
  "Idle seconds before pending edits are flushed into a history entry.
The value is read each time a buffer schedules its next idle check,
so changes take effect from the next editing burst."
  :type 'number
  :group 'minuet-duet)

(defcustom minuet-duet-history-max-entries 8
  "Maximum number of history entries kept per buffer.
The oldest entries are dropped first."
  :type 'integer
  :group 'minuet-duet)

(defcustom minuet-duet-history-max-region-lines 200
  "Maximum changed-region size (in lines) recorded as a history entry.

The changed region of a diff spans from its first hunk to its last
hunk on either side, including the unchanged context lines around
them.  If it exceeds this many lines, the edit is skipped (the
snapshot is still updated).  This avoids recording mass edits such as
large pastes, reverts, or whole-buffer reformatting, which are poor
signals of user intent."
  :type 'integer
  :group 'minuet-duet)

(defcustom minuet-duet-history-diff-context-lines 2
  "Number of unchanged context lines around each hunk in history diffs.
Passed as the diff program's -U argument; hunks whose context ranges
touch or overlap are merged into a single hunk by the diff program."
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

(defcustom minuet-duet-history-diff-program "diff"
  "Program used to diff buffer snapshots.
It is invoked as PROGRAM -UN OLD NEW and must produce a unified diff
on stdout, exiting with status 0 when the files are identical, 1 when
they differ, and 2 or greater on error (the convention of POSIX
diff).  `minuet-duet-history-mode' refuses to enable when the program
is not found."
  :type 'string
  :group 'minuet-duet)

(defcustom minuet-duet-history-flush-timeout 0.2
  "Maximum seconds `minuet-duet-history-flush' waits for a pending diff.
Diffing runs asynchronously; when a prediction is requested while a
diff is still in flight (or edits are pending), the flush waits up to
this long for it to complete so the newest burst is included in the
prompt.  Past the deadline the prediction proceeds with the history
one burst stale rather than blocking."
  :type 'number
  :group 'minuet-duet)

;;;;;
;; State
;;;;;

(defvar minuet-duet-history--directory nil
  "Directory holding all snapshot files, or nil before the first use.
Created lazily under `temporary-file-directory' and deleted
recursively at `kill-emacs'.  Snapshot files are normally deleted by
their owner's lifecycle hooks; the directory sweep backstops buffers
killed with their hooks inhibited (e.g. temp buffers created with
`inhibit-buffer-hooks'), whose files would otherwise be stranded.")

(defvar-local minuet-duet-history--timer nil
  "One-shot idle timer scheduling this buffer's next flush, or nil.
Non-nil exactly while the buffer is tracked: each run schedules the
next timer, and the chain ends when the buffer dies or the mode is
disabled.")

(defvar-local minuet-duet-history--snapshot-file nil
  "File holding the buffer content at the last recorded snapshot.")

(defvar-local minuet-duet-history--pending-file nil
  "Scratch file the next snapshot is written to while it is diffed.
Swapped with `minuet-duet-history--snapshot-file' when the diff
completes, so the two files ping-pong roles.")

(defvar-local minuet-duet-history--snapshot-tick nil
  "Buffer `buffer-chars-modified-tick' at the last snapshot.")

(defvar-local minuet-duet-history--process nil
  "In-flight diff process for this buffer, or nil.")

(defvar-local minuet-duet-history--entries nil
  "List of formatted unified diff strings, newest first.")

(defvar minuet-duet-history-mode)

;;;;;
;; Pure helpers
;;;;;

(defun minuet-duet-history--entry-string ()
  "Return the unified diff in the current buffer as a history entry.
The ---/+++ file header lines, which name the snapshot files and would
leak temporary file paths into prompts, and the trailing newline are
dropped."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "--- [^\n]*\n\\+\\+\\+ [^\n]*\n")
      (goto-char (match-end 0)))
    (buffer-substring-no-properties
     (point)
     (if (eq (char-before (point-max)) ?\n)
         (max (point) (1- (point-max)))
       (point-max)))))

(defun minuet-duet-history--hunk-span ()
  "Return the changed-region span of the unified diff in the current buffer.
The span is the larger side of the region from the start of the first
hunk to the end of the last hunk, computed from the @@ headers (an
omitted count means 1).  Returns nil when the buffer contains no hunk
headers, e.g. for binary input.  Works on the diff process buffer
directly so oversized diffs are measured and discarded without ever
allocating their content as a Lisp string."
  (save-excursion
    (goto-char (point-min))
    (let (first-a first-b last-a-end last-b-end)
      (while (re-search-forward
              "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
              nil t)
        (let ((a-start (string-to-number (match-string 1)))
              (a-count (if (match-beginning 2)
                           (string-to-number (match-string 2))
                         1))
              (b-start (string-to-number (match-string 3)))
              (b-count (if (match-beginning 4)
                           (string-to-number (match-string 4))
                         1)))
          (unless first-a
            (setq first-a a-start
                  first-b b-start))
          (setq last-a-end (+ a-start a-count)
                last-b-end (+ b-start b-count))))
      (when first-a
        (max (- last-a-end first-a) (- last-b-end first-b))))))

(defun minuet-duet-history--push-entry (entry)
  "Push ENTRY onto the buffer's history, dropping the oldest past the cap."
  (push entry minuet-duet-history--entries)
  (setq minuet-duet-history--entries
        (seq-take minuet-duet-history--entries
                  minuet-duet-history-max-entries)))

;;;;;
;; Snapshot files
;;;;;

(defun minuet-duet-history--write-snapshot (file)
  "Write the widened buffer content to FILE; return the tick written.
`write-region' writes straight from the buffer text, so no Lisp string
is allocated.  Content is always encoded as utf-8 with Unix newlines
regardless of the buffer's file coding system, so both snapshot files
are encoded consistently and the diff output decodes back to the
buffer's text."
  (let ((tick (buffer-chars-modified-tick)))
    (save-restriction
      (widen)
      (let ((coding-system-for-write 'utf-8-unix)
            (write-region-inhibit-fsync t)
            (write-region-annotate-functions nil)
            (write-region-post-annotation-function nil)
            (buffer-file-format nil))
        (write-region (point-min) (point-max) file nil 0)))
    tick))

(defun minuet-duet-history--ensure-directory ()
  "Return the snapshot directory, creating it when missing.
`make-temp-file' creates it in the local `temporary-file-directory'
even for remote buffers.  The directory is re-created if it was
deleted externally mid-session; the `kill-emacs' sweep is installed
when it is first created."
  (unless (and minuet-duet-history--directory
               (file-directory-p minuet-duet-history--directory))
    (setq minuet-duet-history--directory
          (make-temp-file "minuet-duet-history-" t))
    (add-hook 'kill-emacs-hook #'minuet-duet-history--delete-directory))
  minuet-duet-history--directory)

(defun minuet-duet-history--delete-directory ()
  "Delete the snapshot directory and everything in it.
Runs from `kill-emacs-hook'; also collects files stranded by buffers
that died without running `kill-buffer-hook'.  In-flight diff
processes are not cancelled: they carry :noquery and die with Emacs.
Native Windows may refuse to delete open snapshots, but this is
untested because no Windows machine is available."
  (when minuet-duet-history--directory
    (ignore-errors (delete-directory minuet-duet-history--directory t))
    (setq minuet-duet-history--directory nil)))

(defun minuet-duet-history--allocate-files ()
  "Allocate this buffer's two snapshot files in the snapshot directory."
  (let ((prefix (expand-file-name "snapshot-"
                                  (minuet-duet-history--ensure-directory))))
    (setq minuet-duet-history--snapshot-file (make-temp-file prefix)
          minuet-duet-history--pending-file (make-temp-file prefix))))

(defun minuet-duet-history--delete-files ()
  "Delete this buffer's snapshot files."
  (dolist (file (list minuet-duet-history--snapshot-file
                      minuet-duet-history--pending-file))
    (when file
      (ignore-errors (delete-file file))))
  (setq minuet-duet-history--snapshot-file nil
        minuet-duet-history--pending-file nil))

(defun minuet-duet-history--snapshot-state-valid-p ()
  "Return non-nil when the shared directory and this buffer's files exist."
  (and minuet-duet-history--directory
       (file-directory-p minuet-duet-history--directory)
       minuet-duet-history--snapshot-file
       (file-regular-p minuet-duet-history--snapshot-file)
       minuet-duet-history--pending-file
       (file-regular-p minuet-duet-history--pending-file)))

(defun minuet-duet-history--take-snapshot ()
  "Snapshot the current buffer content and modification tick."
  (unless (minuet-duet-history--snapshot-state-valid-p)
    (minuet-duet-history--delete-files)
    (minuet-duet-history--allocate-files))
  (setq minuet-duet-history--snapshot-tick
        (minuet-duet-history--write-snapshot
         minuet-duet-history--snapshot-file)))

(defun minuet-duet-history--cancel-process ()
  "Cancel any in-flight diff process of the current buffer.
The buffer-local process variable is cleared before the process is
deleted, so the late-arriving sentinel recognizes the cancellation and
only disposes of its output buffers."
  (let ((process minuet-duet-history--process))
    (setq minuet-duet-history--process nil)
    (when (and process (process-live-p process))
      (delete-process process))))

;;;;;
;; Flush
;;;;;

(defun minuet-duet-history--disable-oversized-buffer ()
  "Disable history tracking because the current buffer exceeds its size cap."
  (minuet-duet-history-mode -1)
  (minuet--log
   (format "Minuet duet history: buffer %s exceeds `minuet-duet-history-max-buffer-size'; tracking disabled."
           (buffer-name))))

(defun minuet-duet-history--rotate (pending-tick)
  "Make the pending snapshot the current one, recorded at PENDING-TICK."
  (cl-rotatef minuet-duet-history--snapshot-file
              minuet-duet-history--pending-file)
  (setq minuet-duet-history--snapshot-tick pending-tick))

(defun minuet-duet-history--start-flush ()
  "Start recording pending edits in the current buffer as a history entry.
Writes the buffer content to the pending snapshot file and starts an
asynchronous diff against the last snapshot; the process sentinel
records the result and updates the snapshot.  Does nothing when the
buffer text is unchanged since the last flush or a diff is already in
flight.  If the snapshot directory or baseline disappeared externally,
the current content becomes a fresh baseline; existing history is kept,
but the burst whose baseline was lost cannot be recorded.  Pending edits
are detected by comparing
`buffer-chars-modified-tick' (which ignores property-only changes)
against the snapshot tick rather than via `after-change-functions', so
edits made with modification hooks inhibited (e.g. by
`with-silent-modifications') or from an indirect sibling buffer are
recorded too."
  (let ((tick (buffer-chars-modified-tick)))
    (when (and minuet-duet-history-mode
               (not minuet-duet-history--process)
               (not (eql tick minuet-duet-history--snapshot-tick)))
      (cond
       ((> (buffer-size) minuet-duet-history-max-buffer-size)
        (minuet-duet-history--disable-oversized-buffer))
       ((not (minuet-duet-history--snapshot-state-valid-p))
        (minuet-duet-history--take-snapshot))
       (t
        (let ((pending-tick (minuet-duet-history--write-snapshot
                             minuet-duet-history--pending-file))
              (stdout (generate-new-buffer " *minuet-duet-history-diff*" t))
              (stderr (generate-new-buffer " *minuet-duet-history-diff-stderr*" t)))
          (condition-case err
              (let* ((default-directory temporary-file-directory)
                     (process-connection-type nil)
                     (process
                      (make-process
                       :name "minuet-duet-history-diff"
                       :command (list minuet-duet-history-diff-program
                                      (format "-U%d"
                                              (max 0 minuet-duet-history-diff-context-lines))
                                      minuet-duet-history--snapshot-file
                                      minuet-duet-history--pending-file)
                       :buffer stdout
                       :stderr stderr
                       :coding 'utf-8-unix
                       :noquery t
                       :sentinel #'minuet-duet-history--sentinel)))
                ;; The stderr pipe's default sentinel would insert
                ;; "Process ... finished" into the stderr buffer.
                (set-process-sentinel (get-buffer-process stderr) #'ignore)
                (process-put process :minuet-buffer (current-buffer))
                (process-put process :minuet-pending-tick pending-tick)
                (process-put process :minuet-stderr stderr)
                (setq minuet-duet-history--process process))
            (error
             (kill-buffer stdout)
             (kill-buffer stderr)
             (signal (car err) (cdr err))))))))))

(defun minuet-duet-history--sentinel (process _event)
  "Record the output of diff PROCESS as a history entry.
Rotates the snapshot files on success; on failure the snapshot and
tick are left unchanged so the next flush retries the same burst.
When the tracked buffer died or the flush was cancelled (the buffer's
process variable no longer holds PROCESS), only the process output
buffers are disposed of; the snapshot files are owned by the buffer
lifecycle, never by the sentinel."
  (let ((stdout (process-buffer process))
        (stderr (process-get process :minuet-stderr))
        (buffer (process-get process :minuet-buffer)))
    (unwind-protect
        (when (and (memq (process-status process) '(exit signal))
                   (buffer-live-p buffer)
                   (eq process (buffer-local-value 'minuet-duet-history--process
                                                   buffer)))
          (with-current-buffer buffer
            (setq minuet-duet-history--process nil)
            (let ((status (process-status process))
                  (code (process-exit-status process))
                  (pending-tick (process-get process :minuet-pending-tick)))
              (cond
               ((or (eq status 'signal) (>= code 2))
                (minuet--log
                 (format "Minuet duet history: %s failed in %s (%s): %s"
                         minuet-duet-history-diff-program (buffer-name)
                         (if (eq status 'signal) "signal" code)
                         (string-trim
                          (with-current-buffer stderr (buffer-string))))))
               ((= code 0)
                ;; The burst was reverted: text is back to the snapshot.
                (minuet-duet-history--rotate pending-tick))
               (t
                (let ((span (with-current-buffer stdout
                              (minuet-duet-history--hunk-span))))
                  (cond
                   ((null span)
                    (minuet--log
                     (format "Minuet duet history: no hunks in diff output for %s; skipped."
                             (buffer-name))))
                   ((> span minuet-duet-history-max-region-lines)
                    (minuet--log
                     (format "Minuet duet history: edit in %s exceeds `minuet-duet-history-max-region-lines'; skipped."
                             (buffer-name))))
                   (t
                    (minuet-duet-history--push-entry
                     (with-current-buffer stdout
                       (minuet-duet-history--entry-string)))))
                  (minuet-duet-history--rotate pending-tick)))))))
      (when (buffer-live-p stdout) (kill-buffer stdout))
      (when (buffer-live-p stderr) (kill-buffer stderr)))))

(defun minuet-duet-history--flush-buffer-safely ()
  "Start a flush of the current buffer, logging errors instead of signaling.
Used by both the idle timer and `minuet-duet-history-flush' so a flush
error degrades to \"no new history\" rather than aborting the caller;
the snapshot tick is left unchanged, so the next flush retries the
same burst."
  (condition-case err
      (minuet-duet-history--start-flush)
    (error
     (minuet--log
      (format "Minuet duet history: flush error in %s: %s"
              (buffer-name) (error-message-string err))))))

;;;;;
;; Timer chain
;;;;;

(defun minuet-duet-history--schedule-timer ()
  "Schedule this buffer's next idle flush as a one-shot timer.
A fresh timer object is created each time (re-activating one that is
still on `timer-idle-list' is an error), and any previously scheduled
timer is cancelled first so the buffer never runs two chains.  The
timer is activated with `timer-activate-when-idle' rather than
`run-with-idle-timer': when the next timer is scheduled from the
previous one's run, Emacs is already idle past the delay, and
`run-with-idle-timer' would fire it immediately, re-running the chain
in a busy loop for the rest of the idle period.  Activating without
DONT-WAIT defers it to the next idle period instead, matching the
once-per-idle-period behavior of a repeating idle timer."
  (minuet-duet-history--cancel-timer)
  (let ((timer (timer-create)))
    (timer-set-function timer #'minuet-duet-history--on-timer
                        (list (current-buffer)))
    (timer-set-idle-time timer minuet-duet-history-idle-delay)
    (timer-activate-when-idle timer)
    (setq minuet-duet-history--timer timer)))

(defun minuet-duet-history--cancel-timer ()
  "Cancel this buffer's scheduled flush timer, ending its timer chain."
  (when minuet-duet-history--timer
    (cancel-timer minuet-duet-history--timer)
    (setq minuet-duet-history--timer nil)))

(defun minuet-duet-history--on-timer (buffer)
  "Flush pending edits in BUFFER and schedule its next flush timer.
When BUFFER died or the mode was turned off in it without running the
teardown (e.g. a kill with `inhibit-buffer-hooks', or wiped local
variables), no next timer is scheduled and the chain simply ends, so
a stale timer fires at most once.  The flush is skipped while the
previous diff is still in flight or the buffer text is unchanged
since the last snapshot."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'minuet-duet-history-mode buffer))
    (with-current-buffer buffer
      (unless (or minuet-duet-history--process
                  (eql (buffer-chars-modified-tick)
                       minuet-duet-history--snapshot-tick))
        (minuet-duet-history--flush-buffer-safely))
      ;; The flush may have disabled the mode (oversized buffer).
      (when minuet-duet-history-mode
        (minuet-duet-history--schedule-timer)))))

;;;;;
;; Hooks
;;;;;

(defun minuet-duet-history--on-kill-buffer ()
  "Cancel this buffer's diff and timer and delete its snapshot files."
  (minuet-duet-history--cancel-process)
  (minuet-duet-history--delete-files)
  (minuet-duet-history--cancel-timer))

(defun minuet-duet-history--on-major-mode-change ()
  "Disable the mode before `kill-all-local-variables' wipes its state.
Runs from `change-major-mode-hook' (major-mode change, or a manual
revert through `normal-mode') while the buffer-local file and process
variables are still intact, so the diff is cancelled and the snapshot
files are deleted instead of being orphaned by the wipe.  When the new
major mode's hooks re-enable the mode, it re-initializes from
scratch."
  (minuet-duet-history-mode -1))


;; Direct clones created by `clone-buffer' are intentionally ignored:
;; it cannot clone file-visiting buffers and falls outside Minuet's
;; normal editing workflow.  Only indirect clones need lifecycle
;; handling here.
(defun minuet-duet-history--on-clone ()
  "Re-initialize an indirect clone that inherited enabled history tracking.
Indirect cloning copies the buffer-local mode state, snapshot file
paths, timer, in-flight process, entries, and hooks.  The inherited
process, timer, and file paths alias the parent's, so they are
dropped (without killing the parent's process, cancelling its timer,
or deleting its files) and a fresh snapshot and timer chain are set
up for the clone."
  (when minuet-duet-history-mode
    (setq minuet-duet-history--process nil
          minuet-duet-history--timer nil
          minuet-duet-history--snapshot-file nil
          minuet-duet-history--pending-file nil)
    (minuet-duet-history--take-snapshot)
    (minuet-duet-history--schedule-timer)))

;;;###autoload
(define-minor-mode minuet-duet-history-mode
  "Track recent edits in this buffer for duet next-edit prediction.

While enabled, edits are recorded as unified diffs, one coalesced
entry per editing burst, computed on idle by an external diff program
over temporary-file snapshots.  `minuet-duet-predict' includes the
recorded history in its prompt so the model can infer the user's
intent from what they have been doing."
  :init-value nil
  :lighter nil
  (if minuet-duet-history-mode
      (cond
       ;; Re-enabling in an already-tracked buffer with intact local
       ;; state keeps the recorded history instead of wiping it (e.g.
       ;; the mode toggled on twice); the live timer chain is kept.
       ;; When the snapshot file was deleted externally, fall through
       ;; and re-initialize.  (A `kill-all-local-variables' wipe never
       ;; reaches this branch: the `change-major-mode-hook' teardown
       ;; disables the mode first.)
       ((and minuet-duet-history--timer
             (minuet-duet-history--snapshot-state-valid-p))
        (add-hook 'change-major-mode-hook
                  #'minuet-duet-history--on-major-mode-change nil t)
        (add-hook 'clone-indirect-buffer-hook
                  #'minuet-duet-history--on-clone nil t))
       ((> (buffer-size) minuet-duet-history-max-buffer-size)
        (setq minuet-duet-history-mode nil)
        ;; The buffer may hold a stale timer chain (e.g. its snapshot
        ;; file vanished while the buffer grew past the cap).
        (minuet-duet-history--cancel-timer)
        (minuet--log
         (format "Minuet duet history: buffer %s exceeds `minuet-duet-history-max-buffer-size'; not tracking."
                 (buffer-name))
         t))
       ((not (executable-find minuet-duet-history-diff-program))
        (setq minuet-duet-history-mode nil)
        (minuet-duet-history--cancel-timer)
        (minuet--log
         (format "Minuet duet history: diff program %S not found; not tracking %s."
                 minuet-duet-history-diff-program (buffer-name))
         t))
       (t
        ;; Drop any stale state (a snapshot file deleted externally,
        ;; or file paths left over from a partial wipe) before
        ;; re-initializing.  `minuet-duet-history--schedule-timer'
        ;; cancels a stale timer chain itself.
        (minuet-duet-history--cancel-process)
        (minuet-duet-history--delete-files)
        (setq minuet-duet-history--entries nil)
        (minuet-duet-history--take-snapshot)
        (add-hook 'kill-buffer-hook #'minuet-duet-history--on-kill-buffer nil t)
        (add-hook 'change-major-mode-hook
                  #'minuet-duet-history--on-major-mode-change nil t)
        (add-hook 'clone-indirect-buffer-hook
                  #'minuet-duet-history--on-clone nil t)
        (minuet-duet-history--schedule-timer)))
    (remove-hook 'kill-buffer-hook #'minuet-duet-history--on-kill-buffer t)
    (remove-hook 'change-major-mode-hook
                 #'minuet-duet-history--on-major-mode-change t)
    (remove-hook 'clone-indirect-buffer-hook
                 #'minuet-duet-history--on-clone t)
    (minuet-duet-history--cancel-process)
    (minuet-duet-history--delete-files)
    (minuet-duet-history--cancel-timer)
    (setq minuet-duet-history--snapshot-tick nil
          minuet-duet-history--entries nil)))

;;;;;
;; Public API
;;;;;

(defun minuet-duet-history-flush ()
  "Flush pending edits into the history, waiting briefly for the diff.
Starts a flush when edits are pending and none is in flight, then
waits for in-flight diffs up to `minuet-duet-history-flush-timeout'
seconds so the newest burst is recorded; if edits arrive while a diff
is running, one follow-up flush is started within the same deadline
\(at most two flushes per call, so a persistently failing diff program
cannot cause a respawn loop).  Past the deadline the history is left
one burst stale.  No-op when `minuet-duet-history-mode' is disabled.
Never signals: flush errors are logged, so callers such as
`minuet-duet--build-context' degrade to running without history
instead of aborting."
  (when minuet-duet-history-mode
    (condition-case err
        (let ((deadline (+ (float-time) minuet-duet-history-flush-timeout))
              (starts 0))
          (catch 'done
            (while t
              (when (and (< starts 2)
                         (not minuet-duet-history--process)
                         (not (eql (buffer-chars-modified-tick)
                                   minuet-duet-history--snapshot-tick)))
                (cl-incf starts)
                (minuet-duet-history--flush-buffer-safely))
              (unless (and minuet-duet-history-mode
                           minuet-duet-history--process
                           (< (float-time) deadline))
                (throw 'done nil))
              ;; Wait on any process, not specifically on the diff:
              ;; waiting on a process whose output was already drained
              ;; can miss its exit notification and leave the sentinel
              ;; unrun for the whole timeout.  The slice is short
              ;; because the exit notification does not interrupt the
              ;; wait either; each flush pays up to one slice.
              (accept-process-output nil 0.005))))
      (error
       (minuet--log
        (format "Minuet duet history: flush error in %s: %s"
                (buffer-name) (error-message-string err)))))))

(defun minuet-duet-history-clear ()
  "Discard the recorded edit history of the current buffer."
  (interactive)
  (when minuet-duet-history-mode
    (if (> (buffer-size) minuet-duet-history-max-buffer-size)
        (minuet-duet-history--disable-oversized-buffer)
      (minuet-duet-history--cancel-process)
      (setq minuet-duet-history--entries nil)
      (minuet-duet-history--take-snapshot))))

(defun minuet-duet-history-prompt-text ()
  "Return the edit history of the current buffer formatted for prompts.
Returns nil when `minuet-duet-history-mode' is disabled, when no edits
have been recorded, or while the buffer is narrowed: entries are
diffed against the widened buffer, so rendering them under narrowing
could expose text outside the visible region and would use line
numbers inconsistent with the narrowed document.  Entries are kept and
become available again once the buffer is widened.

The newest entry is always included; older entries (and their
separators) are added while the total stays within
`minuet-duet-history-max-prompt-chars'.  The fixed <edit_history>
wrapper is not counted against the budget.  Entries are rendered
oldest first."
  (when (and minuet-duet-history-mode
             minuet-duet-history--entries
             (not (buffer-narrowed-p)))
    (let ((selected nil)
          (total 0))
      (cl-loop for entry in minuet-duet-history--entries
               for newest = t then nil
               ;; Entries after the first cost their separator too.
               for cost = (length entry) then (+ (length entry) 2)
               if (or newest
                      (<= (+ total cost)
                          minuet-duet-history-max-prompt-chars))
               do (progn (push entry selected)
                         (cl-incf total cost))
               else return nil)
      (concat
       "<edit_history>\n"
       "Recent edits made by the user, oldest first, as unified diffs (line numbers refer to the buffer at the time of each edit):\n\n"
       (mapconcat #'identity selected "\n\n")
       "\n</edit_history>"))))

(provide 'minuet-duet-history)
;;; minuet-duet-history.el ends here
