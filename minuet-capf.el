;;; minuet-capf.el --- CAPF integration for Minuet -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; This file is part of GNU Emacs

;;; Commentary:

;; `completion-at-point-functions' integration for Minuet.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'minuet)

(cl-defstruct (minuet--capf-state
               (:constructor minuet--capf-state-create)
               (:copier nil))
  "State of one `minuet-completion-at-point' session."
  buffer
  context
  complete-fn
  candidates
  started
  status)

(defvar-local minuet--capf-session nil
  "Current `minuet-completion-at-point' session in this buffer.")

(defun minuet--capf-normalize-candidates (items)
  "Normalize completion ITEMS for CAPF."
  (setq items (if minuet-add-single-line-entry
                  (minuet--add-single-line-entry items)
                items))
  (seq-uniq items))

(defun minuet--capf-live-request-p ()
  "Return non-nil when a Minuet request process is still running."
  (cl-some #'process-live-p minuet--current-requests))

(defun minuet--capf-request-deadline ()
  "Return the current CAPF request deadline as a float timestamp."
  (+ (float-time)
     (max 0 (or minuet-request-timeout 0))
     0.25))

(defun minuet--capf-cancel-session (state)
  "Cancel STATE and all active Minuet requests in the current buffer."
  (when state
    (setf (minuet--capf-state-status state) 'canceled))
  (minuet--cancel-requests))

(defun minuet--capf-flush-session ()
  "Flush the current Minuet CAPF session."
  (let ((state minuet--capf-session))
    (setq minuet--capf-session nil)
    (minuet--capf-cancel-session state))
  (remove-hook 'completion-in-region-mode-hook
               #'minuet--capf-maybe-flush-session t))
  ;; (remove-hook 'company-after-completion-hook
  ;;              #'minuet--capf-flush-session t))

(defun minuet--capf-maybe-flush-session ()
  "Flush the current CAPF session when completion-in-region ends."
  (unless (bound-and-true-p completion-in-region-mode)
    (minuet--capf-flush-session)))

(defun minuet--capf-install-flush-hooks ()
  "Install hooks that flush the current CAPF session."
  (add-hook 'completion-in-region-mode-hook
            #'minuet--capf-maybe-flush-session nil t)
  (add-hook 'company-after-completion-hook
            #'minuet--capf-flush-session nil t))

(defun minuet--capf-handle-items (state items)
  "Update STATE with completion ITEMS if STATE is still current."
  (let ((buffer (minuet--capf-state-buffer state)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (eq minuet--capf-session state)
                   (eq (minuet--capf-state-status state) 'pending))
          (setf (minuet--capf-state-candidates state)
                (minuet--capf-normalize-candidates items)))))))

(defun minuet--capf-start-session (state)
  "Start completion requests for STATE."
  (unless (minuet--capf-state-started state)
    (setf (minuet--capf-state-started state) t)
    (setf (minuet--capf-state-status state) 'pending)
    (minuet--cancel-requests)
    (condition-case err
        (funcall (minuet--capf-state-complete-fn state)
                 (minuet--capf-state-context state)
                 (lambda (items)
                   (minuet--capf-handle-items state items)))
      (error
       (minuet--log (format "Minuet CAPF request failed: %s" err)
                    minuet-show-error-message-on-minibuffer)
       (setf (minuet--capf-state-status state) 'done)))))

(defun minuet--capf-wait-for-candidates (state)
  "Wait for completion candidates from STATE and return them."
  (minuet--capf-start-session state)
  (when (eq (minuet--capf-state-status state) 'pending)
    (let ((deadline (minuet--capf-request-deadline)))
      (while (and (eq minuet--capf-session state)
                  (eq (minuet--capf-state-status state) 'pending)
                  (minuet--capf-live-request-p)
                  (not (input-pending-p))
                  (< (float-time) deadline))
        (accept-process-output nil 0.05))
      (when (and (eq minuet--capf-session state)
                 (eq (minuet--capf-state-status state) 'pending))
        (setf (minuet--capf-state-status state) 'done)
        (when (or (input-pending-p)
                  (minuet--capf-live-request-p))
          (minuet--cancel-requests)))))
  (when (and (eq minuet--capf-session state)
             (not (eq (minuet--capf-state-status state) 'canceled)))
    (minuet--capf-state-candidates state)))

(defun minuet--capf-table (state string pred action)
  "Completion table for STATE with STRING, PRED, and ACTION."
  (pcase action
    ('metadata
     '(metadata (category . minuet-capf)))
    ('boundaries nil)
    (_
     (complete-with-action
      action
      (minuet--capf-wait-for-candidates state)
      string
      pred))))

(defun minuet--capf-exit-function (state _string status)
  "Flush STATE when completion STATUS is finished or exact."
  (when (memq status '(finished exact))
    (let ((buffer (minuet--capf-state-buffer state)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq minuet--capf-session state)
            (minuet--capf-flush-session)))))))

;;;###autoload
(defun minuet-completion-at-point ()
  "Return a Minuet completion table for `completion-at-point-functions'."
  (minuet--cleanup-suggestion)
  (minuet--capf-flush-session)
  (let ((available-p-fn (intern (format "minuet--%s-available-p" minuet-provider)))
        (complete-fn (intern (format "minuet--%s-complete" minuet-provider))))
    (when (funcall available-p-fn)
      (let* ((state (minuet--capf-state-create
                     :buffer (current-buffer)
                     :context (minuet--get-context)
                     :complete-fn complete-fn
                     :status 'pending))
             (point (point)))
        (setq minuet--capf-session state)
        (minuet--capf-install-flush-hooks)
        (list point point
              (lambda (string pred action)
                (minuet--capf-table state string pred action))
              :exclusive 'no
              :exit-function
              (lambda (string status)
                (minuet--capf-exit-function state string status)))))))

(provide 'minuet-capf)
;;; minuet-capf.el ends here
