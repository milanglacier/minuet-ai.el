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
   '((:original-start 1 :original-count 0
      :proposed-start 1 :proposed-count 2))))

(ert-deftest minuet-diff-pure-insertion-at-beginning ()
  "Insertions before the first original line retain the correct anchor."
  (minuet-diff-test--should-equal-hunks
   '("a" "b")
   '("x" "a" "b")
   '((:original-start 1 :original-count 0
      :proposed-start 1 :proposed-count 1))))

(ert-deftest minuet-diff-pure-insertion-in-middle ()
  "Insertions between original lines preserve the insertion position."
  (minuet-diff-test--should-equal-hunks
   '("a" "b")
   '("a" "x" "b")
   '((:original-start 2 :original-count 0
      :proposed-start 2 :proposed-count 1))))

(ert-deftest minuet-diff-pure-insertion-at-end ()
  "Trailing insertions use the position after the last original line."
  (minuet-diff-test--should-equal-hunks
   '("a" "b")
   '("a" "b" "x")
   '((:original-start 3 :original-count 0
      :proposed-start 3 :proposed-count 1))))

(ert-deftest minuet-diff-pure-deletion ()
  "Deleting all lines produces one deletion hunk."
  (minuet-diff-test--should-equal-hunks
   '("a" "b")
   nil
   '((:original-start 1 :original-count 2
      :proposed-start 1 :proposed-count 0))))

(ert-deftest minuet-diff-replacement ()
  "Single-line replacement is represented as one replacement hunk."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c")
   '("a" "X" "c")
   '((:original-start 2 :original-count 1
      :proposed-start 2 :proposed-count 1))))

(ert-deftest minuet-diff-replacement-with-extra-inserted-lines ()
  "Adjacent delete+insert operations are merged into one replacement."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c")
   '("a" "x" "y" "c")
   '((:original-start 2 :original-count 1
      :proposed-start 2 :proposed-count 2))))

(ert-deftest minuet-diff-repeated-lines ()
  "Repeated lines still produce stable hunks."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "a" "c")
   '("a" "a" "c")
   '((:original-start 2 :original-count 1
      :proposed-start 2 :proposed-count 0))))

(ert-deftest minuet-diff-multiple-separated-hunks ()
  "Separated changes remain separated by unchanged context."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c" "d")
   '("a" "x" "c" "y")
   '((:original-start 2 :original-count 1
      :proposed-start 2 :proposed-count 1)
     (:original-start 4 :original-count 1
      :proposed-start 4 :proposed-count 1))))

(ert-deftest minuet-diff-mixed-delete-and-replace ()
  "Deletion and replacement hunks keep their exact coordinates."
  (minuet-diff-test--should-equal-hunks
   '("a" "b" "c" "d" "e")
   '("a" "c" "X" "e")
   '((:original-start 2 :original-count 1
      :proposed-start 2 :proposed-count 0)
     (:original-start 4 :original-count 1
      :proposed-start 3 :proposed-count 1))))

(provide 'minuet-diff-tests)
;;; minuet-diff-tests.el ends here
