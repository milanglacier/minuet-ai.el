;;; test-helper.el --- Test bootstrap for Minuet ERT tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared setup for batch ERT runs.  Tests are executed in `emacs -Q'
;; with an isolated `package-user-dir' so dependencies are installed
;; via the standard `package.el' workflow instead of relying on a
;; specific package manager configuration.

;;; Code:

(defvar minuet-test--temp-emacs-dir nil
  "Temporary Emacs directory created for the current test run.")

(defun minuet-test--emacs-dir ()
  "Return the isolated Emacs directory for the current test run."
  (or (getenv "MINUET_TEST_EMACS_DIR")
      (setq minuet-test--temp-emacs-dir
            (or minuet-test--temp-emacs-dir
                (make-temp-file "minuet-test-emacs-" t)))))

(defun minuet-test--package-user-dir ()
  "Return the isolated package directory for the current test run."
  (or (getenv "PACKAGE_USER_DIR")
      (expand-file-name "elpa" (minuet-test--emacs-dir))))

(defun minuet-test--cleanup-temp-dir ()
  "Delete the temporary Emacs directory created for this test run."
  (when (and minuet-test--temp-emacs-dir
             (file-directory-p minuet-test--temp-emacs-dir))
    (delete-directory minuet-test--temp-emacs-dir t)))

(setq user-emacs-directory (file-name-as-directory (minuet-test--emacs-dir)))

(require 'package)

(defun minuet-test--ensure-packages (packages)
  "Install each package in PACKAGES if it is not already available."
  (let ((missing (seq-remove #'package-installed-p packages)))
    (when missing
      (package-refresh-contents)
      (dolist (pkg missing)
        (package-install pkg)))))

(let* ((this-file (or load-file-name (buffer-file-name)))
       (tests-dir (file-name-directory this-file))
       (project-dir (file-name-directory (directory-file-name tests-dir))))
  (setq load-prefer-newer t
        package-user-dir (minuet-test--package-user-dir)
        package-check-signature nil
        package-quickstart nil
        package-quickstart-file
        (expand-file-name "package-quickstart.el" user-emacs-directory)
        package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                           ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                           ("melpa" . "https://melpa.org/packages/"))
        package-archive-priorities '(("gnu" . 30)
                                     ("nongnu" . 20)
                                     ("melpa" . 10)))
  (package-initialize)
  (minuet-test--ensure-packages '(dash plz))
  (package-initialize)
  (add-hook 'kill-emacs-hook #'minuet-test--cleanup-temp-dir)
  (add-to-list 'load-path project-dir))

(provide 'test-helper)
;;; test-helper.el ends here
