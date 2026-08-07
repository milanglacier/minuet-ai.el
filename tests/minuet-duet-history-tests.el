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
  "Run BODY in a temp buffer with an isolated snapshot directory.
Temp buffers are created with `inhibit-buffer-hooks', so
`kill-buffer-hook' never runs for them; the mode is disabled before
the buffer dies so its diff process is cancelled, its timer chain
ends, and its snapshot files are deleted.  The let-bound snapshot
directory is deleted afterwards, sweeping files stranded by the
test."
  (declare (indent 0))
  `(let ((minuet-duet-history--directory nil))
     (unwind-protect
         (with-temp-buffer
           (unwind-protect
               (progn ,@body)
             (when minuet-duet-history-mode
               (minuet-duet-history-mode -1))))
       (minuet-duet-history--delete-directory))))

(defun minuet-duet-history-test--timers-for (buffer)
  "Return the scheduled history timers of BUFFER on `timer-idle-list'."
  (cl-remove-if-not
   (lambda (timer)
     (and (eq (timer--function timer) #'minuet-duet-history--on-timer)
          (equal (timer--args timer) (list buffer))))
   timer-idle-list))

(defun minuet-duet-history-test--directory-files ()
  "Return the files currently present in the snapshot directory."
  (and minuet-duet-history--directory
       (file-directory-p minuet-duet-history--directory)
       (directory-files minuet-duet-history--directory nil
                        directory-files-no-dot-files-regexp)))

(defun minuet-duet-history-test--flush ()
  "Flush the current buffer, waiting generously for the async diff.
Wraps `minuet-duet-history-flush' with a large timeout so tests can
treat flushing as synchronous."
  (let ((minuet-duet-history-flush-timeout 5))
    (minuet-duet-history-flush)))

;;;;;
;; Diff output post-processing
;;;;;

(defun minuet-duet-history-test--entry-string (output &optional budget)
  "Run `minuet-duet-history--entry-string' on OUTPUT in a temp buffer.
BUDGET defaults to a bound larger than any test diff."
  (with-temp-buffer
    (insert output)
    (minuet-duet-history--entry-string (or budget 10000))))

(ert-deftest minuet-duet-history-entry-string ()
  "The ---/+++ header lines and trailing newline are dropped."
  (should (equal (minuet-duet-history-test--entry-string
                  "--- /tmp/a\t2026-01-01\n+++ /tmp/b\t2026-01-01\n@@ -1 +1 @@\n-a\n+b\n")
                 "@@ -1 +1 @@\n-a\n+b"))
  ;; Headerless input is returned as-is (minus the trailing newline).
  (should (equal (minuet-duet-history-test--entry-string "@@ -1 +1 @@\n-a\n+b")
                 "@@ -1 +1 @@\n-a\n+b")))

(ert-deftest minuet-duet-history-entry-string-git-headers ()
  "The extra header lines of git diff --no-index output are dropped."
  (should (equal (minuet-duet-history-test--entry-string
                  (concat "diff --git a/tmp/snapshot-1 b/tmp/snapshot-2\n"
                          "index e69de29..8baef1b 100644\n"
                          "--- a/tmp/snapshot-1\n"
                          "+++ b/tmp/snapshot-2\n"
                          "@@ -1 +1 @@\n-a\n+b\n"))
                 "@@ -1 +1 @@\n-a\n+b"))
  ;; Function context that git appends after the hunk header is kept.
  (should (equal (minuet-duet-history-test--entry-string
                  (concat "diff --git a/x b/y\n"
                          "index 1111111..2222222 100644\n"
                          "--- a/x\n+++ b/y\n"
                          "@@ -2,3 +2,4 @@ (defun foo ()\n a\n+b\n c\n d\n"))
                 "@@ -2,3 +2,4 @@ (defun foo ()\n a\n+b\n c\n d")))

(ert-deftest minuet-duet-history-entry-string-no-hunks ()
  "Output without @@ headers (e.g. binary files) yields nil."
  (should-not (minuet-duet-history-test--entry-string
               "Binary files a and b differ\n"))
  (should-not (minuet-duet-history-test--entry-string "")))

