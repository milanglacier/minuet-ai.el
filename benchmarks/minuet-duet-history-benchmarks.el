;;; minuet-duet-history-benchmarks.el --- Benchmarks for duet history -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; Benchmark `minuet-duet-history-mode' with large diffs and frequent edits.
;; Each tracked workload has an edit-only baseline.  Results include elapsed
;; time, garbage collection, allocated Lisp memory, and retained Lisp memory.
;; Run with `make benchmark'.
;;
;; Diffs run in an external process over temp-file snapshots; the flush
;; timeout is raised for the whole run so every measured flush includes
;; the diff's completion (write, fork/exec, diff, sentinel) instead of
;; being cut short by the interactive deadline.  Wall time and retained
;; KiB are the headline numbers; alloc MiB now mostly measures the diff
;; output strings and process plumbing, since snapshots no longer live
;; in the Lisp heap.  The tracked block workloads produce one hunk far
;; over `minuet-duet-history-max-entry-chars', so they measure a full
;; external diff whose output is discarded post-hoc, not an early bail;
;; the scattered workload produces a many-hunk diff over the budget, so
;; it measures an entry accepted after truncation to the leading hunks.

;;; Code:

(require 'benchmark)
(require 'cl-lib)
(require 'minuet-duet-history)

(defvar minuet-duet-history-benchmark-lines
  (string-to-number (or (getenv "MINUET_BENCH_LINES") "20000"))
  "Number of lines in benchmark buffers.")

(defvar minuet-duet-history-benchmark-repetitions
  (string-to-number (or (getenv "MINUET_BENCH_REPETITIONS") "12"))
  "Number of times to run each repeated workload.")

(defvar minuet-duet-history-benchmark-burst-edits
  (string-to-number (or (getenv "MINUET_BENCH_BURST_EDITS") "20"))
  "Number of edits in a frequent-edit burst.")

(defconst minuet-duet-history-benchmark--line-format
  "line-%06d value-%08d payload\n")

(defun minuet-duet-history-benchmark--text (lines value &optional first-line)
  "Return LINES fixed-width lines containing VALUE.
Start line numbering at FIRST-LINE, or zero."
  (with-temp-buffer
    (dotimes (offset lines)
      (insert (format minuet-duet-history-benchmark--line-format
                      (+ (or first-line 0) offset) value)))
    (buffer-string)))

(defun minuet-duet-history-benchmark--buffer (&optional track)
  "Create a large benchmark buffer and enable history when TRACK is non-nil."
  (let ((buffer (generate-new-buffer " *minuet-history-benchmark*")))
    (with-current-buffer buffer
      ;; Keep undo allocation out of the history measurements.
      (setq buffer-undo-list t)
      (insert (minuet-duet-history-benchmark--text
               minuet-duet-history-benchmark-lines 0))
      (when (> (buffer-size) minuet-duet-history-max-buffer-size)
        (error "Benchmark buffer exceeds `minuet-duet-history-max-buffer-size'"))
      (when track
        (minuet-duet-history-mode 1)))
    buffer))

(defun minuet-duet-history-benchmark--line-position (line)
  "Return the position at the beginning of zero-based LINE."
  (save-excursion
    (goto-char (point-min))
    (forward-line line)
    (point)))

(defun minuet-duet-history-benchmark--block (track lines)
  "Create state for replacing LINES lines in a buffer with TRACK enabled."
  (let* ((buffer (minuet-duet-history-benchmark--buffer track))
         (first-line (/ (- minuet-duet-history-benchmark-lines lines) 2))
         (start (with-current-buffer buffer
                  (copy-marker
                   (minuet-duet-history-benchmark--line-position first-line)))))
    (vector buffer start
            (minuet-duet-history-benchmark--text lines 1 first-line)
            (minuet-duet-history-benchmark--text lines 2 first-line)
            track)))

(defun minuet-duet-history-benchmark--replace-block (state)
  "Replace the block described by STATE and flush when tracking."
  (let ((buffer (aref state 0))
        (start (aref state 1))
        (old (aref state 2))
        (new (aref state 3)))
    (with-current-buffer buffer
      (delete-region start (+ start (length old)))
      (goto-char start)
      (insert new)
      (when (aref state 4)
        (minuet-duet-history-flush)))
    (aset state 2 new)
    (aset state 3 old)))

