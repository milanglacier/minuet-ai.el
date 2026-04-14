;;; minuet-duet-tests.el --- Tests for minuet-duet and minuet-diff -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for minuet-diff-line-hunks, duet response parsing,
;; context extraction, and integration tests for apply/dismiss.

;;; Code:

(require 'ert)

(let ((project-dir (file-name-directory
                    (directory-file-name
                     (file-name-directory
                      (or load-file-name (buffer-file-name)))))))
  (add-to-list 'load-path project-dir))

(require 'minuet)
(require 'minuet-diff)

(require 'minuet-duet)

;; =====================================================================
;; minuet-diff-line-hunks tests
;; =====================================================================

(ert-deftest minuet-diff-no-op ()
  "Identical inputs produce no hunks."
  (should (null (minuet-diff-line-hunks '("a" "b" "c") '("a" "b" "c")))))

(ert-deftest minuet-diff-empty-inputs ()
  "Two empty lists produce no hunks."
  (should (null (minuet-diff-line-hunks nil nil))))

(ert-deftest minuet-diff-pure-insertion ()
  "Inserting lines into an empty original."
  (let ((hunks (minuet-diff-line-hunks nil '("x" "y"))))
    (should (= (length hunks) 1))
    (should (= (plist-get (car hunks) :original-count) 0))
    (should (= (plist-get (car hunks) :proposed-count) 2))))

(ert-deftest minuet-diff-pure-deletion ()
  "Deleting all lines."
  (let ((hunks (minuet-diff-line-hunks '("a" "b") nil)))
    (should (= (length hunks) 1))
    (should (= (plist-get (car hunks) :original-count) 2))
    (should (= (plist-get (car hunks) :proposed-count) 0))))

(ert-deftest minuet-diff-replacement ()
  "Single-line replacement."
  (let ((hunks (minuet-diff-line-hunks '("a" "b" "c") '("a" "X" "c"))))
    (should (= (length hunks) 1))
    (should (= (plist-get (car hunks) :original-start) 2))
    (should (= (plist-get (car hunks) :original-count) 1))
    (should (= (plist-get (car hunks) :proposed-start) 2))
    (should (= (plist-get (car hunks) :proposed-count) 1))))

(ert-deftest minuet-diff-mixed-multi-hunk ()
  "Multiple hunks: deletion + insertion."
  (let ((hunks (minuet-diff-line-hunks '("a" "b" "c" "d" "e")
                                       '("a" "c" "X" "e"))))
    ;; b deleted (hunk 1), X inserted after c (hunk 2), d deleted (implicit or merged)
    (should (>= (length hunks) 1))))

(ert-deftest minuet-diff-insertion-in-middle ()
  "Insert new lines in the middle."
  (let ((hunks (minuet-diff-line-hunks '("a" "b") '("a" "X" "b"))))
    (should (= (length hunks) 1))
    (should (= (plist-get (car hunks) :original-count) 0))
    (should (= (plist-get (car hunks) :proposed-count) 1))
    (should (= (plist-get (car hunks) :proposed-start) 2))))

;; =====================================================================
;; Duet response parsing tests
;; =====================================================================

(ert-deftest minuet-duet-parse-valid ()
  "Valid response with one cursor marker."
  (let ((text (concat "<editable_region_start>\n"
                      "hello <cursor_position>world\n"
                      "<editable_region_end>")))
    (let ((result (minuet-duet--parse-response text)))
      (should result)
      (should (equal (car result) '("hello world")))
      (should (= (plist-get (cdr result) :row-offset) 0))
      (should (= (plist-get (cdr result) :col) 6)))))

(ert-deftest minuet-duet-parse-multiline ()
  "Valid multi-line response."
  (let ((text (concat "<editable_region_start>\n"
                      "line1\n"
                      "line2<cursor_position>\n"
                      "line3\n"
                      "<editable_region_end>")))
    (let ((result (minuet-duet--parse-response text)))
      (should result)
      (should (equal (car result) '("line1" "line2" "line3")))
      (should (= (plist-get (cdr result) :row-offset) 1))
      (should (= (plist-get (cdr result) :col) 5)))))

(ert-deftest minuet-duet-parse-missing-start-marker ()
  "Missing start marker returns nil."
  (let ((text "hello <cursor_position>world\n<editable_region_end>"))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-missing-end-marker ()
  "Missing end marker returns nil."
  (let ((text "<editable_region_start>\nhello <cursor_position>world"))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-duplicate-start-marker ()
  "Duplicate start markers returns nil."
  (let ((text (concat "<editable_region_start>\n<editable_region_start>\n"
                      "hello <cursor_position>world\n"
                      "<editable_region_end>")))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-missing-cursor-marker ()
  "Missing cursor marker returns nil."
  (let ((text (concat "<editable_region_start>\n"
                      "hello world\n"
                      "<editable_region_end>")))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-duplicate-cursor-marker ()
  "Duplicate cursor markers returns nil."
  (let ((text (concat "<editable_region_start>\n"
                      "hello <cursor_position>wor<cursor_position>ld\n"
                      "<editable_region_end>")))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-newline-trimming ()
  "Leading and trailing newlines inside markers are trimmed."
  ;; Two leading newlines: first trimmed, second kept as empty first line
  (let ((text (concat "<editable_region_start>\n\n"
                      "<cursor_position>hello\n"
                      "<editable_region_end>")))
    (let ((result (minuet-duet--parse-response text)))
      (should result)
      ;; The inner text after removing first \n is "\n<cursor>hello"
      ;; Trailing \n is also trimmed, so inner = "\n<cursor>hello" -> "" and "hello"
      ;; Actually: inner after first trim = "\n<cursor_position>hello"
      ;; trailing trim: "\n<cursor_position>hello" (no trailing \n to trim)
      ;; So lines = ("" "hello"), cursor at line 1 col 0
      (should (equal (car result) '("" "hello"))))))

(ert-deftest minuet-duet-parse-empty-response ()
  "Empty string returns nil."
  (should (null (minuet-duet--parse-response "")))
  (should (null (minuet-duet--parse-response nil))))

;; =====================================================================
;; Context extraction tests
;; =====================================================================

(ert-deftest minuet-duet-context-empty-buffer ()
  "Context from an empty buffer."
  (with-temp-buffer
    (let ((ctx (minuet-duet--build-context)))
      (should (stringp (plist-get ctx :non-editable-region-before)))
      (should (stringp (plist-get ctx :editable-region-before-cursor)))
      (should (stringp (plist-get ctx :editable-region-after-cursor)))
      (should (stringp (plist-get ctx :non-editable-region-after)))
      (should (listp (plist-get ctx :original-lines))))))

(ert-deftest minuet-duet-context-point-at-beginning ()
  "Context when point is at beginning of buffer."
  (with-temp-buffer
    (insert "line1\nline2\nline3")
    (goto-char (point-min))
    (let ((ctx (minuet-duet--build-context)))
      (should (string-empty-p (plist-get ctx :editable-region-before-cursor)))
      (should (string-empty-p (plist-get ctx :non-editable-region-before))))))

(ert-deftest minuet-duet-context-point-at-end ()
  "Context when point is at end of buffer."
  (with-temp-buffer
    (insert "line1\nline2\nline3")
    (goto-char (point-max))
    (let ((ctx (minuet-duet--build-context)))
      (should (string-empty-p (plist-get ctx :editable-region-after-cursor)))
      (should (string-empty-p (plist-get ctx :non-editable-region-after))))))

(ert-deftest minuet-duet-context-clipped-by-buffer ()
  "Editable region clipped when fewer lines than requested."
  (with-temp-buffer
    (insert "a\nb\nc")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((minuet-duet-editable-region-lines-before 100)
           (minuet-duet-editable-region-lines-after 100)
           (ctx (minuet-duet--build-context)))
      ;; Should include all lines without error
      (should (= (length (plist-get ctx :original-lines)) 3))
      (should (string-empty-p (plist-get ctx :non-editable-region-before)))
      (should (string-empty-p (plist-get ctx :non-editable-region-after))))))

(ert-deftest minuet-duet-context-multiline-region ()
  "Context correctly splits around point in a multi-line buffer."
  (with-temp-buffer
    (insert "line1\nline2\nline3\nline4\nline5")
    (goto-char (point-min))
    (forward-line 2)  ; beginning of line3
    (forward-char 3)  ; mid-line3
    (let* ((minuet-duet-editable-region-lines-before 1)
           (minuet-duet-editable-region-lines-after 1)
           (ctx (minuet-duet--build-context)))
      ;; Editable region: lines 2-4
      (should (>= (length (plist-get ctx :original-lines)) 2))
      ;; Non-editable before should contain "line1"
      (should (string-match-p "line1" (plist-get ctx :non-editable-region-before))))))

;; =====================================================================
;; Integration tests: apply, dismiss, stale detection
;; =====================================================================

(ert-deftest minuet-duet-apply-replaces-region ()
  "Apply replaces only the editable region."
  (with-temp-buffer
    (insert "before\nold1\nold2\nafter")
    ;; Simulate a prediction that was already parsed
    (setq minuet-duet--modified-tick (buffer-modified-tick)
          minuet-duet--region-start (save-excursion
                                      (goto-char (point-min))
                                      (forward-line 1)
                                      (point))
          minuet-duet--region-end (save-excursion
                                    (goto-char (point-min))
                                    (forward-line 2)
                                    (line-end-position))
          minuet-duet--original-lines '("old1" "old2")
          minuet-duet--proposed-lines '("new1" "new2" "new3")
          minuet-duet--proposed-cursor '(:row-offset 1 :col 3))
    (minuet-duet-apply)
    (should (string= (buffer-string) "before\nnew1\nnew2\nnew3\nafter"))
    ;; State should be cleared
    (should (null minuet-duet--proposed-lines))))

(ert-deftest minuet-duet-apply-cursor-position ()
  "Point is at predicted cursor offset after apply."
  (with-temp-buffer
    (insert "aaa\nbbb\nccc")
    (setq minuet-duet--modified-tick (buffer-modified-tick)
          minuet-duet--region-start (save-excursion
                                      (goto-char (point-min))
                                      (forward-line 1)
                                      (point))
          minuet-duet--region-end (save-excursion
                                    (goto-char (point-min))
                                    (forward-line 1)
                                    (line-end-position))
          minuet-duet--original-lines '("bbb")
          minuet-duet--proposed-lines '("xyz")
          minuet-duet--proposed-cursor '(:row-offset 0 :col 2))
    (let ((region-start minuet-duet--region-start))
      (minuet-duet-apply)
      ;; Point should be at region-start + 2
      (should (= (point) (+ region-start 2))))))

(ert-deftest minuet-duet-stale-prediction-rejected ()
  "Apply rejects stale prediction when buffer was modified."
  (with-temp-buffer
    (insert "original")
    (setq minuet-duet--modified-tick (buffer-modified-tick)
          minuet-duet--region-start (point-min)
          minuet-duet--region-end (point-max)
          minuet-duet--original-lines '("original")
          minuet-duet--proposed-lines '("changed")
          minuet-duet--proposed-cursor '(:row-offset 0 :col 0))
    ;; Modify buffer to make prediction stale
    (goto-char (point-max))
    (insert "!")
    (minuet-duet-apply)
    ;; Buffer should NOT have "changed", still has "original!"
    (should (string= (buffer-string) "original!"))
    ;; State should be cleared
    (should (null minuet-duet--proposed-lines))))

(ert-deftest minuet-duet-dismiss-clears-state ()
  "Dismiss clears all overlays and state."
  (with-temp-buffer
    (insert "test")
    (setq minuet-duet--proposed-lines '("foo")
          minuet-duet--proposed-cursor '(:row-offset 0 :col 0)
          minuet-duet--overlays (list (make-overlay 1 2)))
    (minuet-duet-dismiss)
    (should (null minuet-duet--proposed-lines))
    (should (null minuet-duet--proposed-cursor))
    (should (null minuet-duet--overlays))))

(ert-deftest minuet-duet-visible-p-with-overlays ()
  "visible-p returns non-nil when overlays exist."
  (with-temp-buffer
    (insert "test")
    (setq minuet-duet--overlays (list (make-overlay 1 2)))
    (should (minuet-duet-visible-p))
    (dolist (ov minuet-duet--overlays) (delete-overlay ov))
    (should-not (minuet-duet-visible-p))))

(provide 'minuet-duet-tests)
;;; minuet-duet-tests.el ends here
