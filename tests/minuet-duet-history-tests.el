;;; minuet-duet-history-tests.el --- Tests for minuet-duet-history -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for `minuet-duet-history-mode' and its helpers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "test-helper"
                        (file-name-directory
                         (or load-file-name (buffer-file-name))))
      nil t)

(require 'minuet-duet-history)
(require 'minuet-duet)

(defvar minuet-duet-history-test--scripts-directory
  (expand-file-name "scripts"
                    (file-name-directory
                     (or load-file-name (buffer-file-name))))
  "Directory holding the diff-program test fixtures.")

(defun minuet-duet-history-test--script (name)
  "Return the path of fixture script NAME."
  (expand-file-name name minuet-duet-history-test--scripts-directory))

(defmacro minuet-duet-history-test--with-buffer (&rest body)
  "Run BODY in a temp buffer with isolated global tracking state.
Temp buffers are created with `inhibit-buffer-hooks', so
`kill-buffer-hook' never deregisters them; let-binding the globals
keeps tests independent.  The mode is disabled before the buffer dies
so its diff process is cancelled and its snapshot files are deleted,
any timer created inside is cancelled, and files stranded by the test
are swept."
  (declare (indent 0))
  `(let ((minuet-duet-history--buffers nil)
         (minuet-duet-history--timer nil)
         (minuet-duet-history--temp-files nil))
     (unwind-protect
         (with-temp-buffer
           (unwind-protect
               (progn ,@body)
             (when minuet-duet-history-mode
               (minuet-duet-history-mode -1))))
       (when minuet-duet-history--timer
         (cancel-timer minuet-duet-history--timer))
       (dolist (file minuet-duet-history--temp-files)
         (ignore-errors (delete-file file))))))

(defun minuet-duet-history-test--flush ()
  "Flush the current buffer, waiting generously for the async diff.
Wraps `minuet-duet-history-flush' with a large timeout so tests can
treat flushing as synchronous."
  (let ((minuet-duet-history-flush-timeout 5))
    (minuet-duet-history-flush)))

;;;;;
;; Diff output post-processing
;;;;;

(defun minuet-duet-history-test--entry-string (output)
  "Run `minuet-duet-history--entry-string' on OUTPUT in a temp buffer."
  (with-temp-buffer
    (insert output)
    (minuet-duet-history--entry-string)))

(defun minuet-duet-history-test--hunk-span (output)
  "Run `minuet-duet-history--hunk-span' on OUTPUT in a temp buffer."
  (with-temp-buffer
    (insert output)
    (minuet-duet-history--hunk-span)))

(ert-deftest minuet-duet-history-entry-string ()
  "The ---/+++ header lines and trailing newline are dropped."
  (should (equal (minuet-duet-history-test--entry-string
                  "--- /tmp/a\t2026-01-01\n+++ /tmp/b\t2026-01-01\n@@ -1 +1 @@\n-a\n+b\n")
                 "@@ -1 +1 @@\n-a\n+b"))
  ;; Headerless input is returned as-is (minus the trailing newline).
  (should (equal (minuet-duet-history-test--entry-string "@@ -1 +1 @@\n-a\n+b")
                 "@@ -1 +1 @@\n-a\n+b")))

(ert-deftest minuet-duet-history-hunk-span-single ()
  "A single hunk spans its own line count; omitted counts mean 1."
  (should (= (minuet-duet-history-test--hunk-span "@@ -2 +2 @@\n-b\n+x") 1))
  (should (= (minuet-duet-history-test--hunk-span
              "@@ -1,3 +1,4 @@\n a\n+x\n b\n c")
             4)))

(ert-deftest minuet-duet-history-hunk-span-multi-hunk ()
  "The span covers first hunk start through last hunk end, per side."
  ;; Old side: 1 .. (10+4) => 13; new side: 1 .. (10+6) => 15.
  (should (= (minuet-duet-history-test--hunk-span
              "@@ -1,3 +1,3 @@\n a\n-b\n+B\n@@ -10,4 +10,6 @@\n x\n+y\n+z\n w")
             15)))

(ert-deftest minuet-duet-history-hunk-span-zero-count ()
  "Zero-count sides (pure insertions/deletions) are handled."
  (should (= (minuet-duet-history-test--hunk-span "@@ -2,0 +3,2 @@\n+x\n+y") 2)))

