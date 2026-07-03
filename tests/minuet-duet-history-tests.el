;;; minuet-duet-history-tests.el --- Tests for minuet-duet-history -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for `minuet-duet-history-mode' and its helpers.

;;; Code:

(require 'ert)
(load (expand-file-name "test-helper"
                        (file-name-directory
                         (or load-file-name (buffer-file-name))))
      nil t)

(require 'minuet-duet-history)
(require 'minuet-duet)

(defmacro minuet-duet-history-test--with-buffer (&rest body)
  "Run BODY in a temp buffer with isolated global tracking state.
Temp buffers are created with `inhibit-buffer-hooks', so
`kill-buffer-hook' never deregisters them; let-binding the globals
keeps tests independent, and any timer created inside is cancelled."
  (declare (indent 0))
  `(let ((minuet-duet-history--buffers nil)
         (minuet-duet-history--timer nil))
     (unwind-protect
         (with-temp-buffer ,@body)
       (when minuet-duet-history--timer
         (cancel-timer minuet-duet-history--timer)))))

;;;;;
;; Common affixes
;;;;;

(ert-deftest minuet-duet-history-affixes-identical ()
  "Identical vectors are all prefix."
  (should (equal (minuet-duet-history--common-affixes ["a" "b"] ["a" "b"])
                 '(2 . 0))))

(ert-deftest minuet-duet-history-affixes-disjoint ()
  "Fully different vectors share no affixes."
  (should (equal (minuet-duet-history--common-affixes ["a"] ["b"])
                 '(0 . 0))))

(ert-deftest minuet-duet-history-affixes-prefix-only ()
  "Only leading lines are shared."
  (should (equal (minuet-duet-history--common-affixes ["a" "b"] ["a" "c"])
                 '(1 . 0))))

(ert-deftest minuet-duet-history-affixes-suffix-only ()
  "Only trailing lines are shared."
  (should (equal (minuet-duet-history--common-affixes ["x" "b"] ["y" "b"])
                 '(0 . 1))))

(ert-deftest minuet-duet-history-affixes-overlap-clamp ()
  "Suffix is clamped so prefix and suffix regions never overlap."
  (should (equal (minuet-duet-history--common-affixes
                  ["a" "a"] ["a" "a" "a"])
                 '(2 . 0))))

;;;;;
;; Unified diff formatting
;;;;;

(defun minuet-duet-history-test--udiff (old new n-context)
  "Diff OLD and NEW vectors of lines and format with N-CONTEXT."
  (let* ((affixes (minuet-duet-history--common-affixes old new))
         (prefix (car affixes))
         (suffix (cdr affixes))
         (hunks (minuet-diff-line-hunks
                 (cl-subseq old prefix (- (length old) suffix))
                 (cl-subseq new prefix (- (length new) suffix)))))
    (minuet-duet-history--format-udiff old new prefix hunks n-context)))

(ert-deftest minuet-duet-history-udiff-replacement-no-context ()
  "A single replaced line with zero context."
  (should (equal (minuet-duet-history-test--udiff
                  ["a" "b" "c"] ["a" "x" "c"] 0)
                 "@@ -2,1 +2,1 @@\n-b\n+x")))

(ert-deftest minuet-duet-history-udiff-replacement-with-context ()
  "A single replaced line with two context lines on each side."
  (should (equal (minuet-duet-history-test--udiff
                  ["a" "b" "c" "d" "e"] ["a" "b" "X" "d" "e"] 2)
                 "@@ -1,5 +1,5 @@\n a\n b\n-c\n+X\n d\n e")))

(ert-deftest minuet-duet-history-udiff-pure-insertion ()
  "A pure insertion uses the 0-based anchor on the empty side."
  (should (equal (minuet-duet-history-test--udiff
                  ["a" "b"] ["a" "x" "b"] 0)
                 "@@ -1,0 +2,1 @@\n+x")))

(ert-deftest minuet-duet-history-udiff-pure-deletion ()
  "A pure deletion uses the 0-based anchor on the empty side."
  (should (equal (minuet-duet-history-test--udiff
                  ["a" "b" "c"] ["a" "c"] 0)
                 "@@ -2,1 +1,0 @@\n-b")))

(ert-deftest minuet-duet-history-udiff-two-groups ()
  "Far-apart hunks produce separate @@ groups."
  (should (equal (minuet-duet-history-test--udiff
                  ["a" "b" "c" "d" "e" "f" "g"]
                  ["a" "B" "c" "d" "e" "F" "g"]
                  1)
                 (concat "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
                         "@@ -5,3 +5,3 @@\n e\n-f\n+F\n g"))))

(ert-deftest minuet-duet-history-udiff-merged-group ()
  "Hunks whose context ranges touch are merged into one @@ group."
  (should (equal (minuet-duet-history-test--udiff
                  ["a" "b" "c" "d" "e"]
                  ["A" "b" "c" "d" "E"]
                  2)
                 "@@ -1,5 +1,5 @@\n-a\n+A\n b\n c\n d\n-e\n+E")))

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
  "Each flush of a dirty buffer records one coalesced entry, newest first."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\nc\n")
    (minuet-duet-history-mode 1)
    (should minuet-duet-history-mode)
    (should-not minuet-duet-history--dirty)
    (goto-char (point-min))
    (forward-line 1)
    (insert "new line\n")
    (should minuet-duet-history--dirty)
    (minuet-duet-history--flush-buffer)
    (should (equal minuet-duet-history--entries
                   '("@@ -1,3 +1,4 @@\n a\n+new line\n b\n c")))
    (should-not minuet-duet-history--dirty)
    ;; A second burst becomes a second entry, newest first.
    (goto-char (point-max))
    (insert "d\n")
    (minuet-duet-history--flush-buffer)
    (should (= (length minuet-duet-history--entries) 2))
    (should (string-match-p "\\+d" (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-flush-ignores-reverted-edit ()
  "An edit undone back to the snapshot updates the tick but adds no entry."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\nc\n")
    (minuet-duet-history-mode 1)
    (let ((old-tick minuet-duet-history--snapshot-tick))
      (goto-char (point-min))
      (insert "x")
      (delete-char -1)
      (should minuet-duet-history--dirty)
      (minuet-duet-history--flush-buffer)
      (should-not minuet-duet-history--entries)
      (should-not (eql minuet-duet-history--snapshot-tick old-tick))
      (should (eql minuet-duet-history--snapshot-tick
                   (buffer-chars-modified-tick))))))

(ert-deftest minuet-duet-history-flush-skips-clean-buffer ()
  "Flushing without pending changes does nothing."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (minuet-duet-history--flush-buffer)
    (should-not minuet-duet-history--entries)))

(ert-deftest minuet-duet-history-flush-skips-oversized-region ()
  "Edits larger than the region cap are skipped but re-snapshot."
  (minuet-duet-history-test--with-buffer
    (insert "a\nb\n")
    (minuet-duet-history-mode 1)
    (let ((minuet-duet-history-max-region-lines 2))
      (goto-char (point-max))
      (insert "1\n2\n3\n4\n5\n")
      (minuet-duet-history--flush-buffer)
      (should-not minuet-duet-history--entries)
      ;; Snapshot was updated: a subsequent small edit diffs against the
      ;; post-paste content.
      (goto-char (point-min))
      (insert "z\n")
      (minuet-duet-history--flush-buffer)
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
      (minuet-duet-history--flush-buffer)
      (should-not minuet-duet-history-mode))))

(ert-deftest minuet-duet-history-mode-refuses-oversized-buffer ()
  "The mode refuses to enable in a buffer over the size cap."
  (minuet-duet-history-test--with-buffer
    (insert "more than ten characters")
    (let ((minuet-duet-history-max-buffer-size 10))
      (minuet-duet-history-mode 1)
      (should-not minuet-duet-history-mode)
      (should-not (memq (current-buffer) minuet-duet-history--buffers)))))

;;;;;
;; Timer & buffer lifecycle
;;;;;

(ert-deftest minuet-duet-history-timer-lifecycle ()
  "One shared idle timer exists while any buffer is tracked."
  (let ((buf1 (generate-new-buffer "minuet-duet-history-test-1"))
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
      (when (buffer-live-p buf2) (kill-buffer buf2)))))

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

(provide 'minuet-duet-history-tests)
;;; minuet-duet-history-tests.el ends here