(ert-deftest minuet-duet-history-entry-string-truncates-to-hunks ()
  "An over-budget diff keeps the leading whole hunks that fit."
  (let ((diff (concat "@@ -1 +1 @@\n-a\n+b\n"
                      "@@ -5 +5 @@\n-c\n+d\n"
                      "@@ -9 +9 @@\n-e\n+f\n")))
    ;; The whole entry (trailing newline dropped) is 53 chars; the leading
    ;; one and two hunks measure 17 and 35 chars.
    (should (equal (minuet-duet-history-test--entry-string diff 53)
                   "@@ -1 +1 @@\n-a\n+b\n@@ -5 +5 @@\n-c\n+d\n@@ -9 +9 @@\n-e\n+f"))
    (should (equal (minuet-duet-history-test--entry-string diff 40)
                   "@@ -1 +1 @@\n-a\n+b\n@@ -5 +5 @@\n-c\n+d"))
    (should (equal (minuet-duet-history-test--entry-string diff 20)
                   "@@ -1 +1 @@\n-a\n+b"))))

(ert-deftest minuet-duet-history-entry-string-first-hunk-over-budget ()
  "The entry is dropped when not even the first hunk fits."
  (should-not (minuet-duet-history-test--entry-string
               "@@ -1 +1 @@\n-a\n+b\n@@ -5 +5 @@\n-c\n+d\n" 10)))

(ert-deftest minuet-duet-history-entry-string-truncation-ignores-headers ()
  "The budget applies to the entry after the file headers are stripped."
  (should (equal (minuet-duet-history-test--entry-string
                  (concat "--- /tmp/a\t2026-01-01\n+++ /tmp/b\t2026-01-01\n"
                          "@@ -1 +1 @@\n-a\n+b\n@@ -5 +5 @@\n-c\n+d\n")
                  20)
                 "@@ -1 +1 @@\n-a\n+b")))

