;;; minuet-duet-tests.el --- Tests for minuet-duet -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for duet response parsing, context extraction, and
;; integration tests for apply/dismiss.

;;; Code:

(require 'ert)
(load (expand-file-name "test-helper"
                        (file-name-directory
                         (or load-file-name (buffer-file-name))))
      nil t)

(require 'minuet)
(require 'minuet-duet)

(defconst minuet-duet-test--tests-directory
  (file-name-directory (or load-file-name (buffer-file-name)))
  "Directory containing the duet ERT test files.")

(defun minuet-duet-test--fixture-path (name)
  "Return the absolute path to test fixture NAME."
  (expand-file-name
   name
   (expand-file-name "scripts" minuet-duet-test--tests-directory)))

(defun minuet-duet-test--wait-until (predicate timeout message)
  "Wait until PREDICATE return non-nil or fail after TIMEOUT seconds.
Use MESSAGE in the assertion failure."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (< (float-time) deadline)
                (not (funcall predicate)))
      (accept-process-output nil 0.05))
    (unless (funcall predicate)
      (ert-fail message))))

;;;;;
;; Duet response parsing tests
;;;;;

(ert-deftest minuet-duet-parse-valid ()
  "Valid response with one cursor marker."
  (let* ((text (concat minuet-duet-editable-region-start-marker "\n"
                       "hello " minuet-duet-cursor-position-marker "world\n"
                       minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response text)))
    (should result)
    (should (equal (car result) '("hello world")))
    (should (= (plist-get (cdr result) :row-offset) 0))
    (should (= (plist-get (cdr result) :col) 6))))

(ert-deftest minuet-duet-parse-multiline ()
  "Valid multi-line response."
  (let* ((text (concat minuet-duet-editable-region-start-marker "\n"
                       "line1\n"
                       "line2" minuet-duet-cursor-position-marker "\n"
                       "line3\n"
                       minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response text)))
    (should result)
    (should (equal (car result) '("line1" "line2" "line3")))
    (should (= (plist-get (cdr result) :row-offset) 1))
    (should (= (plist-get (cdr result) :col) 5))))

(ert-deftest minuet-duet-parse-missing-start-marker ()
  "Missing start marker returns nil."
  (let ((text (concat "hello " minuet-duet-cursor-position-marker "world\n"
                      minuet-duet-editable-region-end-marker)))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-missing-end-marker ()
  "Missing end marker returns nil."
  (let ((text (concat minuet-duet-editable-region-start-marker
                      "\nhello " minuet-duet-cursor-position-marker "world")))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-duplicate-start-marker ()
  "Duplicate start markers returns nil."
  (let ((text (concat minuet-duet-editable-region-start-marker "\n"
                      minuet-duet-editable-region-start-marker "\n"
                      "hello " minuet-duet-cursor-position-marker "world\n"
                      minuet-duet-editable-region-end-marker)))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-missing-cursor-marker ()
  "Missing cursor marker falls back to the editable region end."
  (let ((text (concat minuet-duet-editable-region-start-marker "\n"
                      "hello world\n"
                      minuet-duet-editable-region-end-marker))
        messages)
    (cl-letf (((symbol-function 'minuet--log)
               (lambda (message &optional _message-p)
                 (push message messages)
                 nil)))
      (let ((result (minuet-duet--parse-response text)))
        (should result)
        (should (equal (car result) '("hello world")))
        (should (= (plist-get (cdr result) :row-offset) 0))
        (should (= (plist-get (cdr result) :col) 11))
        (should (member "Minuet duet: cursor marker missing; using editable region end"
                        messages))))))

(ert-deftest minuet-duet-parse-duplicate-cursor-marker ()
  "Duplicate cursor markers returns nil."
  (let ((text (concat minuet-duet-editable-region-start-marker "\n"
                      "hello " minuet-duet-cursor-position-marker
                      "wor" minuet-duet-cursor-position-marker "ld\n"
                      minuet-duet-editable-region-end-marker)))
    (should (null (minuet-duet--parse-response text)))))

(ert-deftest minuet-duet-parse-newline-trimming ()
  "Leading and trailing newlines inside markers are trimmed."
  ;; Two leading newlines: first trimmed, second kept as empty first line
  (let* ((text (concat minuet-duet-editable-region-start-marker "\n\n"
                       minuet-duet-cursor-position-marker "hello\n"
                       minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response text)))
    (should result)
    ;; The inner text after removing first \n is "\n<cursor>hello"
    ;; Trailing \n is also trimmed, so inner = "\n<cursor>hello" -> "" and "hello"
    ;; Actually: inner after first trim = "\n<cursor>hello"
    ;; trailing trim: "\n<cursor>hello" (no trailing \n to trim)
    ;; So lines = ("" "hello"), cursor at line 1 col 0
    (should (equal (car result) '("" "hello")))))

(ert-deftest minuet-duet-parse-empty-response ()
  "Empty string returns nil."
  (should (null (minuet-duet--parse-response "")))
  (should (null (minuet-duet--parse-response nil))))

(ert-deftest minuet-duet-parse-filters-duplicated-typescript-context ()
  "Parse a realistic TypeScript edit when the response repeats context lines."
  (with-temp-buffer
    (insert (mapconcat
             #'identity
             '("import { readFile } from \"node:fs/promises\";"
               ""
               "type User = {"
               "  id: string;"
               "  name: string;"
               "};"
               ""
               "export async function loadUsers(path: string) {"
               "  const raw = await readFile(path, \"utf8\");"
               "  const rows = JSON.parse(raw);"
               "  return rows.map((row: Record<string, unknown>) => ({"
               "    id: String(row.id),"
               "    name: String(row.name),"
               "  }));"
               "}")
             "\n"))
    (goto-char (point-min))
    (search-forward "  const rows")
    (let* ((minuet-duet-editable-region-lines-before 0)
           (minuet-duet-editable-region-lines-after 0)
           (context (minuet-duet--build-context))
           (duplicated-before
            "  const raw = await readFile(path, \"utf8\");")
           (duplicated-after
            "  return rows.map((row: Record<string, unknown>) => ({")
           (replacement
            "  const rows = JSON.parse(raw) as Array<Record<string, unknown>>;")
           (response
            (concat minuet-duet-editable-region-start-marker "\n"
                    duplicated-before "\n"
                    replacement minuet-duet-cursor-position-marker "\n"
                    duplicated-after "\n"
                    minuet-duet-editable-region-end-marker))
           (result (minuet-duet--parse-response response context)))
      (should result)
      (should (member replacement (car result)))
      (should-not (member duplicated-before (car result)))
      (should-not (member duplicated-after (car result)))
      (should (= (plist-get (cdr result) :col) (length replacement))))))

(ert-deftest minuet-duet-parse-filters-duplicated-python-context ()
  "Parse a realistic Python edit when the response repeats surrounding code."
  (with-temp-buffer
    (insert (mapconcat
             #'identity
             '("from dataclasses import dataclass"
               "@dataclass"
               "class Order:"
               "    items: list[float]"
               "    discount: float"
               "def total_order(order: Order) -> float:"
               "    subtotal = sum(order.items)"
               "    taxable = max(subtotal - order.discount, 0.0)"
               "    return round(taxable * 1.0825, 2)"
               "print(total_order(Order([12.5, 8.0, 3.25], 2.0)))")
             "\n"))
    (goto-char (point-min))
    (search-forward "    return round")
    (let* ((minuet-duet-editable-region-lines-before 0)
           (minuet-duet-editable-region-lines-after 0)
           (context (minuet-duet--build-context))
           (duplicated-before
            "    taxable = max(subtotal - order.discount, 0.0)")
           (duplicated-after
            "print(total_order(Order([12.5, 8.0, 3.25], 2.0)))")
           (replacement "    return round(taxable * 1.0925, 2)")
           (response
            (concat minuet-duet-editable-region-start-marker "\n"
                    duplicated-before "\n"
                    replacement minuet-duet-cursor-position-marker "\n"
                    duplicated-after "\n"
                    minuet-duet-editable-region-end-marker))
           (result (minuet-duet--parse-response response context)))
      (should result)
      (should (member replacement (car result)))
      (should-not (member duplicated-before (car result)))
      (should-not (member duplicated-after (car result)))
      (should (= (plist-get (cdr result) :col) (length replacement))))))

(ert-deftest minuet-duet-parse-trims-prefix-before-recording-cursor ()
  "Duplicated prefix context is trimmed before cursor position is recorded."
  (let* ((minuet-duet-filter-region-before-length 3)
         (context '(:non-editable-region-before "left prefix"
                    :non-editable-region-after ""))
         (response (concat minuet-duet-editable-region-start-marker "\n"
                           "prefix" minuet-duet-cursor-position-marker
                           "body\n"
                           minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response response context)))
    (should result)
    (should (equal (car result) '("body")))
    (should (= (plist-get (cdr result) :row-offset) 0))
    (should (= (plist-get (cdr result) :col) 0))))

(ert-deftest minuet-duet-parse-trims-prefix-boundary-line ()
  "Duplicated prefix trimming also removes the boundary newline."
  (let* ((minuet-duet-filter-region-before-length 3)
         (context '(:non-editable-region-before "left\nprefix"
                    :non-editable-region-after ""))
         (response (concat minuet-duet-editable-region-start-marker "\n"
                           "prefix\n"
                           minuet-duet-cursor-position-marker
                           "body\n"
                           minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response response context)))
    (should result)
    (should (equal (car result) '("body")))
    (should (= (plist-get (cdr result) :row-offset) 0))
    (should (= (plist-get (cdr result) :col) 0))))

(ert-deftest minuet-duet-parse-preserves-leading-blank-line-without-prefix-trim ()
  "Leading blank lines are preserved when prefix deduplication does not trim."
  (let* ((minuet-duet-filter-region-before-length 3)
         (context '(:non-editable-region-before "unrelated"
                    :non-editable-region-after ""))
         (response (concat minuet-duet-editable-region-start-marker "\n\n"
                           minuet-duet-cursor-position-marker
                           "body\n"
                           minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response response context)))
    (should result)
    (should (equal (car result) '("" "body")))
    (should (= (plist-get (cdr result) :row-offset) 1))
    (should (= (plist-get (cdr result) :col) 0))))

(ert-deftest minuet-duet-parse-trims-suffix-after-removing-cursor ()
  "Duplicated suffix context is trimmed after removing the cursor marker."
  (let* ((minuet-duet-filter-region-after-length 3)
         (context '(:non-editable-region-before ""
                    :non-editable-region-after "suffix right"))
         (response (concat minuet-duet-editable-region-start-marker "\n"
                           "body suf" minuet-duet-cursor-position-marker
                           "fix\n"
                           minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response response context)))
    (should result)
    (should (equal (car result) '("body ")))
    (should (= (plist-get (cdr result) :row-offset) 0))
    (should (= (plist-get (cdr result) :col) 5))))

(ert-deftest minuet-duet-parse-trims-suffix-boundary-line ()
  "Duplicated suffix trimming also removes the boundary newline."
  (let* ((minuet-duet-filter-region-after-length 3)
         (context '(:non-editable-region-before ""
                    :non-editable-region-after "suffix\nright"))
         (response (concat minuet-duet-editable-region-start-marker "\n"
                           "body"
                           minuet-duet-cursor-position-marker
                           "\nsuffix\n"
                           minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response response context)))
    (should result)
    (should (equal (car result) '("body")))
    (should (= (plist-get (cdr result) :row-offset) 0))
    (should (= (plist-get (cdr result) :col) 4))))

(ert-deftest minuet-duet-parse-preserves-trailing-blank-line-without-suffix-trim ()
  "Trailing blank lines are preserved when suffix deduplication does not trim."
  (let* ((minuet-duet-filter-region-after-length 3)
         (context '(:non-editable-region-before ""
                    :non-editable-region-after "unrelated"))
         (response (concat minuet-duet-editable-region-start-marker "\n"
                           "body"
                           minuet-duet-cursor-position-marker
                           "\n\n"
                           minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response response context)))
    (should result)
    (should (equal (car result) '("body" "")))
    (should (= (plist-get (cdr result) :row-offset) 0))
    (should (= (plist-get (cdr result) :col) 4))))

(ert-deftest minuet-duet-parse-clamps-cursor-after-suffix-trimming ()
  "Cursor moves to the final text end when suffix trimming removes its index."
  (let* ((minuet-duet-filter-region-after-length 3)
         (context '(:non-editable-region-before "left prefix"
                    :non-editable-region-after "suffix right"))
         (response (concat minuet-duet-editable-region-start-marker "\n"
                           "body suffix"
                           minuet-duet-cursor-position-marker "\n"
                           minuet-duet-editable-region-end-marker))
         (result (minuet-duet--parse-response response context)))
    (should result)
    (should (equal (car result) '("body ")))
    (should (= (plist-get (cdr result) :row-offset) 0))
    (should (= (plist-get (cdr result) :col) 5))))

;;;;;
;; Context extraction tests
;;;;;

(ert-deftest minuet-duet-make-system-prompt-default-template ()
  "Default duet system template expands configured prompt fragments."
  (let ((result (minuet-duet--make-system-prompt minuet-duet-default-system)))
    (should (string-match-p "You are an AI editing engine" result))
    (should (string-match-p "Guidelines:" result))
    (should (string-match-p
             (regexp-quote minuet-duet-editable-region-start-marker)
             result))
    (should (string-match-p
             (regexp-quote minuet-duet-editable-region-end-marker)
             result))
    (should (string-match-p
             (regexp-quote minuet-duet-cursor-position-marker)
             result))))

(ert-deftest minuet-duet-make-system-prompt-literal-walk ()
  "System prompt placeholders are resolved from the template itself."
  (let* ((template '(:template "A {{{:first}}} B {{{:missing}}} C {{{:first}}}"
                     :first "value"
                     :unused "unused {{{:first}}}"))
         (result (minuet-duet--make-system-prompt template)))
    (should (equal result "A value B  C value"))))

(ert-deftest minuet-duet-make-chat-input-default-template ()
  "Default duet chat input expands dynamic placeholders from CONTEXT."
  (let* ((context '(:non-editable-region-before "before\n"
                    :editable-region-before-cursor "edit-before"
                    :editable-region-after-cursor "edit-after"
                    :non-editable-region-after "\nafter"))
         (result (minuet-duet--make-chat-input context
                                               minuet-duet-default-chat-input)))
    (should
     (equal result
            (concat "before\n\n"
                    minuet-duet-editable-region-start-marker "\n"
                    "edit-before"
                    minuet-duet-cursor-position-marker
                    "edit-after\n"
                    minuet-duet-editable-region-end-marker
                    "\n\n"
                    "after")))))

(ert-deftest minuet-duet-make-chat-input-custom-placeholder-dispatch ()
  "Custom duet chat input placeholders are resolved from CHAT-INPUT."
  (let* ((context '(:name "world"))
         (chat-input '(:template minuet-duet-test--chat-input-template
                       :greeting minuet-duet-test--chat-input-greeting
                       :missing nil))
         (result (minuet-duet--make-chat-input context chat-input)))
    (should (equal result "Hello, world! "))))

(defun minuet-duet-test--chat-input-template ()
  "Return a custom chat input template used by duet test."
  "{{{:greeting}}}! {{{:missing}}}")

(defun minuet-duet-test--chat-input-greeting (context)
  "Return a greeting derived from CONTEXT for duet test."
  (format "Hello, %s" (plist-get context :name)))

(ert-deftest minuet-duet-context-empty-buffer ()
  "Context from an empty buffer."
  (with-temp-buffer
    (let ((ctx (minuet-duet--build-context)))
      (should (integerp (plist-get ctx :chars-modified-tick)))
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

;;;;;
;; Integration tests: apply, dismiss, stale detection
;;;;;

(ert-deftest minuet-duet-render-preview-pure-insertion-in-middle ()
  "Pure insertions in the middle render before the following line."
  (with-temp-buffer
    (insert "a\nb")
    (setq minuet-duet--region-start (point-min)
          minuet-duet--original-lines '("a" "b")
          minuet-duet--proposed-lines '("a" "x" "b")
          minuet-duet--proposed-cursor nil)
    (minuet-duet--render-preview)
    (should (= (length minuet-duet--overlays) 1))
    (let* ((ov (car minuet-duet--overlays))
           (line-2-start (save-excursion
                           (goto-char (point-min))
                           (forward-line 1)
                           (point))))
      (should (= (overlay-start ov) line-2-start))
      (should (= (overlay-end ov) line-2-start))
      (should (overlay-get ov 'before-string))
      (should-not (overlay-get ov 'after-string)))
    (should minuet-duet-active-mode)))

(ert-deftest minuet-duet-render-preview-pure-insertion-at-end ()
  "Pure insertions at the end render after the last original line."
  (with-temp-buffer
    (insert "a\nb")
    (setq minuet-duet--region-start (point-min)
          minuet-duet--original-lines '("a" "b")
          minuet-duet--proposed-lines '("a" "b" "x")
          minuet-duet--proposed-cursor nil)
    (minuet-duet--render-preview)
    (should (= (length minuet-duet--overlays) 1))
    (let ((ov (car minuet-duet--overlays)))
      (should (= (overlay-start ov) (point-max)))
      (should (= (overlay-end ov) (point-max)))
      (should-not (overlay-get ov 'before-string))
      (should (overlay-get ov 'after-string)))))

(ert-deftest minuet-duet-render-preview-replacement-continuation-keeps-order ()
  "Replacement continuations stay ordered on an indented blank line."
  (with-temp-buffer
    (insert "    \n")
    (setq minuet-duet--region-start (point-min)
          minuet-duet--original-lines '("    ")
          minuet-duet--proposed-lines
          '("    result[\"diff\"] = result[\"max\"] - result[\"first\"]"
            "    return result[\"diff\"]")
          minuet-duet--proposed-cursor nil)
    (minuet-duet--render-preview)
    (should (= (length minuet-duet--overlays) 1))
    (let* ((ov (car minuet-duet--overlays))
           (after (substring-no-properties (overlay-get ov 'after-string))))
      (should (string-match-p
               (regexp-quote
                "result[\"diff\"] = result[\"max\"] - result[\"first\"]\n    return result[\"diff\"]")
               after)))))

(ert-deftest minuet-duet-render-preview-with-cursor-only-activates-mode ()
  "Cursor-only previews activate the duet keymap."
  (with-temp-buffer
    (insert "a\nb")
    (setq minuet-duet--region-start (point-min)
          minuet-duet--original-lines '("a" "b")
          minuet-duet--proposed-lines '("a" "b")
          minuet-duet--proposed-cursor '(:row-offset 1 :col 1))
    (minuet-duet--render-preview)
    (should (= (length minuet-duet--overlays) 1))
    (should minuet-duet-active-mode)))

(ert-deftest minuet-duet-render-preview-without-visible-preview-keeps-mode-off ()
  "No hunks and no cursor leave the duet keymap inactive."
  (with-temp-buffer
    (insert "a\nb")
    (setq minuet-duet--region-start (point-min)
          minuet-duet--original-lines '("a" "b")
          minuet-duet--proposed-lines '("a" "b")
          minuet-duet--proposed-cursor nil)
    (minuet-duet--render-preview)
    (should (null minuet-duet--overlays))
    (should-not minuet-duet-active-mode)))

(ert-deftest minuet-duet-apply-replaces-region ()
  "Apply replaces only the editable region."
  (with-temp-buffer
    (insert "before\nold1\nold2\nafter")
    ;; Simulate a prediction that was already parsed
    (setq minuet-duet--chars-modified-tick (buffer-chars-modified-tick)
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
          minuet-duet--proposed-cursor '(:row-offset 1 :col 3)
          minuet-duet-active-mode t)
    (minuet-duet-apply)
    (should (string= (buffer-string) "before\nnew1\nnew2\nnew3\nafter"))
    ;; State should be cleared
    (should (null minuet-duet--proposed-lines))
    (should-not minuet-duet-active-mode)))

(ert-deftest minuet-duet-apply-cursor-position ()
  "Point is at predicted cursor offset after apply."
  (with-temp-buffer
    (insert "aaa\nbbb\nccc")
    (setq minuet-duet--chars-modified-tick (buffer-chars-modified-tick)
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

(ert-deftest minuet-duet-apply-complex-multiline-rewrite ()
  "Apply handles a complex multi-line rewrite with blank lines."
  (with-temp-buffer
    (insert
     (mapconcat
      #'identity
      '("function buildRequest(user, overrides) {"
        "  const headers = { 'content-type': 'application/json' };"
        "  const payload = {"
        "    id: user.id,"
        "    name: user.name,"
        "  };"
        "  return send(payload, headers);"
        "}"
        ""
        "export default buildRequest;")
      "\n"))
    (setq minuet-duet--chars-modified-tick (buffer-chars-modified-tick)
          minuet-duet--region-start (save-excursion
                                      (goto-char (point-min))
                                      (forward-line 2)
                                      (point))
          minuet-duet--region-end (save-excursion
                                    (goto-char (point-min))
                                    (forward-line 6)
                                    (line-end-position))
          minuet-duet--original-lines
          '("  const payload = {"
            "    id: user.id,"
            "    name: user.name,"
            "  };"
            "  return send(payload, headers);")
          minuet-duet--proposed-lines
          '("  const payload = {"
            "    id: user.id,"
            "    name: user.name,"
            "    role: overrides.role ?? 'viewer',"
            "  };"
            ""
            "  if (overrides.dryRun) {"
            "    return payload;"
            "  }"
            ""
            "  return send(payload, {"
            "    ...headers,"
            "    ...overrides.headers,"
            "  });")
          minuet-duet--proposed-cursor '(:row-offset 7 :col 11)
          minuet-duet-active-mode t)
    (minuet-duet-apply)
    (should
     (string=
      (buffer-string)
      (mapconcat
       #'identity
       '("function buildRequest(user, overrides) {"
         "  const headers = { 'content-type': 'application/json' };"
         "  const payload = {"
         "    id: user.id,"
         "    name: user.name,"
         "    role: overrides.role ?? 'viewer',"
         "  };"
         ""
         "  if (overrides.dryRun) {"
         "    return payload;"
         "  }"
         ""
         "  return send(payload, {"
         "    ...headers,"
         "    ...overrides.headers,"
         "  });"
         "}"
         ""
         "export default buildRequest;")
       "\n")))
    (should (string= (thing-at-point 'line t) "    return payload;\n"))
    (should (= (current-column) 11))
    (should (null minuet-duet--proposed-lines))
    (should-not minuet-duet-active-mode)))

(ert-deftest minuet-duet-stale-prediction-rejected ()
  "Apply rejects stale prediction when buffer was modified."
  (with-temp-buffer
    (insert "original")
    (setq minuet-duet--chars-modified-tick (buffer-chars-modified-tick)
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

(ert-deftest minuet-duet-predict-ignores-property-only-buffer-changes ()
  "Property-only buffer churn does not stale the first duet response."
  (with-temp-buffer
    (insert "const value = 1;")
    (let* ((callback nil)
           (response (concat minuet-duet-editable-region-start-marker "\n"
                             "const value = 2;"
                             minuet-duet-cursor-position-marker
                             "\n"
                             minuet-duet-editable-region-end-marker))
           (minuet-duet-provider 'gemini))
      (cl-letf (((symbol-function 'minuet-duet--gemini-complete)
                 (lambda (_context cb)
                   (setq callback cb))))
        (minuet-duet-predict))
      (should callback)
      ;; Simulate cold-start fontification/property setup without editing text.
      (with-silent-modifications
        (put-text-property (point-min) (point-max) 'fontified t))
      (funcall callback response)
      (should (equal minuet-duet--proposed-lines '("const value = 2;")))
      (should (minuet-duet-visible-p)))))

(ert-deftest minuet-duet-predict-openai-compatible-transport ()
  "OpenAI-compatible duet requests work through the streaming transport."
  (with-temp-buffer
    (insert "return 1")
    (goto-char (point-max))
    (let* ((process-environment (copy-sequence process-environment))
           (plz-curl-program
            (minuet-duet-test--fixture-path "mock_openai_stream.py"))
           (minuet-duet-provider 'openai-compatible)
           (minuet-duet-request-timeout 2)
           (minuet-duet-editable-region-lines-before 0)
           (minuet-duet-editable-region-lines-after 0)
           (response (concat minuet-duet-editable-region-start-marker "\n"
                             "return 42"
                             minuet-duet-cursor-position-marker
                             "\n"
                             minuet-duet-editable-region-end-marker))
           (minuet-duet-openai-compatible-options
            `(:model "fixture-model"
              :api-key "OPENROUTER_API_KEY"
              :end-point ,response
              :name "Fixture"
              :system ,minuet-duet-default-system
              :fewshots nil
              :chat-input ,minuet-duet-default-chat-input
              :optional nil
              :transform ())))
      (setenv "OPENROUTER_API_KEY" "test-key")
      (unwind-protect
          (progn
            (minuet-duet-predict)
            (minuet-duet-test--wait-until
             #'minuet-duet-visible-p
             3
             "duet preview did not become visible through the transport test")
            (should (equal minuet-duet--proposed-lines '("return 42")))
            (minuet-duet-apply)
            (should (equal (buffer-string) "return 42"))
            (should (= (current-column) 9))
            (should-not (minuet-duet-visible-p))
            (should-not minuet-duet-active-mode))
        (minuet-duet-dismiss)))))

(ert-deftest minuet-duet-dismiss-clears-state ()
  "Dismiss clears all overlays and state."
  (with-temp-buffer
    (insert "test")
    (setq minuet-duet--proposed-lines '("foo")
          minuet-duet--proposed-cursor '(:row-offset 0 :col 0)
          minuet-duet--overlays (list (make-overlay 1 2))
          minuet-duet-active-mode t)
    (minuet-duet-dismiss)
    (should (null minuet-duet--proposed-lines))
    (should (null minuet-duet--proposed-cursor))
    (should (null minuet-duet--overlays))
    (should-not minuet-duet-active-mode)))

(ert-deftest minuet-duet-dismiss-removes-after-change-hook ()
  "Dismiss removes the local duet after-change hook and pending state."
  (with-temp-buffer
    (insert "test")
    (minuet-duet--install-after-change-hook)
    (setq minuet-duet--pending-seq 42
          minuet-duet--chars-modified-tick (buffer-chars-modified-tick)
          minuet-duet--region-start (point-min)
          minuet-duet--region-end (point-max)
          minuet-duet--original-lines '("test")
          minuet-duet--proposed-lines '("done")
          minuet-duet--proposed-cursor '(:row-offset 0 :col 1))
    (should minuet-duet--after-change-active)
    (should (memq #'minuet-duet--on-after-change after-change-functions))
    (minuet-duet-dismiss)
    (should-not minuet-duet--after-change-active)
    (should-not (memq #'minuet-duet--on-after-change after-change-functions))
    (should (null minuet-duet--pending-seq))
    (should (null minuet-duet--region-start))
    (should (null minuet-duet--region-end))
    (should (null minuet-duet--original-lines))))

(ert-deftest minuet-duet-dismiss-cancels-live-request ()
  "Dismiss terminates a live pending request before clearing state."
  (with-temp-buffer
    (let ((fake-process 'fake-process)
          (signal-args nil))
      (setq minuet-duet--current-request fake-process
            minuet-duet--proposed-lines '("foo")
            minuet-duet--proposed-cursor '(:row-offset 0 :col 0))
      (cl-letf (((symbol-function 'process-live-p)
                 (lambda (process)
                   (eq process fake-process)))
                ((symbol-function 'signal-process)
                 (lambda (process signal)
                   (setq signal-args (list process signal)))))
        (minuet-duet-dismiss))
      (should (equal signal-args (list fake-process 'SIGTERM)))
      (should (null minuet-duet--current-request))
      (should (null minuet-duet--proposed-lines))
      (should (null minuet-duet--proposed-cursor)))))

(ert-deftest minuet-duet-visible-p-with-overlays ()
  "Visible-p returns non-nil when overlays exist."
  (with-temp-buffer
    (insert "test")
    (setq minuet-duet--overlays (list (make-overlay 1 2)))
    (should (minuet-duet-visible-p))
    (dolist (ov minuet-duet--overlays) (delete-overlay ov))
    (should-not (minuet-duet-visible-p))))

(provide 'minuet-duet-tests)
;;; minuet-duet-tests.el ends here
