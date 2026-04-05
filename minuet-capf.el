;;; minuet-capf.el --- CAPF integration for Minuet -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; This file is part of GNU Emacs

;;; Commentary:

;; `completion-at-point-functions' integration for Minuet.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'minuet)

(defcustom minuet-capf-debounce-delay 0.25
  "Idle debounce delay in seconds before sending a Minuet CAPF request."
  :type 'number
  :group 'minuet)

(defcustom minuet-capf-throttle-delay 0.8
  "Minimum interval in seconds between two Minuet CAPF requests."
  :type 'number
  :group 'minuet)

(cl-defstruct (mineut-capf--state
               (:constructor mineut-capf--state-create)
               (:copier nil))
  "State of one `minuet-completion-at-point' session."
  buffer
  request-point
  point
  key
  context
  complete-fn
  candidates
  status)

(defvar-local mineut-capf--session nil
  "Current `minuet-completion-at-point' session in this buffer.")

(defvar-local mineut-capf--cache (make-hash-table :test #'eql)
  "Buffer-local completion cache keyed by point.")

(defvar-local mineut-capf--debounce-timer nil
  "Pending debounce/throttle timer for a Minuet CAPF request.")

(defvar-local mineut-capf--last-request-time nil
  "Timestamp of the last Minuet CAPF request sent in this buffer.")

(defun mineut-capf--cache-key ()
  "Return the current cache key."
  (point))

(defun mineut-capf--ensure-cache ()
  "Ensure the current buffer owns its own completion cache."
  (unless (local-variable-p 'mineut-capf--cache (current-buffer))
    (setq-local mineut-capf--cache (make-hash-table :test #'eql)))
  mineut-capf--cache)

(defun mineut-capf--cached-candidates (key)
  "Return cached candidates for KEY."
  (gethash key (mineut-capf--ensure-cache)))

(defun mineut-capf--store-cache (key candidates)
  "Store CANDIDATES in cache under KEY."
  (puthash key candidates (mineut-capf--ensure-cache)))

(defun mineut-capf--normalize-candidates (items)
  "Normalize completion ITEMS for CAPF."
  (setq items (if minuet-add-single-line-entry
                  (minuet--add-single-line-entry items)
                items))
  (seq-uniq items))

(defun mineut-capf--live-request-p ()
  "Return non-nil when a Minuet request process is still running."
  (cl-some #'process-live-p minuet--current-requests))

(defun mineut-capf--cancel-debounce-timer ()
  "Cancel the pending debounce/throttle timer."
  (when mineut-capf--debounce-timer
    (cancel-timer mineut-capf--debounce-timer)
    (setq mineut-capf--debounce-timer nil)))

(defun mineut-capf--cancel-session (state)
  "Cancel STATE and all active Minuet requests in the current buffer."
  (mineut-capf--cancel-debounce-timer)
  (when state
    (setf (mineut-capf--state-status state) 'canceled))
  (minuet--cancel-requests))

(defun mineut-capf--flush-session ()
  "Flush the current Minuet CAPF session."
  (let ((state mineut-capf--session))
    (setq mineut-capf--session nil)
    (mineut-capf--cancel-session state))
  (remove-hook 'completion-in-region-mode-hook
               #'mineut-capf--maybe-flush-session t)
  (remove-hook 'company-after-completion-hook
               #'mineut-capf--flush-session-hook t))

(defun mineut-capf--flush-session-hook (&rest _)
  "Flush the current Minuet CAPF session from a hook callback."
  (mineut-capf--flush-session))

(defun mineut-capf--maybe-flush-session ()
  "Flush the current CAPF session when completion-in-region ends."
  (unless (bound-and-true-p completion-in-region-mode)
    (mineut-capf--flush-session)))

(defun mineut-capf--install-flush-hooks ()
  "Install hooks that flush the current CAPF session."
  (add-hook 'completion-in-region-mode-hook
            #'mineut-capf--maybe-flush-session nil t)
  (add-hook 'company-after-completion-hook
            #'mineut-capf--flush-session-hook nil t))

(defun mineut-capf--company-capf-backend-p ()
  "Return non-nil when Company is currently using `company-capf'."
  (let ((backend (bound-and-true-p company-backend)))
    (or (eq backend 'company-capf)
        (and (consp backend)
             (memq 'company-capf backend)))))

(defun mineut-capf--frontend-visible-p ()
  "Return non-nil when a completion frontend popup is active."
  (or (and (bound-and-true-p completion-in-region-mode)
           (or (not (boundp 'corfu-mode))
               (bound-and-true-p corfu-mode)))
      (and (fboundp 'company--active-p)
           (company--active-p)
           (mineut-capf--company-capf-backend-p))))

(defun mineut-capf--refresh-frontends ()
  "Refresh Corfu/Company popups if one is active."
  (when (and (bound-and-true-p completion-in-region-mode)
             (or (not (boundp 'corfu-mode))
                 (bound-and-true-p corfu-mode)))
    (cond
     ((fboundp 'corfu--update)
      (ignore-errors
        (corfu--update)
        (when (fboundp 'corfu--exhibit)
          (corfu--exhibit))))
     ((fboundp 'corfu--exhibit)
      (ignore-errors
        (corfu--exhibit)))))
  (when (and (fboundp 'company--active-p)
             (company--active-p)
             (mineut-capf--company-capf-backend-p)
             (fboundp 'company--perform))
    (let ((non-essential nil))
      (ignore-errors
        (company--perform)))))

(defun mineut-capf--adapt-candidates-to-point (state items)
  "Adapt completion ITEMS from STATE to the current point.
Return a cons cell (KEY . CANDIDATES), or nil when ITEMS are stale."
  (let* ((start (mineut-capf--state-request-point state))
         (key (point)))
    (when (>= key start)
      (let ((typed (buffer-substring-no-properties start key)))
        (if (string-empty-p typed)
            (cons key items)
          (let ((trimmed
                 (delq nil
                       (mapcar (lambda (item)
                                 (when (string-prefix-p typed item)
                                   (substring item (length typed))))
                               items))))
            (when trimmed
              (cons key trimmed))))))))

(defun mineut-capf--commit-candidates (state items)
  "Commit completion ITEMS to STATE if STATE is still current."
  (let ((buffer (mineut-capf--state-buffer state)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (eq mineut-capf--session state)
                   (eq (mineut-capf--state-status state) 'pending))
          (when-let* ((entry (mineut-capf--adapt-candidates-to-point state items)))
            (let ((key (car entry))
                  (candidates (mineut-capf--normalize-candidates (cdr entry))))
              (setf (mineut-capf--state-point state) key)
              (setf (mineut-capf--state-key state) key)
              (setf (mineut-capf--state-candidates state) candidates)
              (mineut-capf--store-cache key candidates)
              (when (mineut-capf--frontend-visible-p)
                (mineut-capf--refresh-frontends))))
          (unless (mineut-capf--live-request-p)
            (setf (mineut-capf--state-status state) 'done)))))))

(defun mineut-capf--request-wait-time ()
  "Return how many seconds to wait for throttle, or nil if no wait is needed."
  (when (and mineut-capf--last-request-time
             (> minuet-capf-throttle-delay 0))
    (let ((wait (- (+ mineut-capf--last-request-time
                      minuet-capf-throttle-delay)
                   (float-time))))
      (when (> wait 0)
        wait))))

(defun mineut-capf--start-request (state)
  "Start the completion request for STATE."
  (when (and (eq mineut-capf--session state)
             (eq (mineut-capf--state-status state) 'scheduled))
    (if-let* ((wait (mineut-capf--request-wait-time)))
        (setq mineut-capf--debounce-timer
              (run-with-timer wait nil
                              #'mineut-capf--dispatch-request
                              (current-buffer)
                              state))
      (setq mineut-capf--debounce-timer nil)
      (setf (mineut-capf--state-status state) 'pending)
      (setq mineut-capf--last-request-time (float-time))
      (minuet--cancel-requests)
      (condition-case err
          (funcall (mineut-capf--state-complete-fn state)
                   (mineut-capf--state-context state)
                   (lambda (items)
                     (mineut-capf--commit-candidates state items)))
        (error
         (minuet--log (format "Minuet CAPF request failed: %s" err)
                      minuet-show-error-message-on-minibuffer)
         (setf (mineut-capf--state-status state) 'done))))))

(defun mineut-capf--dispatch-request (buffer state)
  "Dispatch a debounced/throttled completion request for BUFFER and STATE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq mineut-capf--session state)
        (mineut-capf--start-request state)))))

(defun mineut-capf--schedule-request (state)
  "Schedule a background completion request for STATE."
  (when (eq (mineut-capf--state-status state) 'idle)
    (setf (mineut-capf--state-status state) 'scheduled)
    (mineut-capf--cancel-debounce-timer)
    (setq mineut-capf--debounce-timer
          (run-with-idle-timer
           (max 0 minuet-capf-debounce-delay)
           nil
           #'mineut-capf--dispatch-request
           (current-buffer)
           state))))

(defun mineut-capf--table (state string pred action)
  "Completion table for STATE with STRING, PRED, and ACTION."
  (pcase action
    ('metadata
     '(metadata (category . minuet-capf)))
    ('boundaries nil)
    (_
     (let* ((key (mineut-capf--cache-key))
            (candidates (or (mineut-capf--cached-candidates key)
                            (and (eq (mineut-capf--state-key state) key)
                                 (mineut-capf--state-candidates state)))))
       (unless candidates
         (mineut-capf--schedule-request state))
       (complete-with-action action candidates string pred)))))

(defun mineut-capf--exit-function (state _string status)
  "Flush STATE when completion STATUS is finished or exact."
  (when (memq status '(finished exact))
    (let ((buffer (mineut-capf--state-buffer state)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq mineut-capf--session state)
            (mineut-capf--flush-session)))))))

(defun mineut-capf--create-session (point complete-fn)
  "Create a new CAPF session at POINT using COMPLETE-FN."
  (mineut-capf--state-create
   :buffer (current-buffer)
   :request-point point
   :point point
   :key point
   :context (minuet--get-context)
   :complete-fn complete-fn
   :status 'idle))

(defun mineut-capf--ensure-session (point complete-fn)
  "Return the current session for POINT and COMPLETE-FN, creating one if needed."
  (unless (and mineut-capf--session
               (= (mineut-capf--state-point mineut-capf--session) point)
               (eq (mineut-capf--state-complete-fn mineut-capf--session)
                   complete-fn)
               (memq (mineut-capf--state-status mineut-capf--session)
                     '(idle scheduled pending done)))
    (mineut-capf--flush-session)
    (mineut-capf--ensure-cache)
    (setq mineut-capf--session
          (mineut-capf--create-session point complete-fn))
    (mineut-capf--install-flush-hooks))
  mineut-capf--session)

;;;###autoload
(defun minuet-completion-at-point ()
  "Return a Minuet completion table for `completion-at-point-functions'."
  (minuet--cleanup-suggestion t)
  (let ((available-p-fn (intern (format "minuet--%s-available-p" minuet-provider)))
        (complete-fn (intern (format "minuet--%s-complete" minuet-provider))))
    (if (not (funcall available-p-fn))
        (mineut-capf--flush-session)
      (let* ((point (point))
             (state (mineut-capf--ensure-session point complete-fn)))
        (list point point
              (lambda (string pred action)
                (mineut-capf--table state string pred action))
              :exclusive 'no
              :exit-function
              (lambda (string status)
                (mineut-capf--exit-function state string status)))))))

(provide 'minuet-capf)
;;; minuet-capf.el ends here