(ert-deftest minuet-duet-history-record-entry-honors-buffer-local-budgets ()
  "Entry recording reads both budget options from the tracked buffer."
  (dolist (budget-variable
           '(minuet-duet-history-max-entry-chars
             minuet-duet-history-max-prompt-chars))
    (let ((minuet-duet-history-max-entry-chars 10000)
          (minuet-duet-history-max-prompt-chars 10000)
          (stdout (generate-new-buffer
                   " *minuet-duet-history-budget-test*")))
      (unwind-protect
          (minuet-duet-history-test--with-buffer
            (set (make-local-variable budget-variable) 20)
            (with-current-buffer stdout
              (insert "@@ -1 +1 @@\n-a\n+b\n@@ -5 +5 @@\n-c\n+d\n"))
            (minuet-duet-history--record-entry stdout)
            (should (equal minuet-duet-history--entries
                           '("@@ -1 +1 @@\n-a\n+b"))))
        (kill-buffer stdout)))))

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

(ert-deftest minuet-duet-history-flush-list-diff-program ()
  "A list-valued diff program records entries like a plain program name."
  (skip-unless (executable-find "diff"))
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (let ((minuet-duet-history-diff-program '("diff")))
      (minuet-duet-history-mode 1)
      (should minuet-duet-history-mode)
      (goto-char (point-max))
      (insert "c\n")
      (minuet-duet-history-test--flush)
      (should (= (length minuet-duet-history--entries) 1))
      (should (string-match-p "\\+c" (car minuet-duet-history--entries))))))

(ert-deftest minuet-duet-history-flush-git-no-index ()
  "The git diff --no-index fallback records entries end-to-end.
Real git output has extra header lines before the hunks and exit
status 1 on differing files; the recorded entry contains only the
hunks, and a burst that reverts to the snapshot (git exits 0) records
nothing."
  (skip-unless (executable-find "git"))
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (let ((minuet-duet-history-diff-program
           '("git" "diff" "--no-index" "--no-ext-diff" "--no-textconv"
             "--no-color")))
      (minuet-duet-history-mode 1)
      (should minuet-duet-history-mode)
      (goto-char (point-max))
      (insert "c\n")
      (minuet-duet-history-test--flush)
      (let ((entry (car minuet-duet-history--entries)))
        (should entry)
        (should (string-prefix-p "@@ " entry))
        (should (string-match-p "\\+c" entry))
        (should-not (string-match-p "^diff --git" entry))
        (should-not (string-match-p (regexp-quote temporary-file-directory)
                                    entry)))
      ;; An edit undone before the flush leaves the buffer identical to
      ;; the snapshot; git exits 0 and no entry is recorded.
      (goto-char (point-max))
      (insert "d")
      (delete-char -1)
      (minuet-duet-history-test--flush)
      (should (= (length minuet-duet-history--entries) 1))
      (should (eql minuet-duet-history--snapshot-tick
                   (buffer-chars-modified-tick))))))

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

(ert-deftest minuet-duet-history-flush-truncates-oversized-entry ()
  "An over-budget multi-hunk burst records only its leading hunks."
  (minuet-duet-history-test--with-buffer
    (dotimes (i 20)
      (insert (format "line-%02d\n" i)))
    (minuet-duet-history-mode 1)
    ;; Edit two spots far enough apart for separate hunks; a budget that
    ;; only fits the first hunk drops the second.
    (goto-char (point-min))
    (insert "first\n")
    (goto-char (point-max))
    (insert "second\n")
    (let ((minuet-duet-history-max-entry-chars 60))
      (minuet-duet-history-test--flush))
    (should (= (length minuet-duet-history--entries) 1))
    (let ((entry (car minuet-duet-history--entries)))
      (should (string-match-p "\\+first" entry))
      (should-not (string-match-p "\\+second" entry)))))

(ert-deftest minuet-duet-history-flush-skips-oversized-hunk ()
  "A burst whose first hunk exceeds the budget is skipped but re-snapshots."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (minuet-duet-history-mode 1)
    (let ((minuet-duet-history-max-entry-chars 20))
      (goto-char (point-max))
      (insert "1234567890\n1234567890\n1234567890\n")
      (minuet-duet-history-test--flush)
      (should-not minuet-duet-history--entries))
    ;; Snapshot was updated: a subsequent small edit diffs against the
    ;; post-paste content.
    (goto-char (point-min))
    (insert "z\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+z" (car minuet-duet-history--entries)))))

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
      (should-not minuet-duet-history--timer)
      (should-not (minuet-duet-history-test--directory-files)))))

(ert-deftest minuet-duet-history-mode-refuses-oversized-buffer ()
  "The mode refuses to enable in a buffer over the size cap."
  (minuet-duet-history-test--with-buffer
    (insert "more than ten characters")
    (let ((minuet-duet-history-max-buffer-size 10))
      (minuet-duet-history-mode 1)
      (should-not minuet-duet-history-mode)
      (should-not minuet-duet-history--timer)
      ;; The refusal happens before any snapshot file is allocated.
      (should-not minuet-duet-history--directory))))

(ert-deftest minuet-duet-history-mode-refuses-missing-diff-program ()
  "The mode refuses to enable when the diff program is not found."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (let ((minuet-duet-history-diff-program "minuet-no-such-diff-xyz"))
      (minuet-duet-history-mode 1)
      (should-not minuet-duet-history-mode)
      (should-not minuet-duet-history--timer)
      ;; The refusal happens before any snapshot file is allocated.
      (should-not minuet-duet-history--directory))))

