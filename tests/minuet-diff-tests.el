;;; minuet-diff-tests.el --- Tests for minuet-diff -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for `minuet-diff-line-hunks'.

;;; Code:

(require 'ert)
(load (expand-file-name "test-helper"
                        (file-name-directory
                         (or load-file-name (buffer-file-name))))
      nil t)

(require 'minuet-diff)

(defmacro minuet-diff-test--should-equal-hunks (original proposed expected)
  "Assert that ORIGINAL and PROPOSED produce EXPECTED hunks."
  `(should (equal (minuet-diff-line-hunks ,original ,proposed)
                  ,expected)))

(ert-deftest minuet-diff-no-op ()
  "Identical inputs produce no hunks."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c")
   '("a" "b" "c")
   nil))

(ert-deftest minuet-diff-empty-inputs ()
  "Two empty lists produce no hunks."
  (minuet-diff-test--should-equal-hunks nil nil nil))

(ert-deftest minuet-diff-pure-insertion-into-empty-input ()
  "Inserting lines into an empty original creates one insertion hunk."
  (minuet-diff-test--should-equal-hunks
   nil
   '("x" "y")
   '((:original-start 0 :original-count 0
      :proposed-start 0 :proposed-count 2))))

(ert-deftest minuet-diff-pure-insertion-at-beginning ()
  "Insertions before the first original line retain the correct anchor."
  (minuet-diff-test--should-equal-hunks
   '("a" "b")
   '("x" "a" "b")
   '((:original-start 0 :original-count 0
      :proposed-start 0 :proposed-count 1))))

(ert-deftest minuet-diff-pure-insertion-in-middle ()
  "Insertions between original lines preserve the insertion position."
  (minuet-diff-test--should-equal-hunks
   '("a" "b")
   '("a" "x" "b")
   '((:original-start 1 :original-count 0
      :proposed-start 1 :proposed-count 1))))

(ert-deftest minuet-diff-pure-insertion-at-end ()
  "Trailing insertions use the position after the last original line."
  (minuet-diff-test--should-equal-hunks
   '("a" "b")
   '("a" "b" "x")
   '((:original-start 2 :original-count 0
      :proposed-start 2 :proposed-count 1))))

(ert-deftest minuet-diff-pure-deletion ()
  "Deleting all lines produces one deletion hunk."
  (minuet-diff-test--should-equal-hunks
   '("a" "b")
   nil
   '((:original-start 0 :original-count 2
      :proposed-start 0 :proposed-count 0))))

(ert-deftest minuet-diff-replacement ()
  "Single-line replacement is represented as one replacement hunk."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c")
   '("a" "X" "c")
   '((:original-start 1 :original-count 1
      :proposed-start 1 :proposed-count 1))))

(ert-deftest minuet-diff-replacement-with-extra-inserted-lines ()
  "Adjacent delete+insert operations are merged into one replacement."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c")
   '("a" "x" "y" "c")
   '((:original-start 1 :original-count 1
      :proposed-start 1 :proposed-count 2))))

(ert-deftest minuet-diff-repeated-lines ()
  "Repeated lines still produce stable hunks."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "a" "c")
   '("a" "a" "c")
   '((:original-start 1 :original-count 1
      :proposed-start 1 :proposed-count 0))))

(ert-deftest minuet-diff-multiple-separated-hunks ()
  "Separated changes remain separated by unchanged context."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c" "d")
   '("a" "x" "c" "y")
   '((:original-start 1 :original-count 1
      :proposed-start 1 :proposed-count 1)
     (:original-start 3 :original-count 1
      :proposed-start 3 :proposed-count 1))))

(ert-deftest minuet-diff-mixed-delete-and-replace ()
  "Deletion and replacement hunks keep their exact coordinates."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c" "d" "e")
   '("a" "c" "X" "e")
   '((:original-start 1 :original-count 1
      :proposed-start 1 :proposed-count 0)
     (:original-start 3 :original-count 1
      :proposed-start 2 :proposed-count 1))))

