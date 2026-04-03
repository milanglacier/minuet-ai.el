;;; minuet-capf-tests.el --- Tests for Minuet CAPF -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'minuet-capf)

(ert-deftest minuet-capf-returns-point-range-and-props ()
  (with-temp-buffer
    (insert "foo")
    (let ((minuet-provider 'openai-fim-compatible))
      (cl-letf (((symbol-function 'minuet--openai-fim-compatible-available-p)
                 (lambda () t)))
        (let ((capf (minuet-completion-at-point)))
          (should (equal (list (nth 0 capf) (nth 1 capf))
                         (list (point) (point))))
          (should (functionp (nth 2 capf)))
          (should (eq (plist-get (nthcdr 3 capf) :exclusive) 'no))
          (should (functionp (plist-get (nthcdr 3 capf) :exit-function))))))))

(ert-deftest minuet-capf-table-returns-deduplicated-completions ()
  (with-temp-buffer
    (let ((minuet-provider 'openai-fim-compatible)
          (minuet-add-single-line-entry nil))
      (cl-letf (((symbol-function 'minuet--openai-fim-compatible-available-p)
                 (lambda () t))
                ((symbol-function 'minuet--openai-fim-compatible-complete)
                 (lambda (_context callback)
                   (funcall callback '("alpha" "beta" "alpha")))))
        (let* ((capf (minuet-completion-at-point))
               (table (nth 2 capf)))
          (should (equal (all-completions "a" table) '("alpha")))
          (should (equal (funcall table "" nil 'metadata)
                         '(metadata (category . minuet-capf))))
          (should-not (funcall table "" nil 'boundaries)))))))

(ert-deftest minuet-capf-exit-function-flushes-session ()
  (with-temp-buffer
    (let ((minuet-provider 'openai-fim-compatible))
      (cl-letf (((symbol-function 'minuet--openai-fim-compatible-available-p)
                 (lambda () t))
                ((symbol-function 'minuet--openai-fim-compatible-complete)
                 (lambda (_context callback)
                   (funcall callback '("alpha")))))
        (let* ((capf (minuet-completion-at-point))
               (table (nth 2 capf))
               (exit-function (plist-get (nthcdr 3 capf) :exit-function)))
          (should minuet--capf-session)
          (should (equal (all-completions "" table) '("alpha")))
          (funcall exit-function "alpha" 'finished)
          (should-not minuet--capf-session))))))

(ert-deftest minuet-capf-stale-callback-is-ignored-after-flush ()
  (with-temp-buffer
    (let ((minuet-provider 'openai-fim-compatible)
          callback)
      (cl-letf (((symbol-function 'minuet--openai-fim-compatible-available-p)
                 (lambda () t))
                ((symbol-function 'minuet--openai-fim-compatible-complete)
                 (lambda (_context cb)
                   (setq callback cb))))
        (let* ((capf (minuet-completion-at-point))
               (table (nth 2 capf)))
          (should-not (all-completions "" table))
          (minuet--capf-flush-session)
          (funcall callback '("late"))
          (should-not minuet--capf-session)
          (should-not (all-completions "" table)))))))

(provide 'minuet-capf-tests)
;;; minuet-capf-tests.el ends here