(ert-deftest minuet-duet-history-mode-refuses-missing-list-diff-program ()
  "A list-valued diff program is checked by its first element."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (let ((minuet-duet-history-diff-program
           '("minuet-no-such-diff-xyz" "--no-index")))
      (minuet-duet-history-mode 1)
      (should-not minuet-duet-history-mode)
      (should-not minuet-duet-history--timer)
      (should-not minuet-duet-history--directory))))

(ert-deftest minuet-duet-history-refusal-leaves-no-timer ()
  "A size refusal leaves the buffer untracked with no timer scheduled.
After a local-variable wipe (which tears tracking down via the
`change-major-mode-hook' teardown), a mode hook re-fire on a buffer
that grew past the cap must refuse cleanly."
  (minuet-duet-history-test--with-buffer
    (insert "small")
    (minuet-duet-history-mode 1)
    (should minuet-duet-history--timer)
    (kill-all-local-variables)
    (goto-char (point-max))
    (insert "\nmore than ten characters\n")
    (let ((minuet-duet-history-max-buffer-size 10))
      (minuet-duet-history-mode 1))
    (should-not minuet-duet-history-mode)
    (should-not minuet-duet-history--timer)
    (should-not (minuet-duet-history-test--timers-for (current-buffer)))))

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
    (let ((timer minuet-duet-history--timer))
      (minuet-duet-history-mode 1)
      (should (= (length minuet-duet-history--entries) 1))
      ;; The live timer chain is kept; no second chain is scheduled.
      (should (eq minuet-duet-history--timer timer))
      (should (= (length (minuet-duet-history-test--timers-for
                          (current-buffer)))
                 1)))))

(ert-deftest minuet-duet-history-reenable-after-local-wipe-reinitializes ()
  "Re-enabling after `kill-all-local-variables' restores tracking.
Simulates `normal-mode' on revert: the `change-major-mode-hook'
teardown disables tracking cleanly before the wipe, then a mode hook
re-fires and re-initializes from scratch."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (minuet-duet-history-mode 1)
    (let ((old-timer minuet-duet-history--timer))
      (kill-all-local-variables)
      (should-not minuet-duet-history--snapshot-file)
      (should-not (memq old-timer timer-idle-list)))
    (minuet-duet-history-mode 1)
    (should minuet-duet-history--snapshot-file)
    (should (file-exists-p minuet-duet-history--snapshot-file))
    (should (memq #'minuet-duet-history--on-kill-buffer kill-buffer-hook))
    (goto-char (point-max))
    (insert "c\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+c" (car minuet-duet-history--entries)))
    ;; Re-enabling does not leave a second timer chain behind.
    (should (= (length (minuet-duet-history-test--timers-for
                        (current-buffer)))
               1))))

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
    ;; The stale timer chain was replaced, not duplicated.
    (should (= (length (minuet-duet-history-test--timers-for
                        (current-buffer)))
               1))
    (goto-char (point-max))
    (insert "c\n")
    (minuet-duet-history-test--flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+c" (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-flush-rebaselines-after-directory-deletion ()
  "A tracked buffer recovers when its snapshot directory disappears.
The unavailable burst is absorbed into a fresh baseline, existing
history is retained, and later edits are recorded normally."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "recorded-before-deletion\n")
    (minuet-duet-history-test--flush)
    (let ((entries (copy-sequence minuet-duet-history--entries))
          (old-directory minuet-duet-history--directory)
          (old-snapshot minuet-duet-history--snapshot-file)
          (old-pending minuet-duet-history--pending-file)
          (timer minuet-duet-history--timer))
      (delete-directory old-directory t)
      (goto-char (point-max))
      (insert "unavailable-baseline\n")
      (minuet-duet-history-test--flush)
      (should (file-directory-p minuet-duet-history--directory))
      (should-not (equal minuet-duet-history--directory old-directory))
      (should-not (equal minuet-duet-history--snapshot-file old-snapshot))
      (should-not (equal minuet-duet-history--pending-file old-pending))
      (should (file-exists-p minuet-duet-history--snapshot-file))
      (should (file-exists-p minuet-duet-history--pending-file))
      (should
       (equal (file-name-directory minuet-duet-history--snapshot-file)
              (file-name-as-directory minuet-duet-history--directory)))
      (should
       (equal (file-name-directory minuet-duet-history--pending-file)
              (file-name-as-directory minuet-duet-history--directory)))
      (should (equal minuet-duet-history--entries entries))
      (should (eql minuet-duet-history--snapshot-tick
                   (buffer-chars-modified-tick)))
      (should (eq minuet-duet-history--timer timer))
      (goto-char (point-max))
      (insert "recorded-after-recovery\n")
      (minuet-duet-history-test--flush)
      (should (= (length minuet-duet-history--entries) 2))
      (should (string-match-p "\\+recorded-after-recovery"
                              (car minuet-duet-history--entries))))))

(ert-deftest minuet-duet-history-flush-repairs-each-stale-buffer ()
  "Every live buffer replaces stale paths after the directory is recreated."
  (let ((minuet-duet-history--directory nil)
        (buffer-1 (generate-new-buffer "minuet-duet-history-recovery-1"))
        (buffer-2 (generate-new-buffer "minuet-duet-history-recovery-2")))
    (unwind-protect
        (progn
          (dolist (buffer (list buffer-1 buffer-2))
            (with-current-buffer buffer
              (insert "a\n")
              (minuet-duet-history-mode 1)))
          (let ((old-directory minuet-duet-history--directory))
            (delete-directory old-directory t)
            ;; The first buffer creates the replacement session directory.
            (with-current-buffer buffer-1
              (goto-char (point-max))
              (insert "absorbed-1\n")
              (minuet-duet-history-test--flush))
            (let ((new-directory minuet-duet-history--directory))
              (should (file-directory-p new-directory))
              (should-not (equal new-directory old-directory))
              ;; The second buffer still has paths in the old directory,
              ;; so it must independently re-baseline into the replacement.
              (with-current-buffer buffer-2
                (should (equal
                         (file-name-directory
                          minuet-duet-history--snapshot-file)
                         (file-name-as-directory old-directory)))
                (goto-char (point-max))
                (insert "absorbed-2\n")
                (minuet-duet-history-test--flush)
                (should
                 (equal (file-name-directory
                         minuet-duet-history--snapshot-file)
                        (file-name-as-directory new-directory)))
                (should (eql minuet-duet-history--snapshot-tick
                             (buffer-chars-modified-tick)))
                (goto-char (point-max))
                (insert "recorded-after-recovery\n")
                (minuet-duet-history-test--flush)
                (should (= (length minuet-duet-history--entries) 1))
                (should (string-match-p "\\+recorded-after-recovery"
                                        (car minuet-duet-history--entries))))
              (should
               (= (length (minuet-duet-history-test--directory-files)) 4)))))
      (dolist (buffer (list buffer-1 buffer-2))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when minuet-duet-history-mode
              (minuet-duet-history-mode -1)))
          (kill-buffer buffer)))
      (minuet-duet-history--delete-directory))))

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
        (minuet-duet-history--on-timer (current-buffer))
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
        (should-not minuet-duet-history--timer)
        (should-not (minuet-duet-history-test--timers-for
                     (current-buffer)))))))