(ert-deftest minuet-duet-history-hunk-span-no-hunks ()
  "Output without @@ headers (e.g. binary files) yields nil."
  (should-not (minuet-duet-history-test--hunk-span
               "Binary files a and b differ\n"))
  (should-not (minuet-duet-history-test--hunk-span "")))

;;;;;
;; Entry bounding
;;;;;

(ert-deftest minuet-duet-history-push-entry-bounded ()
  "Pushing past the cap drops the oldest entries."
  (with-temp-buffer
    (let ((minuet-duet-history-max-entries 3))
      (dolist (entry '("1" "2" "3" "4" "5"))
        (minuet-duet-history--push-entry entry))
      (should (equal minuet-duet-history--entries '("5" "4" "3"))))))

;;;;;
;; Flush integration
;;;;;

(ert-deftest minuet-duet-history-flush-records-entries ()
  "Each flush of a changed buffer records one coalesced entry, newest first."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\nc\n")
    (minuet-duet-history-mode 1)
    (should minuet-duet-history-mode)
    (should (eql minuet-duet-history--snapshot-tick
                 (buffer-chars-modified-tick)))
    (goto-char (point-min))
    (forward-line 1)
    (insert "new line\n")
    (should-not (eql minuet-duet-history--snapshot-tick
                     (buffer-chars-modified-tick)))
    (minuet-duet-history-test--flush)
    (should (equal minuet-duet-history--entries
                   '("@@ -1,3 +1,4 @@\n a\n+new line\n b\n c")))
    (should (eql minuet-duet-history--snapshot-tick
                 (buffer-chars-modified-tick)))
    ;; A second burst becomes a second entry, newest first.
    (goto-char (point-max))
    (insert "d\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 2))
    (should (string-match-p "\\+d" (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-flush-strips-file-headers ()
  "Recorded entries contain no file header lines or temp file paths."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "c\n")
    (minuet-duet-history-test--flush)
    (let ((entry (car minuet-duet-history--entries)))
      (should entry)
      (should (string-prefix-p "@@ " entry))
      (should-not (string-match-p "^--- " entry))
      (should-not (string-match-p "^\\+\\+\\+ " entry))
      (should-not (string-match-p (regexp-quote temporary-file-directory)
                                  entry)))))

(ert-deftest minuet-duet-history-flush-ignores-reverted-edit ()
  "An edit undone back to the snapshot updates the tick but adds no entry."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\nc\n")
    (minuet-duet-history-mode 1)
    (let ((old-tick minuet-duet-history--snapshot-tick))
      (goto-char (point-min))
      (insert "x")
      (delete-char -1)
      (should-not (eql minuet-duet-history--snapshot-tick
                       (buffer-chars-modified-tick)))
      (minuet-duet-history-test--flush)
      (should-not minuet-duet-history--entries)
      (should-not (eql minuet-duet-history--snapshot-tick old-tick))
      (should (eql minuet-duet-history--snapshot-tick
                   (buffer-chars-modified-tick))))))

(ert-deftest minuet-duet-history-flush-skips-clean-buffer ()
  "Flushing without pending changes does nothing."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (minuet-duet-history-test--flush)
    (should-not minuet-duet-history--entries)))

(ert-deftest minuet-duet-history-flush-skips-oversized-region ()
  "Edits larger than the region cap are skipped but re-snapshot.
The measured span includes the hunks' context lines, so the cap must
leave room for `minuet-duet-history-diff-context-lines' around a small
edit."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (minuet-duet-history-mode 1)
    (let ((minuet-duet-history-max-region-lines 4))
      (goto-char (point-max))
      (insert "1\n2\n3\n4\n5\n")
      (minuet-duet-history-test--flush)
      (should-not minuet-duet-history--entries)
      ;; Snapshot was updated: a subsequent small edit diffs against the
      ;; post-paste content.
      (goto-char (point-min))
      (insert "z\n")
      (minuet-duet-history-test--flush)
      (should (= (length minuet-duet-history--entries) 1))
      (should (string-match-p "\\+z" (car minuet-duet-history--entries))))))

(ert-deftest minuet-duet-history-flush-disables-on-oversized-buffer ()
  "Tracking auto-disables when the buffer grows past the size cap."
  (minuet-duet-history-test--with-buffer
    (insert "small")
    (minuet-duet-history-mode 1)
    (let ((minuet-duet-history-max-buffer-size 10))
      (goto-char (point-max))
      (insert "\nmore than ten characters\n")
      (minuet-duet-history-test--flush)
      (should-not minuet-duet-history-mode)
      (should-not minuet-duet-history--snapshot-file)
      (should-not minuet-duet-history--temp-files))))

(ert-deftest minuet-duet-history-mode-refuses-oversized-buffer ()
  "The mode refuses to enable in a buffer over the size cap."
  (minuet-duet-history-test--with-buffer
    (insert "more than ten characters")
    (let ((minuet-duet-history-max-buffer-size 10))
      (minuet-duet-history-mode 1)
      (should-not minuet-duet-history-mode)
      (should-not (memq (current-buffer) minuet-duet-history--buffers))
      (should-not minuet-duet-history--temp-files))))

(ert-deftest minuet-duet-history-mode-refuses-missing-diff-program ()
  "The mode refuses to enable when the diff program is not found."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (let ((minuet-duet-history-diff-program "minuet-no-such-diff-xyz"))
      (minuet-duet-history-mode 1)
      (should-not minuet-duet-history-mode)
      (should-not (memq (current-buffer) minuet-duet-history--buffers))
      (should-not minuet-duet-history--timer)
      (should-not minuet-duet-history--temp-files))))

(ert-deftest minuet-duet-history-refusal-deregisters-stale-registration ()
  "A size refusal after a local-variable wipe deregisters the buffer.
Otherwise the buffer would linger in the tracked list with the timer
alive until the next idle prune."
  (minuet-duet-history-test--with-buffer
    (insert "small")
    (minuet-duet-history-mode 1)
    (should (memq (current-buffer) minuet-duet-history--buffers))
    (kill-all-local-variables)
    (goto-char (point-max))
    (insert "\nmore than ten characters\n")
    (let ((minuet-duet-history-max-buffer-size 10))
      (minuet-duet-history-mode 1))
    (should-not minuet-duet-history-mode)
    (should-not (memq (current-buffer) minuet-duet-history--buffers))
    (should-not minuet-duet-history--timer)))

(ert-deftest minuet-duet-history-flush-widens-around-narrowing ()
  "Edits made while narrowed diff against the widened buffer content."
  (minuet-duet-history-test--with-buffer
    (dotimes (i 10) (insert (format "line-%d\n" i)))
    (minuet-duet-history-mode 1)
    ;; Narrow to the first two lines, then insert a line at the edge.
    (narrow-to-region (point-min) 15)
    (goto-char (point-max))
    (insert "x\n")
    (minuet-duet-history-test--flush)
    ;; The entry reflects only the real edit, not the text hidden by the
    ;; narrowing, and the narrowing itself is preserved.
    (should (equal minuet-duet-history--entries
                   '("@@ -1,4 +1,5 @@\n line-0\n line-1\n+x\n line-2\n line-3")))
    (should (buffer-narrowed-p))))

(ert-deftest minuet-duet-history-flush-sees-silent-modifications ()
  "Edits made with modification hooks inhibited are still recorded.
The flush is gated on `buffer-chars-modified-tick', which advances for
`with-silent-modifications' edits even though `after-change-functions'
never runs."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (with-silent-modifications (insert "silent\n"))
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "^\\+silent$"
                            (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-flush-multi-hunk-entry ()
  "Two distant edits in one burst yield one entry with two @@ groups."
  (minuet-duet-history-test--with-buffer
    (dotimes (i 12) (insert (format "line-%d\n" i)))
    (minuet-duet-history-mode 1)
    (goto-char (point-min))
    (insert "top\n")
    (goto-char (point-max))
    (insert "bottom\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (let ((entry (car minuet-duet-history--entries)))
      (should (= (minuet-duet--count-occurrences entry "@@ -") 2))
      (should (string-match-p "^\\+top$" entry))
      (should (string-match-p "^\\+bottom$" entry)))))

(ert-deftest minuet-duet-history-flush-non-ascii-round-trip ()
  "Non-ASCII text is recorded intact regardless of the file coding.
Snapshots are always written as utf-8, so a buffer whose file coding
system cannot even encode its content still round-trips."
  (minuet-duet-history-test--with-buffer
    (insert "héllo\n")
    (set-buffer-file-coding-system 'latin-1 t)
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "wörld / 世界\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+wörld / 世界"
                            (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-reenable-keeps-history ()
  "Enabling the mode in an already-tracked buffer keeps its history."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (minuet-duet-history-mode 1)
    (should (= (length minuet-duet-history--entries) 1))
    (should (equal minuet-duet-history--buffers (list (current-buffer))))))

(ert-deftest minuet-duet-history-reenable-after-local-wipe-reinitializes ()
  "Re-enabling after `kill-all-local-variables' restores tracking.
Simulates `normal-mode' on revert: local state and hooks are wiped
while the buffer stays in the tracked list, then a mode hook re-fires."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (minuet-duet-history-mode 1)
    (kill-all-local-variables)
    (should-not minuet-duet-history--snapshot-file)
    (should (memq (current-buffer) minuet-duet-history--buffers))
    (minuet-duet-history-mode 1)
    (should minuet-duet-history--snapshot-file)
    (should (file-exists-p minuet-duet-history--snapshot-file))
    (should (memq #'minuet-duet-history--on-kill-buffer kill-buffer-hook))
    (goto-char (point-max))
    (insert "c\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+c" (car minuet-duet-history--entries)))
    ;; Re-registration does not duplicate the buffer in the list.
    (should (equal minuet-duet-history--buffers (list (current-buffer))))))

(ert-deftest minuet-duet-history-reenable-after-snapshot-deletion ()
  "Re-enabling after the snapshot file vanished re-initializes tracking."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (minuet-duet-history-test--flush)
    (should minuet-duet-history--entries)
    (delete-file minuet-duet-history--snapshot-file)
    (minuet-duet-history-mode 1)
    (should minuet-duet-history--snapshot-file)
    (should (file-exists-p minuet-duet-history--snapshot-file))
    (should-not minuet-duet-history--entries)
    (goto-char (point-max))
    (insert "c\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+c" (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-flush-api-never-signals ()
  "`minuet-duet-history-flush' logs flush errors instead of signaling."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (cl-letf (((symbol-function 'minuet-duet-history--start-flush)
               (lambda () (error "Boom"))))
      (minuet-duet-history-flush))
    ;; The pending edit survives the failed flush and is recorded by
    ;; the next successful one.
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+b" (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-flush-retries-after-diff-failure ()
  "A failing diff program records nothing and leaves the burst pending."
  (skip-unless (file-executable-p
                (minuet-duet-history-test--script "diff-exit-2.sh")))
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (let ((minuet-duet-history-diff-program
           (minuet-duet-history-test--script "diff-exit-2.sh")))
      (minuet-duet-history-test--flush))
    (should-not minuet-duet-history--entries)
    ;; The tick is untouched, so the burst is still pending and the
    ;; next flush with a working program records it.
    (should-not (eql minuet-duet-history--snapshot-tick
                     (buffer-chars-modified-tick)))
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+b" (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-flush-bounded-wait ()
  "The public flush returns at its deadline while the diff completes later."
  (skip-unless (file-executable-p
                (minuet-duet-history-test--script "slow-diff.sh")))
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (let ((minuet-duet-history-diff-program
           (minuet-duet-history-test--script "slow-diff.sh"))
          (minuet-duet-history-flush-timeout 0.05)
          (start (float-time)))
      (minuet-duet-history-flush)
      ;; Returned promptly, with the diff still in flight.
      (should (< (- (float-time) start) 0.5))
      (should-not minuet-duet-history--entries)
      (should minuet-duet-history--process)
      ;; The sentinel records the entry once the slow diff finishes.
      (minuet-test--wait-until
       (lambda () minuet-duet-history--entries)
       5 "slow diff never produced a history entry")
      (should (string-match-p "\\+b" (car minuet-duet-history--entries)))
      (should (eql minuet-duet-history--snapshot-tick
                   (buffer-chars-modified-tick))))))

(ert-deftest minuet-duet-history-flush-skips-while-in-flight ()
  "No second diff is spawned while one is already running."
  (skip-unless (file-executable-p
                (minuet-duet-history-test--script "slow-diff.sh")))
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (let ((minuet-duet-history-diff-program
           (minuet-duet-history-test--script "slow-diff.sh"))
          (minuet-duet-history-flush-timeout 0.05))
      (minuet-duet-history-flush)
      (let ((process minuet-duet-history--process))
        (should process)
        (minuet-duet-history--flush-all)
        (should (eq minuet-duet-history--process process))
        (minuet-duet-history--start-flush)
        (should (eq minuet-duet-history--process process))))))

(ert-deftest minuet-duet-history-clear-cancels-in-flight-diff ()
  "Clearing while a diff is in flight cancels it cleanly.
The late sentinel sees the eq-guard mismatch: no entry is recorded and
its output buffers are disposed of."
  (skip-unless (file-executable-p
                (minuet-duet-history-test--script "slow-diff.sh")))
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (let ((minuet-duet-history-diff-program
           (minuet-duet-history-test--script "slow-diff.sh"))
          (minuet-duet-history-flush-timeout 0.05))
      (minuet-duet-history-flush)
      (let* ((process minuet-duet-history--process)
             (stdout (process-buffer process))
             (stderr (process-get process :minuet-stderr)))
        (should process)
        (minuet-duet-history-clear)
        (should-not minuet-duet-history--process)
        (should-not (process-live-p process))
        (minuet-test--wait-until
         (lambda () (not (or (buffer-live-p stdout) (buffer-live-p stderr))))
         5 "cancelled sentinel never disposed of its output buffers")
        ;; The sentinel has run by now; the cancelled diff left no entry.
        (should-not minuet-duet-history--entries)
        ;; The clear absorbed the pending edit into a fresh snapshot, so
        ;; there is nothing left to flush.
        (should (eql minuet-duet-history--snapshot-tick
                     (buffer-chars-modified-tick)))
        (minuet-duet-history-test--flush)
        (should-not minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-disable-cancels-in-flight-diff ()
  "Disabling the mode while a diff is in flight cancels it cleanly.
No entry is recorded, the late sentinel's output buffers are disposed
of, and the snapshot files are deleted."
  (skip-unless (file-executable-p
                (minuet-duet-history-test--script "slow-diff.sh")))
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (let ((minuet-duet-history-diff-program
           (minuet-duet-history-test--script "slow-diff.sh"))
          (minuet-duet-history-flush-timeout 0.05)
          (snapshot minuet-duet-history--snapshot-file)
          (pending minuet-duet-history--pending-file))
      (minuet-duet-history-flush)
      (let* ((process minuet-duet-history--process)
             (stdout (process-buffer process))
             (stderr (process-get process :minuet-stderr)))
        (should process)
        (minuet-duet-history-mode -1)
        (should-not (process-live-p process))
        (should-not (file-exists-p snapshot))
        (should-not (file-exists-p pending))
        (minuet-test--wait-until
         (lambda () (not (or (buffer-live-p stdout) (buffer-live-p stderr))))
         5 "cancelled sentinel never disposed of its output buffers")
        (should-not minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-clear-discards-entries ()
  "Clearing discards recorded entries and re-snapshots pending edits."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (minuet-duet-history-test--flush)
    (should minuet-duet-history--entries)
    ;; A pending, unflushed edit is absorbed by the new snapshot.
    (insert "c\n")
    (minuet-duet-history-clear)
    (should-not minuet-duet-history--entries)
    (minuet-duet-history-test--flush)
    (should-not minuet-duet-history--entries)))

(ert-deftest minuet-duet-history-clear-disables-on-oversized-buffer ()
  "Clearing disables tracking instead of snapshotting an oversized buffer."
  (minuet-duet-history-test--with-buffer
    (insert "small")
    (let ((minuet-duet-history-max-buffer-size 10))
      (minuet-duet-history-mode 1)
      (let ((snapshot minuet-duet-history--snapshot-file)
            (pending minuet-duet-history--pending-file))
        (goto-char (point-max))
        (insert "\nmore than ten characters\n")
        (minuet-duet-history-clear)
        (should-not minuet-duet-history-mode)
        (should-not minuet-duet-history--snapshot-file)
        (should-not minuet-duet-history--snapshot-tick)
        (should-not minuet-duet-history--entries)
        (should-not (file-exists-p snapshot))
        (should-not (file-exists-p pending))
        (should-not (memq (current-buffer) minuet-duet-history--buffers))
        (should-not minuet-duet-history--timer)))))

;;;;;
;; Snapshot file lifecycle
;;;;;

(ert-deftest minuet-duet-history-disable-deletes-files ()
  "Disabling the mode deletes both snapshot files and the registry entries."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (let ((snapshot minuet-duet-history--snapshot-file)
          (pending minuet-duet-history--pending-file))
      (should (file-exists-p snapshot))
      (should (file-exists-p pending))
      (should (= (length minuet-duet-history--temp-files) 2))
      (minuet-duet-history-mode -1)
      (should-not (file-exists-p snapshot))
      (should-not (file-exists-p pending))
      (should-not minuet-duet-history--temp-files)
      (should-not minuet-duet-history--snapshot-file)
      (should-not minuet-duet-history--pending-file))))

(ert-deftest minuet-duet-history-kill-buffer-deletes-files ()
  "Killing a tracked buffer cancels its diff and deletes its files."
  (let ((minuet-duet-history--buffers nil)
        (minuet-duet-history--timer nil)
        (minuet-duet-history--temp-files nil)
        (buffer (generate-new-buffer "minuet-duet-history-kill-test"))
        snapshot pending)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "a\n")
            (minuet-duet-history-mode 1)
            (setq snapshot minuet-duet-history--snapshot-file
                  pending minuet-duet-history--pending-file))
          (kill-buffer buffer)
          (should-not (file-exists-p snapshot))
          (should-not (file-exists-p pending))
          (should-not minuet-duet-history--temp-files)
          (should-not minuet-duet-history--buffers)
          (should-not minuet-duet-history--timer))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when minuet-duet-history--timer
        (cancel-timer minuet-duet-history--timer))
      (dolist (file minuet-duet-history--temp-files)
        (ignore-errors (delete-file file))))))

(ert-deftest minuet-duet-history-cleanup-all-sweeps-registry ()
  "`minuet-duet-history--cleanup-all' deletes every allocated file."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (let ((snapshot minuet-duet-history--snapshot-file)
          (pending minuet-duet-history--pending-file))
      (minuet-duet-history--cleanup-all)
      (should-not (file-exists-p snapshot))
      (should-not (file-exists-p pending))
      (should-not minuet-duet-history--temp-files))))

;;;;;
;; Timer & buffer lifecycle
;;;;;

(ert-deftest minuet-duet-history-timer-lifecycle ()
  "One shared idle timer exists while any buffer is tracked."
  (let ((minuet-duet-history--buffers nil)
        (minuet-duet-history--timer nil)
        (minuet-duet-history--temp-files nil)
        (buf1 (generate-new-buffer "minuet-duet-history-test-1"))
        (buf2 (generate-new-buffer "minuet-duet-history-test-2")))
    (unwind-protect
        (progn
          (with-current-buffer buf1 (minuet-duet-history-mode 1))
          (should minuet-duet-history--timer)
          (with-current-buffer buf2 (minuet-duet-history-mode 1))
          (should (= (length minuet-duet-history--buffers) 2))
          (with-current-buffer buf1 (minuet-duet-history-mode -1))
          (should minuet-duet-history--timer)
          (should (equal minuet-duet-history--buffers (list buf2)))
          (kill-buffer buf2)
          (should-not minuet-duet-history--buffers)
          (should-not minuet-duet-history--timer))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2))
      (when minuet-duet-history--timer
        (cancel-timer minuet-duet-history--timer))
      (dolist (file minuet-duet-history--temp-files)
        (ignore-errors (delete-file file))))))

(ert-deftest minuet-duet-history-clone-registers-for-idle-flush ()
  "A clone inheriting enabled history mode participates in idle flushes.
The clone gets its own snapshot files instead of aliasing the base
buffer's, and disabling it leaves the base buffer's files alone."
  (let ((minuet-duet-history--buffers nil)
        (minuet-duet-history--timer nil)
        (minuet-duet-history--temp-files nil)
        (base (generate-new-buffer "minuet-duet-history-clone-base"))
        clone)
    (unwind-protect
        (progn
          (with-current-buffer base
            (insert "a\n")
            (minuet-duet-history-mode 1)
            (insert "before-clone\n")
            (minuet-duet-history-test--flush)
            (setq clone
                  (clone-indirect-buffer
                   (generate-new-buffer-name
                    "minuet-duet-history-clone-indirect")
                   nil)))
          (should (buffer-local-value 'minuet-duet-history-mode clone))
          (should (memq clone minuet-duet-history--buffers))
          (should (equal (buffer-local-value
                          'minuet-duet-history--entries clone)
                         (buffer-local-value
                          'minuet-duet-history--entries base)))
          ;; The clone allocated its own snapshot files.
          (should-not (equal (buffer-local-value
                              'minuet-duet-history--snapshot-file clone)
                             (buffer-local-value
                              'minuet-duet-history--snapshot-file base)))
          (with-current-buffer clone
            (goto-char (point-max))
            (insert "b\n"))
          (minuet-duet-history--flush-all)
          (minuet-test--wait-until
           (lambda () (= (length (buffer-local-value
                                  'minuet-duet-history--entries clone))
                         2))
           5 "clone never recorded the idle flush")
          ;; The clone keeps the shared timer alive independently of
          ;; the base buffer, whose files are untouched by the clone.
          (let ((base-snapshot (buffer-local-value
                                'minuet-duet-history--snapshot-file base)))
            (with-current-buffer base
              (minuet-duet-history-mode -1))
            (should-not (file-exists-p base-snapshot)))
          (should minuet-duet-history--timer)
          (should (equal minuet-duet-history--buffers (list clone)))
          (should (file-exists-p (buffer-local-value
                                  'minuet-duet-history--snapshot-file clone))))
      (when (buffer-live-p clone) (kill-buffer clone))
      (when (buffer-live-p base) (kill-buffer base))
      (when minuet-duet-history--timer
        (cancel-timer minuet-duet-history--timer))
      (dolist (file minuet-duet-history--temp-files)
        (ignore-errors (delete-file file))))))

(ert-deftest minuet-duet-history-flush-all-flushes-and-prunes ()
  "The timer flush records pending edits and prunes dead buffers.
Files stranded by a buffer that died without running its kill hooks
are swept when the tracked-buffer list empties."
  (let ((minuet-duet-history--buffers nil)
        (minuet-duet-history--timer nil)
        (minuet-duet-history--temp-files nil)
        (buf1 (generate-new-buffer "minuet-duet-history-flush-all-1"))
        (buf2 (generate-new-buffer "minuet-duet-history-flush-all-2"))
        buf2-snapshot)
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (insert "a\n")
            (minuet-duet-history-mode 1)
            (goto-char (point-max))
            (insert "b\n"))
          (with-current-buffer buf2
            (minuet-duet-history-mode 1)
            (setq buf2-snapshot minuet-duet-history--snapshot-file)
            ;; Simulate a buffer that died without running its hooks.
            (remove-hook 'kill-buffer-hook
                         #'minuet-duet-history--on-kill-buffer t))
          (kill-buffer buf2)
          (minuet-duet-history--flush-all)
          (should (equal minuet-duet-history--buffers (list buf1)))
          (minuet-test--wait-until
           (lambda () (= (length (buffer-local-value
                                  'minuet-duet-history--entries buf1))
                         1))
           5 "flush-all never recorded buf1's pending edit")
          ;; buf2's stranded files linger in the registry until the
          ;; last tracked buffer deregisters, which sweeps them.
          (should (file-exists-p buf2-snapshot))
          (kill-buffer buf1)
          (should-not (file-exists-p buf2-snapshot))
          (should-not minuet-duet-history--temp-files))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2))
      (when minuet-duet-history--timer
        (cancel-timer minuet-duet-history--timer))
      (dolist (file minuet-duet-history--temp-files)
        (ignore-errors (delete-file file))))))

;;;;;
;; Prompt text
;;;;;

(ert-deftest minuet-duet-history-prompt-text-empty ()
  "No history or disabled mode yields nil."
  (minuet-duet-history-test--with-buffer
    (should-not (minuet-duet-history-prompt-text))
    (minuet-duet-history-mode 1)
    (should-not (minuet-duet-history-prompt-text))))

(ert-deftest minuet-duet-history-prompt-text-oldest-first ()
  "Entries are rendered oldest first inside the wrapper tags."
  (minuet-duet-history-test--with-buffer
    (minuet-duet-history-mode 1)
    (setq minuet-duet-history--entries '("E-NEWEST" "E-MIDDLE" "E-OLDEST"))
    (let ((text (minuet-duet-history-prompt-text)))
      (should (string-prefix-p "<edit_history>\n" text))
      (should (string-suffix-p "\n</edit_history>" text))
      (should (string-match-p "E-OLDEST\n\nE-MIDDLE\n\nE-NEWEST" text)))))

(ert-deftest minuet-duet-history-prompt-text-nil-while-narrowed ()
  "History is withheld from prompts while the buffer is narrowed.
Entries are diffed against the widened buffer, so rendering them under
narrowing could expose concealed text and would use line numbers
inconsistent with the narrowed document.  Entries survive and become
available again after widening."
  (minuet-duet-history-test--with-buffer
    (dotimes (i 6) (insert (format "line-%d\n" i)))
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "x\n")
    (minuet-duet-history-test--flush)
    (should (minuet-duet-history-prompt-text))
    (narrow-to-region (point-min) 10)
    (should-not (minuet-duet-history-prompt-text))
    (widen)
    (should (minuet-duet-history-prompt-text))))

(ert-deftest minuet-duet-history-prompt-text-budget ()
  "Older entries are dropped when over budget; the newest always stays."
  (minuet-duet-history-test--with-buffer
    (minuet-duet-history-mode 1)
    (setq minuet-duet-history--entries '("E-NEWEST" "E-MIDDLE" "E-OLDEST"))
    (let ((minuet-duet-history-max-prompt-chars 10))
      (let ((text (minuet-duet-history-prompt-text)))
        (should (string-match-p "E-NEWEST" text))
        (should-not (string-match-p "E-MIDDLE" text))
        (should-not (string-match-p "E-OLDEST" text))))
    (let ((minuet-duet-history-max-prompt-chars 2))
      (should (string-match-p "E-NEWEST" (minuet-duet-history-prompt-text))))))

;;;;;
;; Chat input integration
;;;;;

(ert-deftest minuet-duet-history-chat-input-with-history ()
  "The edit history section precedes the non-editable region."
  (let* ((context '(:edit-history "<edit_history>\nstuff\n</edit_history>"
                    :non-editable-region-before "before\n"
                    :editable-region-before-cursor "edit-before"
                    :editable-region-after-cursor "edit-after"
                    :non-editable-region-after "\nafter"))
         (result (minuet-duet--make-chat-input context
                                               minuet-duet-default-chat-input)))
    (should (string-prefix-p "<edit_history>\nstuff\n</edit_history>\nbefore\n"
                             result))))

(ert-deftest minuet-duet-history-chat-input-without-history ()
  "Without history the chat input is unchanged (no stray leading text)."
  (let* ((context '(:non-editable-region-before "before\n"
                    :editable-region-before-cursor "edit-before"
                    :editable-region-after-cursor "edit-after"
                    :non-editable-region-after "\nafter"))
         (result (minuet-duet--make-chat-input context
                                               minuet-duet-default-chat-input)))
    (should (string-prefix-p "before\n" result))))

;;;;;
;; Predict integration
;;;;;

(ert-deftest minuet-duet-history-predict-flushes-and-includes-history ()
  "`minuet-duet-predict' flushes the pending burst into the request prompt."
  (minuet-duet-history-test--with-buffer
    (insert "line-1\nline-2\nline-3\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "line-4\n")
    (should-not (eql minuet-duet-history--snapshot-tick
                     (buffer-chars-modified-tick)))
    (let ((captured nil)
          (minuet-duet-provider 'openai-compatible)
          (minuet-duet-history-flush-timeout 5))
      (cl-letf (((symbol-function 'minuet-duet--openai-compatible-complete)
                 (lambda (context callback)
                   (setq captured (minuet-duet--make-chat-input
                                   context minuet-duet-default-chat-input))
                   (funcall callback nil))))
        (minuet-duet-predict))
      (should captured)
      ;; The burst typed right before predicting was flushed (within the
      ;; bounded wait) and rendered ahead of the document.
      (should (string-match-p "^\\+line-4$" captured))
      (should (< (string-match "<edit_history>" captured)
                 (string-match "line-1" captured))))))

(provide 'minuet-duet-history-tests)
;;; minuet-duet-history-tests.el ends here
