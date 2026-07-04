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
  "Diff OLD and NEW vectors of lines and format with N-CONTEXT.
Delegates to the production pipeline so these tests exercise the same
code path `minuet-duet-history--flush-buffer' uses."
  (minuet-duet-history--diff-entry old new n-context))

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

(ert-deftest minuet-duet-history-udiff-mid-file-offset ()
  "Headers use absolute 1-based line numbers for edits deep in the file."
  (should (equal (minuet-duet-history-test--udiff
                  ["l1" "l2" "l3" "l4" "l5" "l6" "l7" "l8" "l9" "l10"]
                  ["l1" "l2" "l3" "l4" "l5" "l6" "l7" "X" "l9" "l10"]
                  2)
                 "@@ -6,5 +6,5 @@\n l6\n l7\n-l8\n+X\n l9\n l10")))

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
    (minuet-duet-history--flush-buffer)
    (should (equal minuet-duet-history--entries
                   '("@@ -1,3 +1,4 @@\n a\n+new line\n b\n c")))
    (should (eql minuet-duet-history--snapshot-tick
                 (buffer-chars-modified-tick)))
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
      (should-not (eql minuet-duet-history--snapshot-tick
                       (buffer-chars-modified-tick)))
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
    (minuet-duet-history--flush-buffer)
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
    (minuet-duet-history--flush-buffer)
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
    (minuet-duet-history--flush-buffer)
    (should (= (length minuet-duet-history--entries) 1))
    (let ((entry (car minuet-duet-history--entries)))
      (should (= (minuet-duet--count-occurrences entry "@@ -") 2))
      (should (string-match-p "^\\+top$" entry))
      (should (string-match-p "^\\+bottom$" entry)))))

(ert-deftest minuet-duet-history-reenable-keeps-history ()
  "Enabling the mode in an already-tracked buffer keeps its history."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (minuet-duet-history--flush-buffer)
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
    (should-not minuet-duet-history--snapshot-lines)
    (should (memq (current-buffer) minuet-duet-history--buffers))
    (minuet-duet-history-mode 1)
    (should minuet-duet-history--snapshot-lines)
    (should (memq #'minuet-duet-history--on-kill-buffer kill-buffer-hook))
    (goto-char (point-max))
    (insert "c\n")
    (minuet-duet-history--flush-buffer)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+c" (car minuet-duet-history--entries)))
    ;; Re-registration does not duplicate the buffer in the list.
    (should (equal minuet-duet-history--buffers (list (current-buffer))))))

(ert-deftest minuet-duet-history-flush-api-never-signals ()
  "`minuet-duet-history-flush' logs flush errors instead of signaling."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (cl-letf (((symbol-function 'minuet-duet-history--flush-buffer)
               (lambda () (error "Boom"))))
      (minuet-duet-history-flush))
    ;; The pending edit survives the failed flush and is recorded by
    ;; the next successful one.
    (minuet-duet-history-flush)
    (should (= (length minuet-duet-history--entries) 1))
    (should (string-match-p "\\+b" (car minuet-duet-history--entries)))))

(ert-deftest minuet-duet-history-clear-discards-entries ()
  "Clearing discards recorded entries and re-snapshots pending edits."
  (minuet-duet-history-test--with-buffer
    (insert "a\n")
    (minuet-duet-history-mode 1)
    (goto-char (point-max))
    (insert "b\n")
    (minuet-duet-history--flush-buffer)
    (should minuet-duet-history--entries)
    ;; A pending, unflushed edit is absorbed by the new snapshot.
    (insert "c\n")
    (minuet-duet-history-clear)
    (should-not minuet-duet-history--entries)
    (minuet-duet-history--flush-buffer)
    (should-not minuet-duet-history--entries)))

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

(ert-deftest minuet-duet-history-flush-all-flushes-and-prunes ()
  "The timer flush records pending edits and prunes dead buffers."
  (let ((minuet-duet-history--buffers nil)
        (minuet-duet-history--timer nil)
        (buf1 (generate-new-buffer "minuet-duet-history-flush-all-1"))
        (buf2 (generate-new-buffer "minuet-duet-history-flush-all-2")))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (insert "a\n")
            (minuet-duet-history-mode 1)
            (goto-char (point-max))
            (insert "b\n"))
          (with-current-buffer buf2
            (minuet-duet-history-mode 1)
            ;; Simulate a buffer that died without running its hooks.
            (remove-hook 'kill-buffer-hook
                         #'minuet-duet-history--on-kill-buffer t))
          (kill-buffer buf2)
          (minuet-duet-history--flush-all)
          (should (equal minuet-duet-history--buffers (list buf1)))
          (should (= (length (buffer-local-value
                              'minuet-duet-history--entries buf1))
                     1)))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2))
      (when minuet-duet-history--timer
        (cancel-timer minuet-duet-history--timer)))))

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
    (minuet-duet-history--flush-buffer)
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
          (minuet-duet-provider 'openai-compatible))
      (cl-letf (((symbol-function 'minuet-duet--openai-compatible-complete)
                 (lambda (context callback)
                   (setq captured (minuet-duet--make-chat-input
                                   context minuet-duet-default-chat-input))
                   (funcall callback nil))))
        (minuet-duet-predict))
      (should captured)
      ;; The burst typed right before predicting was flushed synchronously
      ;; and rendered ahead of the document.
      (should (string-match-p "^\\+line-4$" captured))
      (should (< (string-match "<edit_history>" captured)
                 (string-match "line-1" captured))))))

(provide 'minuet-duet-history-tests)
;;; minuet-duet-history-tests.el ends here