;;;;;
;; Snapshot file lifecycle
;;;;;

(ert-deftest minuet-duet-history-disable-deletes-files ()
  "Disabling the mode deletes both snapshot files."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (let ((snapshot minuet-duet-history--snapshot-file)
          (pending minuet-duet-history--pending-file))
      (should (file-exists-p snapshot))
      (should (file-exists-p pending))
      ;; Both files live inside the snapshot directory.
      (should (equal (file-name-directory snapshot)
                     (file-name-as-directory minuet-duet-history--directory)))
      (should (= (length (minuet-duet-history-test--directory-files)) 2))
      (minuet-duet-history-mode -1)
      (should-not (file-exists-p snapshot))
      (should-not (file-exists-p pending))
      (should-not (minuet-duet-history-test--directory-files))
      (should-not minuet-duet-history--snapshot-file)
      (should-not minuet-duet-history--pending-file))))

(ert-deftest minuet-duet-history-kill-buffer-deletes-files ()
  "Killing a tracked buffer cancels its diff and timer and deletes its files."
  (let ((minuet-duet-history--directory nil)
        (buffer (generate-new-buffer "minuet-duet-history-kill-test"))
        timer snapshot pending)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "a\n")
            (minuet-duet-history-mode 1)
            (setq timer minuet-duet-history--timer
                  snapshot minuet-duet-history--snapshot-file
                  pending minuet-duet-history--pending-file))
          (should (memq timer timer-idle-list))
          (kill-buffer buffer)
          (should-not (file-exists-p snapshot))
          (should-not (file-exists-p pending))
          (should-not (memq timer timer-idle-list)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (minuet-duet-history--delete-directory))))

