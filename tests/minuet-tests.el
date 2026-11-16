;;; minuet-tests.el --- Tests for minuet -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for core Minuet behavior.

;;; Code:

(require 'ert)
(require 'seq)
(load (expand-file-name "test-helper"
                        (file-name-directory
                         (or load-file-name (buffer-file-name))))
      nil t)

(require 'minuet)

(ert-deftest minuet-remove-blank-items-drops-whitespace-only-items ()
  "Blank item filtering removes empty items without trimming valid ones."
  (should (equal (minuet--remove-blank-items '("  indented" "" " \t\n" "tail  "))
                 '("  indented" "tail  "))))

(ert-deftest minuet-filter-text-filters-before-cursor-with-nonzero-length ()
  "A non-zero before-cursor filter trims duplicated prefix text."
  (let ((minuet-before-cursor-filter-length 3)
        (minuet-after-cursor-filter-length 0))
    (should (equal (minuet--filter-text
                    "barxyz"
                    '(:before-cursor "foobar" :after-cursor "nomatch"))
                   "xyz"))))

(ert-deftest minuet-filter-text-filters-after-cursor-with-nonzero-length ()
  "A non-zero after-cursor filter trims duplicated suffix text."
  (let ((minuet-before-cursor-filter-length 0)
        (minuet-after-cursor-filter-length 2))
    (should (equal (minuet--filter-text
                    "xyzqu"
                    '(:before-cursor "nomatch" :after-cursor "quux"))
                   "xyz"))))

(ert-deftest minuet-filter-text-filters-before-and-after-with-nonzero-lengths ()
  "Non-zero before and after filters trim duplicated prefix and suffix text."
  (let ((minuet-before-cursor-filter-length 3)
        (minuet-after-cursor-filter-length 2))
    (should (equal (minuet--filter-text
                    "barxyzqu"
                    '(:before-cursor "foobar" :after-cursor "quux"))
                   "xyz"))))

(ert-deftest minuet-filter-text-trims-whitespace-when-filtering-is-enabled ()
  "Enabled filters trim ITEM before removing duplicated context."
  (let ((minuet-before-cursor-filter-length 3)
        (minuet-after-cursor-filter-length 2))
    (should (equal (minuet--filter-text
                    "  barxyzqu  "
                    '(:before-cursor "foobar" :after-cursor "quux"))
                   "xyz"))))

(ert-deftest minuet-filter-text-accepts-function-filter-lengths ()
  "Function-valued filter lengths are evaluated before filtering."
  (let ((minuet-before-cursor-filter-length (lambda () 3))
        (minuet-after-cursor-filter-length (lambda () 2)))
    (should (equal (minuet--filter-text
                    "barxyzz"
                    '(:before-cursor "foobar" :after-cursor "zzquux"))
                   "xy"))))

(ert-deftest minuet-filter-text-disables-filtering-with-fim-defaults ()
  "Provider-aware FIM defaults disable before and after cursor filtering."
  (let ((minuet-provider 'openai-fim-compatible)
        (minuet-before-cursor-filter-length
         #'minuet--default-before-cursor-filter-length-function)
        (minuet-after-cursor-filter-length
         #'minuet--default-after-cursor-filter-length-function))
    (should (equal (minuet--filter-text
                    "barxyzz"
                    '(:before-cursor "foobar" :after-cursor "zzquux"))
                   "barxyzz"))))

(ert-deftest minuet-filter-text-preserves-item-when-filter-lengths-are-zero ()
  "Disabled filters return ITEM without trimming or other changes."
  (let ((minuet-before-cursor-filter-length 0)
        (minuet-after-cursor-filter-length 0))
    (should (equal (minuet--filter-text
                    "  barxyzz  "
                    '(:before-cursor "foobar" :after-cursor "zzquux"))
                   "  barxyzz  "))))

;;;;;
;; Template expansion tests
;;;;;

(ert-deftest minuet-expand-template-basic-substitution ()
  "A placeholder is replaced by the lookup result for its key."
  (should (equal (minuet--expand-template
                  "Hello {{{:name}}}!"
                  (lambda (key) (when (eq key :name) "world")))
                 "Hello world!")))

(ert-deftest minuet-expand-template-repeated-key ()
  "Every occurrence of the same key is replaced."
  (should (equal (minuet--expand-template
                  "{{{:x}}} and {{{:x}}}"
                  (lambda (key) (when (eq key :x) "v")))
                 "v and v")))

(ert-deftest minuet-expand-template-unresolved-key-dropped ()
  "A placeholder whose lookup returns nil is dropped."
  (should (equal (minuet--expand-template "a {{{:missing}}} b" #'ignore)
                 "a  b")))

(ert-deftest minuet-expand-template-adjacent-placeholders ()
  "Adjacent placeholders are expanded independently."
  (should (equal (minuet--expand-template
                  "{{{:a}}}{{{:b}}}"
                  (lambda (key) (if (eq key :a) "1" "2")))
                 "12")))

(ert-deftest minuet-expand-template-unterminated-open-kept-verbatim ()
  "An opening brace triple without a closing triple is kept verbatim."
  (should (equal (minuet--expand-template
                  "{{{:a}}} tail {{{:b"
                  (lambda (_key) "v"))
                 "v tail {{{:b")))

(ert-deftest minuet-expand-template-replacement-not-rescanned ()
  "Placeholders inside replacement values are not expanded again."
  (should (equal (minuet--expand-template
                  "{{{:outer}}}"
                  (lambda (key) (if (eq key :outer) "{{{:inner}}}" "expanded")))
                 "{{{:inner}}}")))

(ert-deftest minuet-expand-template-backslashes-verbatim ()
  "Backslash sequences in replacement values pass through verbatim."
  (should (equal (minuet--expand-template
                  "{{{:v}}}"
                  (lambda (_key) "\\1 \\& \\\\"))
                 "\\1 \\& \\\\")))

(ert-deftest minuet-expand-template-empty-template ()
  "An empty template expands to an empty string."
  (should (equal (minuet--expand-template "" #'ignore) "")))

(ert-deftest minuet-expand-template-non-string-value-errors ()
  "A lookup returning a non-string value signals a type error."
  (should-error (minuet--expand-template "{{{:v}}}" (lambda (_key) 42))
                :type 'wrong-type-argument)
  (should-error (minuet--expand-template "{{{:v}}}" (lambda (_key) '(?a)))
                :type 'wrong-type-argument))

(ert-deftest minuet-expand-template-non-string-template-errors ()
  "A non-string template signals a type error."
  (should-error (minuet--expand-template nil #'ignore)
                :type 'wrong-type-argument)
  (should-error (minuet--expand-template 42 #'ignore)
                :type 'wrong-type-argument))

;;;;;
;; System prompt builder tests
;;;;;

(defvar minuet-test--system-guidelines "guidelines-value"
  "Guidelines variable used by system prompt tests.")

(defun minuet-test--system-prompt-fragment ()
  "Return the prompt fragment used by system prompt tests."
  "prompt-value")

(ert-deftest minuet-make-system-prompt-formats-n-completions ()
  "The n-completions template is formatted with the requested count."
  (let ((template '(:template "{{{:n-completions-template}}}"
                    :n-completions-template "at most %d items")))
    (should (equal (minuet--make-system-prompt template 4)
                   "at most 4 items"))))

(ert-deftest minuet-make-system-prompt-defaults-to-minuet-n-completions ()
  "Without an explicit count the formatter uses `minuet-n-completions'."
  (let ((minuet-n-completions 2)
        (template '(:template "{{{:n-completions-template}}}"
                    :n-completions-template "%d")))
    (should (equal (minuet--make-system-prompt template) "2"))))

(ert-deftest minuet-make-system-prompt-non-string-n-completions-template-errors ()
  "A non-string n-completions template value signals a type error."
  (let ((template '(:template "a{{{:n-completions-template}}}b"
                    :n-completions-template 42)))
    (should-error (minuet--make-system-prompt template 1)
                  :type 'wrong-type-argument)))

(ert-deftest minuet-make-system-prompt-absent-n-completions-template-dropped ()
  "A missing n-completions template key drops its placeholder."
  (let ((template '(:template "a{{{:n-completions-template}}}b")))
    (should (equal (minuet--make-system-prompt template 1) "ab"))))

(ert-deftest minuet-make-system-prompt-evals-plist-values ()
  "Function, variable and string plist values resolve via `minuet--eval-value'."
  (let ((template '(:template "{{{:fn}}}|{{{:sym}}}|{{{:str}}}"
                    :fn minuet-test--system-prompt-fragment
                    :sym minuet-test--system-guidelines
                    :str "literal")))
    (should (equal (minuet--make-system-prompt template 1)
                   "prompt-value|guidelines-value|literal"))))

(ert-deftest minuet-make-system-prompt-unresolved-placeholder-dropped ()
  "Placeholders without a matching template key are dropped."
  (let ((template '(:template "a {{{:missing}}} b")))
    (should (equal (minuet--make-system-prompt template 1) "a  b"))))

(ert-deftest minuet-make-system-prompt-preserves-backslashes ()
  "Backslash sequences in replacement values are inserted verbatim."
  (let ((template '(:template "{{{:prompt}}}"
                    :prompt "use \\1 and \\& and C:\\path")))
    (should (equal (minuet--make-system-prompt template 1)
                   "use \\1 and \\& and C:\\path"))))

(ert-deftest minuet-make-system-prompt-two-unresolved-on-one-line ()
  "Text between two unresolved placeholders on one line is preserved."
  (let ((template '(:template "{{{:m1}}} keep {{{:m2}}}")))
    (should (equal (minuet--make-system-prompt template 1) " keep "))))

;;;;;
;; Chat llm shot builder tests
;;;;;

(defun minuet-test--chat-before-cursor (context)
  "Return the before-cursor text from CONTEXT for chat shot tests."
  (plist-get context :before-cursor))

(defun minuet-test--chat-shot-nil (_context)
  "Return nil regardless of CONTEXT for chat shot tests."
  nil)

(ert-deftest minuet-make-chat-llm-shot-single-template-string ()
  "A string :template yields a single-element list with CONTEXT applied."
  (let* ((options '(:chat-input
                    (:template "ctx: {{{:before}}}"
                     :before minuet-test--chat-before-cursor)))
         (result (minuet--make-chat-llm-shot '(:before-cursor "abc") options)))
    (should (equal result '("ctx: abc")))))

(ert-deftest minuet-make-chat-llm-shot-template-list ()
  "A list-valued :template yields one expanded string per template."
  (let* ((options '(:chat-input
                    (:template ("first {{{:before}}}" "second {{{:before}}}")
                     :before minuet-test--chat-before-cursor)))
         (result (minuet--make-chat-llm-shot '(:before-cursor "x") options)))
    (should (equal result '("first x" "second x")))))

(ert-deftest minuet-make-chat-llm-shot-nil-result-drops-placeholder ()
  "A replacement function returning nil drops its placeholder."
  (let* ((options '(:chat-input
                    (:template "a {{{:gone}}} b"
                     :gone minuet-test--chat-shot-nil)))
         (result (minuet--make-chat-llm-shot nil options)))
    (should (equal result '("a  b")))))

(ert-deftest minuet-make-chat-llm-shot-does-not-mutate-options ()
  "Building chat shots leaves the OPTIONS plist unchanged."
  (let ((options (list :chat-input
                       (list :template "x {{{:before}}}"
                             :before #'minuet-test--chat-before-cursor))))
    (minuet--make-chat-llm-shot '(:before-cursor "b") options)
    (should (equal (plist-get (plist-get options :chat-input) :template)
                   "x {{{:before}}}"))))

(defmacro minuet-test--with-displayed-suggestion (suggestion &rest body)
  "Run BODY in a temporary buffer where SUGGESTION is the displayed suggestion."
  (declare (indent 1))
  `(with-temp-buffer
     (setq minuet--current-suggestions (list ,suggestion)
           minuet--current-suggestion-index 0
           minuet--current-overlay (make-overlay (point) (point)))
     ,@body))

(ert-deftest minuet-accept-suggestion-word-accepts-first-word ()
  "Accepting a word inserts the first word and keeps the rest displayed."
  (minuet-test--with-displayed-suggestion "foo bar baz"
    (minuet-accept-suggestion-word)
    (should (equal (buffer-string) "foo"))
    (should (equal minuet--current-suggestions '(" bar baz")))
    (should minuet--current-overlay)))

(ert-deftest minuet-accept-suggestion-word-accepts-n-words ()
  "A numeric argument accepts that many words at once."
  (minuet-test--with-displayed-suggestion "foo bar baz"
    (minuet-accept-suggestion-word 2)
    (should (equal (buffer-string) "foo bar"))
    (should (equal minuet--current-suggestions '(" baz")))))

(ert-deftest minuet-accept-suggestion-word-includes-leading-non-word-chars ()
  "Leading whitespace and punctuation are accepted along with the first word."
  (minuet-test--with-displayed-suggestion "  (foo) bar"
    (minuet-accept-suggestion-word)
    (should (equal (buffer-string) "  (foo"))
    (should (equal minuet--current-suggestions '(") bar")))))

(ert-deftest minuet-accept-suggestion-word-crosses-newlines ()
  "Word acceptance continues onto the next line of the suggestion."
  (minuet-test--with-displayed-suggestion "foo\nbar baz"
    (minuet-accept-suggestion-word 2)
    (should (equal (buffer-string) "foo\nbar"))
    (should (equal minuet--current-suggestions '(" baz")))))

(ert-deftest minuet-accept-suggestion-word-accepts-all-when-n-exceeds-words ()
  "A count larger than the word total accepts the whole suggestion."
  (minuet-test--with-displayed-suggestion "foo bar"
    (minuet-accept-suggestion-word 5)
    (should (equal (buffer-string) "foo bar"))
    (should-not minuet--current-overlay)))

(provide 'minuet-tests)
;;; minuet-tests.el ends here
