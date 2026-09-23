;;; minuet-context-summary-tests.el --- Tests for summary PoC -*- lexical-binding: t; -*-

(require 'ert)
(load (expand-file-name "test-helper"
                        (file-name-directory
                         (or load-file-name (buffer-file-name)))) nil t)
(require 'minuet-context-summary)

(ert-deftest minuet-context-summary-prompt-uses-target-length-as-hint ()
  (with-temp-buffer
    (insert "(defun example () t)")
    (let ((minuet-context-summary-target-length 1234)
          (minuet-context-summary-prompt "Aim for approximately %d characters."))
      (should (string-match-p "1234" (minuet-context-summary--prompt)))
      (should (string-match-p "defun example" (minuet-context-summary--prompt))))))

(ert-deftest minuet-context-summary-validates-cache-by-modification-tick ()
  (with-temp-buffer
    (insert "source")
    (setq minuet-context-summary--text "summary"
          minuet-context-summary--tick (buffer-chars-modified-tick))
    (should (minuet-context-summary--valid-p))
    (insert " changed")
    (should-not (minuet-context-summary--valid-p))))

(ert-deftest minuet-context-summary-extracts-openai-content ()
  (should (equal
           (minuet-context-summary--extract
            '(:choices ((:message (:content "summary")))) )
           "summary")))

(ert-deftest minuet-context-summary-augmentation-is-optional ()
  (with-temp-buffer
    (let ((minuet-context-summary-enabled nil))
      (should (equal (minuet-context-summary--augment-chat-shot
                      (lambda (_context _options) '("context")) nil nil)
                     '("context"))))))

(provide 'minuet-context-summary-tests)
;;; minuet-context-summary-tests.el ends here