(ert-deftest minuet-duet-history-local-wipe-tears-down-tracking ()
  "A local-variable wipe tears tracking down before its state is lost.
`kill-all-local-variables' (manual revert, major-mode change) runs
`change-major-mode-hook' before wiping, so the mode disables itself
while the file and process variables are still intact: the snapshot
files are deleted on the spot and the buffer deregisters, leaving
nothing behind.  Re-enabling afterwards re-initializes from scratch."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (let ((old-snapshot minuet-duet-history--snapshot-file)
          (old-pending minuet-duet-history--pending-file)
          (old-timer minuet-duet-history--timer))
      (kill-all-local-variables)
      (should-not (file-exists-p old-snapshot))
      (should-not (file-exists-p old-pending))
      (should-not (minuet-duet-history-test--directory-files))
      (should-not (memq old-timer timer-idle-list))
      ;; Re-enabling (as the new major mode's hooks would) starts fresh.
      (minuet-duet-history-mode 1)
      (should (file-exists-p minuet-duet-history--snapshot-file))
      (should (= (length (minuet-duet-history-test--directory-files)) 2)))))

(ert-deftest minuet-duet-history-delete-directory-sweeps-files ()
  "`minuet-duet-history--delete-directory' removes the directory and files.
This is the `kill-emacs' backstop that also collects files stranded
by buffers killed with their hooks inhibited."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (should (file-directory-p minuet-duet-history--directory))
    (should (memq #'minuet-duet-history--delete-directory kill-emacs-hook))
    (let ((directory minuet-duet-history--directory)
          (snapshot minuet-duet-history--snapshot-file)
          (pending minuet-duet-history--pending-file))
      (minuet-duet-history--delete-directory)
      (should-not (file-exists-p snapshot))
      (should-not (file-exists-p pending))
      (should-not (file-exists-p directory))
      (should-not minuet-duet-history--directory))))

;;;;;
;; Timer & buffer lifecycle
;;;;;

(ert-deftest minuet-duet-history-timer-lifecycle ()
  "Each tracked buffer owns its own scheduled idle timer."
  (let ((minuet-duet-history--directory nil)
        (buf1 (generate-new-buffer "minuet-duet-history-test-1"))
        (buf2 (generate-new-buffer "minuet-duet-history-test-2")))
    (unwind-protect
        (progn
          (with-current-buffer buf1 (minuet-duet-history-mode 1))
          (with-current-buffer buf2 (minuet-duet-history-mode 1))
          (let ((timer1 (buffer-local-value 'minuet-duet-history--timer buf1))
                (timer2 (buffer-local-value 'minuet-duet-history--timer buf2)))
            (should (memq timer1 timer-idle-list))
            (should (memq timer2 timer-idle-list))
            (should-not (eq timer1 timer2))
            ;; Disabling one buffer cancels only its own timer.
            (with-current-buffer buf1 (minuet-duet-history-mode -1))
            (should-not (memq timer1 timer-idle-list))
            (should-not (buffer-local-value 'minuet-duet-history--timer buf1))
            (should (memq timer2 timer-idle-list))
            (kill-buffer buf2)
            (should-not (memq timer2 timer-idle-list))))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2))
      (minuet-duet-history--delete-directory))))

(ert-deftest minuet-duet-history-on-timer-reschedules ()
  "A timer run flushes pending edits and schedules the buffer's next timer."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (let ((fired minuet-duet-history--timer))
      (goto-char (point-max))
      (insert "b\n")
      ;; Simulate the scheduled timer firing: `timer-event-handler'
      ;; pulls a one-shot timer off the idle list before running it.
      (cancel-timer fired)
      (minuet-duet-history--on-timer (current-buffer))
      (should minuet-duet-history--timer)
      (should-not (eq minuet-duet-history--timer fired))
      (should (memq minuet-duet-history--timer timer-idle-list))
      (should (= (length (minuet-duet-history-test--timers-for
                          (current-buffer)))
                 1))
      (minuet-test--wait-until
       (lambda () (= (length minuet-duet-history--entries) 1))
       5 "the timer flush never recorded the pending edit"))))