(defun minuet-duet-history-benchmark--scattered (track hunks stride)
  "Create state for editing HUNKS lines STRIDE lines apart with TRACK.
Each edited line is far enough from its neighbors that the diff
records one hunk per line, so the flushed entry is accepted but
truncated to the leading hunks that fit
`minuet-duet-history-max-entry-chars'."
  (let ((buffer (minuet-duet-history-benchmark--buffer track))
        (first-line (/ (- minuet-duet-history-benchmark-lines
                          (* hunks stride))
                       2))
        markers)
    (with-current-buffer buffer
      (dotimes (i hunks)
        (push (copy-marker
               (minuet-duet-history-benchmark--line-position
                (+ first-line (* i stride))))
              markers)))
    (vector buffer (nreverse markers) 1 track)))

(defun minuet-duet-history-benchmark--edit-scattered (state)
  "Rewrite the value field of each marked line in STATE; flush when tracking.
The value field starts 18 characters into each line of
`minuet-duet-history-benchmark--line-format' and is 8 digits wide."
  (let ((buffer (aref state 0))
        (markers (aref state 1))
        (text (format "%08d" (aref state 2))))
    (with-current-buffer buffer
      (dolist (marker markers)
        (delete-region (+ marker 18) (+ marker 26))
        (goto-char (+ marker 18))
        (insert text))
      (when (aref state 3)
        (minuet-duet-history-flush)))
    (aset state 2 (1+ (aref state 2)))))

(defun minuet-duet-history-benchmark--frequent (track flush-each)
  "Create frequent-edit state using TRACK and FLUSH-EACH."
  (let ((buffer (minuet-duet-history-benchmark--buffer track)))
    (with-current-buffer buffer
      (goto-char (minuet-duet-history-benchmark--line-position
                  (/ minuet-duet-history-benchmark-lines 2)))
      (search-forward "value-")
      (vector buffer (copy-marker (point)) "00000000" 1 track flush-each))))

(defun minuet-duet-history-benchmark--edit-burst (state)
  "Perform a frequent edit burst described by STATE."
  (let ((buffer (aref state 0))
        (start (aref state 1))
        (old (aref state 2))
        (next-value (aref state 3))
        (track (aref state 4))
        (flush-each (aref state 5)))
    (with-current-buffer buffer
      (dotimes (_ minuet-duet-history-benchmark-burst-edits)
        (let ((new (format "%08d" next-value)))
          (delete-region start (+ start (length old)))
          (goto-char start)
          (insert new)
          (setq old new
                next-value (1+ next-value)))
        (when flush-each
          (minuet-duet-history-flush)))
      (when (and track (not flush-each))
        (minuet-duet-history-flush)))
    (aset state 2 old)
    (aset state 3 next-value)))

(defun minuet-duet-history-benchmark--enable (buffer)
  "Enable duet history in BUFFER."
  (with-current-buffer buffer
    (minuet-duet-history-mode 1)))

(defun minuet-duet-history-benchmark--cleanup (state)
  "Disable history and kill the buffer referenced by STATE."
  (let ((buffer (if (bufferp state) state (aref state 0))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when minuet-duet-history-mode
          (minuet-duet-history-mode -1)))
      (kill-buffer buffer))))

(defun minuet-duet-history-benchmark--live-bytes (stats)
  "Return live Lisp bytes represented by garbage collection STATS."
  (cl-loop for (_name size used . _rest) in stats sum (* size used)))

(defun minuet-duet-history-benchmark--allocated-bytes (before after stats)
  "Estimate Lisp bytes allocated between BEFORE and AFTER using STATS."
  (cl-loop for old in before
           for new in after
           for type in '(conses floats vector-slots symbols
                                string-bytes intervals strings)
           sum (* (- new old) (or (nth 1 (assq type stats)) 0))))

(defun minuet-duet-history-benchmark--measure (name repetitions setup function)
  "Measure FUNCTION REPETITIONS times on state returned by SETUP.
Label the result NAME."
  (let ((state (funcall setup)))
    (unwind-protect
        (let* ((before-gc (garbage-collect))
               (before-live
                (minuet-duet-history-benchmark--live-bytes before-gc))
               (before-counts (memory-use-counts))
               (timing (benchmark-run repetitions (funcall function state)))
               (after-counts (memory-use-counts))
               (after-gc (garbage-collect)))
          (list name repetitions
                (/ (* 1000.0 (nth 0 timing)) repetitions)
                (/ (minuet-duet-history-benchmark--allocated-bytes
                    before-counts after-counts before-gc)
                   repetitions 1048576.0)
                (nth 1 timing)
                (* 1000.0 (nth 2 timing))
                (/ (- (minuet-duet-history-benchmark--live-bytes after-gc)
                      before-live)
                   1024.0)))
      (minuet-duet-history-benchmark--cleanup state))))