(ert-deftest minuet-diff-mixed-edits-with-leading-and-trailing-insertions ()
  "Complex edits retain stable anchors around repeated context lines."
  (minuet-diff-test--should-equal-hunks
   '("header" "keep" "alpha" "beta" "keep" "footer")
   '("intro" "header" "keep" "beta" "gamma" "keep" "footer" "outro")
   '((:original-start 0 :original-count 0
      :proposed-start 0 :proposed-count 1)
     (:original-start 2 :original-count 1
      :proposed-start 3 :proposed-count 0)
     (:original-start 4 :original-count 0
      :proposed-start 4 :proposed-count 1)
     (:original-start 6 :original-count 0
      :proposed-start 7 :proposed-count 1))))

(ert-deftest minuet-diff-interleaved-edits-around-preserved-lines ()
  "Interleaved inserts and deletes stay separated by retained anchors."
  (minuet-diff-test--should-equal-hunks
   '("a" "x" "b" "y" "c" "z" "d")
   '("a" "b" "x" "c" "z" "e" "d")
   '((:original-start 1 :original-count 0
      :proposed-start 1 :proposed-count 1)
     (:original-start 2 :original-count 2
      :proposed-start 3 :proposed-count 0)
     (:original-start 6 :original-count 0
      :proposed-start 5 :proposed-count 1))))

(ert-deftest minuet-diff-repeated-lines-keep-consistent-alignment ()
  "Repeated anchors produce consistent separated replacements."
  (minuet-diff-test--should-equal-hunks
   '("start" "dup" "mid1" "dup" "mid2" "end")
   '("start" "dup" "mid2" "dup" "mid3" "end")
   '((:original-start 2 :original-count 1
      :proposed-start 2 :proposed-count 1)
     (:original-start 4 :original-count 1
      :proposed-start 4 :proposed-count 1))))

(ert-deftest minuet-diff-large-real-world-data ()
  "Diffing 50 lines of 80 characters each produces correct hunks."
  (let* ((line-length 80)
         (num-lines 50)
         ;; Generate original: 50 lines of ~80 chars each
         (original (cl-loop for i from 1 to num-lines
                            collect (format "Line %02d: %s" i
                                            (make-string (- line-length 8) ?x))))
         ;; Proposed: modified version with replacements and a deletion.
         (proposed (cl-loop for i from 1 to num-lines
                            collect
                            (cond
                             ;; Lines 10-12: replace with 3 new lines.
                             ((= i 10) "INSERTED LINE 10a: extra content here for the test scenario")
                             ((= i 11) "INSERTED LINE 10b: more content filling up the line length now")
                             ((= i 12) "INSERTED LINE 10c: final insertion in this hunk area here")
                             ;; Line 25: deleted (skip in proposed)
                             ((= i 25) nil)
                             ;; Line 40: single line replacement
                             ((= i 40) "REPLACED LINE 40: this line was replaced with new content")
                             ;; Keep other lines unchanged
                             (t (format "Line %02d: %s" i
                                        (make-string (- line-length 8) ?x)))))))
    ;; Filter out nil values (deleted line)
    (setq proposed (cl-remove-if #'null proposed))
    ;; Expected hunks:
    ;; 1. Lines 10-12 (1-based): replace 3 lines with 3 (at position 9 in both)
    ;; 2. Line 25: delete 1 line (at position 24 in both sequences)
    ;; 3. Line 40: replace 1 line (at position 39 in original, 38 in proposed)
    (minuet-diff-test--should-equal-hunks
     original
     proposed
     '((:original-start 9 :original-count 3
        :proposed-start 9 :proposed-count 3)
       (:original-start 24 :original-count 1
        :proposed-start 24 :proposed-count 0)
       (:original-start 39 :original-count 1
        :proposed-start 38 :proposed-count 1)))))

(provide 'minuet-diff-tests)
;;; minuet-diff-tests.el ends here