(ert-deftest minuet-duet-history-clone-registers-for-idle-flush ()
  "A clone inheriting enabled history mode participates in idle flushes.
The clone gets its own snapshot files and timer chain instead of
aliasing the base buffer's, and disabling it leaves the base buffer's
alone."
  (let ((minuet-duet-history--directory nil)
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
          (should (equal (buffer-local-value
                          'minuet-duet-history--entries clone)
                         (buffer-local-value
                          'minuet-duet-history--entries base)))
          ;; The clone allocated its own snapshot files and timer.
          (should-not (equal (buffer-local-value
                              'minuet-duet-history--snapshot-file clone)
                             (buffer-local-value
                              'minuet-duet-history--snapshot-file base)))
          (should-not (eq (buffer-local-value
                           'minuet-duet-history--timer clone)
                          (buffer-local-value
                           'minuet-duet-history--timer base)))
          (should (memq (buffer-local-value 'minuet-duet-history--timer clone)
                        timer-idle-list))
          (with-current-buffer clone
            (goto-char (point-max))
            (insert "b\n"))
          (minuet-duet-history--on-timer clone)
          (minuet-test--wait-until
           (lambda () (= (length (buffer-local-value
                                  'minuet-duet-history--entries clone))
                         2))
           5 "clone never recorded the idle flush")
          ;; Disabling the base buffer leaves the clone's timer chain
          ;; and files untouched.
          (let ((base-snapshot (buffer-local-value
                                'minuet-duet-history--snapshot-file base)))
            (with-current-buffer base
              (minuet-duet-history-mode -1))
            (should-not (file-exists-p base-snapshot)))
          (should (memq (buffer-local-value 'minuet-duet-history--timer clone)
                        timer-idle-list))
          (should (file-exists-p (buffer-local-value
                                  'minuet-duet-history--snapshot-file clone))))
      (when (buffer-live-p clone) (kill-buffer clone))
      (when (buffer-live-p base) (kill-buffer base))
      (minuet-duet-history--delete-directory))))

(ert-deftest minuet-duet-history-on-timer-dead-buffer-ends-chain ()
  "The timer run of a buffer that died without hooks ends its chain.
Simulates a tracked buffer killed with its kill hook missing (e.g.
`inhibit-buffer-hooks'): the next timer run finds the buffer dead,
schedules no successor, and leaves the stranded snapshot files for
the directory sweep at `kill-emacs' (the documented trade-off for
this rare case)."
  (let ((minuet-duet-history--directory nil)
        (buffer (generate-new-buffer "minuet-duet-history-dead-buffer"))
        timer snapshot)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "a\n")
            (minuet-duet-history-mode 1)
            (setq timer minuet-duet-history--timer
                  snapshot minuet-duet-history--snapshot-file)
            ;; Simulate a buffer that dies without running its hooks.
            (remove-hook 'kill-buffer-hook
                         #'minuet-duet-history--on-kill-buffer t))
          (kill-buffer buffer)
          ;; Nothing cancelled the timer, so it is still scheduled and
          ;; will fire once more.  Simulate that firing.
          (should (memq timer timer-idle-list))
          (cancel-timer timer)
          (minuet-duet-history--on-timer buffer)
          ;; No successor was scheduled: the chain has ended.
          (should-not (minuet-duet-history-test--timers-for buffer))
          ;; The stranded files await the directory sweep.
          (should (file-exists-p snapshot))
          (minuet-duet-history--delete-directory)
          (should-not (file-exists-p snapshot)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (minuet-duet-history--delete-directory))))

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

(ert-deftest minuet-duet-history-prompt-text-while-narrowed ()
  "Narrowing the buffer does not change the rendered history.
The same text is returned as when the buffer is widened, and the
narrowing itself is left in place."
  (minuet-duet-history-test--with-buffer
    (dotimes (i 6) (insert (format "line-%d\n" i)))
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "x\n")
    (minuet-duet-history-test--flush)
    (let ((widened-text (minuet-duet-history-prompt-text)))
      (should widened-text)
      (narrow-to-region (point-min) 10)
      (should (equal (minuet-duet-history-prompt-text) widened-text))
      (should (buffer-narrowed-p)))))

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