(defun minuet-duet-history-benchmark--print (results)
  "Print benchmark RESULTS."
  (princ (format "%-39s %5s %10s %13s %6s %10s %13s\n"
                 "scenario" "runs" "ms/run" "alloc MiB/run"
                 "GCs" "GC ms" "retained KiB"))
  (princ (make-string 112 ?-))
  (princ "\n")
  (dolist (result results)
    (pcase-let ((`(,name ,runs ,milliseconds ,allocated ,gcs ,gc-ms ,retained)
                 result))
      (princ (format "%-39s %5d %10.3f %13.3f %6d %10.3f %+13.1f\n"
                     name runs milliseconds allocated gcs gc-ms retained)))))

;;;###autoload
(defun minuet-duet-history-benchmark-run ()
  "Benchmark large diffs, frequent edits, and their memory pressure.
Set MINUET_BENCH_LINES, MINUET_BENCH_REPETITIONS, or
MINUET_BENCH_BURST_EDITS to change the default workload."
  (interactive)
  ;; Reuse the session snapshot directory: each measured case disables
  ;; its own buffer and deletes its files, while the directory remains
  ;; visible to the global `kill-emacs-hook' cleanup.
  (let* ((minuet-duet-history-flush-timeout 30)
         (runs minuet-duet-history-benchmark-repetitions)
         (full-runs (min 3 runs))
         (block-lines 200)
         (cases
          (list
           (list "enable history (large buffer)" 1
                 (lambda () (minuet-duet-history-benchmark--buffer))
                 #'minuet-duet-history-benchmark--enable)
           (list "large diff: edit only" runs
                 (lambda ()
                   (minuet-duet-history-benchmark--block nil block-lines))
                 #'minuet-duet-history-benchmark--replace-block)
           (list "large diff: tracked" runs
                 (lambda ()
                   (minuet-duet-history-benchmark--block t block-lines))
                 #'minuet-duet-history-benchmark--replace-block)
           (list "whole rewrite: edit only" full-runs
                 (lambda ()
                   (minuet-duet-history-benchmark--block
                    nil minuet-duet-history-benchmark-lines))
                 #'minuet-duet-history-benchmark--replace-block)
           (list "whole rewrite: tracked/skip" full-runs
                 (lambda ()
                   (minuet-duet-history-benchmark--block
                    t minuet-duet-history-benchmark-lines))
                 #'minuet-duet-history-benchmark--replace-block)
           (list "scattered diff: edit only" runs
                 (lambda ()
                   (minuet-duet-history-benchmark--scattered nil 100 10))
                 #'minuet-duet-history-benchmark--edit-scattered)
           (list "scattered diff: truncated entry" runs
                 (lambda ()
                   (minuet-duet-history-benchmark--scattered t 100 10))
                 #'minuet-duet-history-benchmark--edit-scattered)
           (list "frequent edits: edit only" runs
                 (lambda ()
                   (minuet-duet-history-benchmark--frequent nil nil))
                 #'minuet-duet-history-benchmark--edit-burst)
           (list "frequent edits: one flush" runs
                 (lambda ()
                   (minuet-duet-history-benchmark--frequent t nil))
                 #'minuet-duet-history-benchmark--edit-burst)
           (list "frequent edits: flush each" runs
                 (lambda ()
                   (minuet-duet-history-benchmark--frequent t t))
                 #'minuet-duet-history-benchmark--edit-burst)))
         results)
    (princ (format "Emacs %s; %d lines; %d edits/burst\n\n"
                   emacs-version
                   minuet-duet-history-benchmark-lines
                   minuet-duet-history-benchmark-burst-edits))
    (dolist (case cases)
      (push (apply #'minuet-duet-history-benchmark--measure case)
            results))
    (minuet-duet-history-benchmark--print (nreverse results))))

(provide 'minuet-duet-history-benchmarks)
;;; minuet-duet-history-benchmarks.el ends here
