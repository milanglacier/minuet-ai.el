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

(cl-defstruct (minuet-capf--state
               (:constructor minuet-capf--state-create)
               (:copier nil))
  "State of one `minuet-completion-at-point' session."
  buffer
  request-point
  point
  context
  complete-fn
  candidates
  status)

(cl-defstruct (minuet-capf--cache-entry
               (:constructor minuet-capf--cache-entry-create)
               (:copier nil))
  "Cached completion candidates anchored at a request point."
  anchor
  candidates)

(defvar-local minuet-capf--session nil
  "Current `minuet-completion-at-point' session in this buffer.")

(defconst minuet-capf--max-cache-size 8
  "Maximum number of cached async completion entries per buffer.")

(defvar-local minuet-capf--cache nil
  "Buffer-local completion cache of request-anchored entries.")

(defvar-local minuet-capf--debounce-timer nil
  "Pending debounce/throttle timer for a Minuet CAPF request.")

(defvar-local minuet-capf--last-request-time nil
  "Timestamp of the last Minuet CAPF request sent in this buffer.")

(defun minuet-capf--ensure-cache ()
  "Ensure the current buffer owns its own completion cache."
  (unless (local-variable-p 'minuet-capf--cache (current-buffer))
    (setq-local minuet-capf--cache nil))
  minuet-capf--cache)

(defun minuet-capf--store-cache (anchor candidates)
  "Store CANDIDATES in cache anchored at ANCHOR."
  (setq minuet-capf--cache
        (seq-take
         (cons (minuet-capf--cache-entry-create
                :anchor anchor
                :candidates candidates)
               (minuet-capf--ensure-cache))
         minuet-capf--max-cache-size)))

(defun minuet-capf--normalize-candidates (items)
  "Normalize completion ITEMS for CAPF."
  (setq items (if minuet-add-single-line-entry
                  (minuet--add-single-line-entry items)
                items))
  (seq-uniq items))

(defun minuet-capf--live-request-p ()
  "Return non-nil when a Minuet request process is still running."
  (cl-some #'process-live-p minuet--current-requests))

(defun minuet-capf--cancel-debounce-timer ()
  "Cancel the pending debounce/throttle timer."
  (when minuet-capf--debounce-timer
    (cancel-timer minuet-capf--debounce-timer)
    (setq minuet-capf--debounce-timer nil)))

(defun minuet-capf--cancel-session (state)
  "Cancel STATE and all active Minuet requests in the current buffer."
  (minuet-capf--cancel-debounce-timer)
  (when state
    (setf (minuet-capf--state-status state) 'canceled))
  (minuet--cancel-requests))

(defun minuet-capf--flush-session ()
  "Flush the current Minuet CAPF session."
  (let ((state minuet-capf--session))
    (setq minuet-capf--session nil)
    (minuet-capf--cancel-session state))
  (remove-hook 'completion-in-region-mode-hook
               #'minuet-capf--maybe-flush-session t)
  (remove-hook 'company-after-completion-hook
               #'minuet-capf--flush-session-hook t))

(defun minuet-capf--flush-session-hook (&rest _)
  "Flush the current Minuet CAPF session from a hook callback."
  (minuet-capf--flush-session))

(defun minuet-capf--maybe-flush-session ()
  "Flush the current CAPF session when completion-in-region ends."
  (unless (bound-and-true-p completion-in-region-mode)
    (minuet-capf--flush-session)))

(defun minuet-capf--install-flush-hooks ()
  "Install hooks that flush the current CAPF session."
  (add-hook 'completion-in-region-mode-hook
            #'minuet-capf--maybe-flush-session nil t)
  (add-hook 'company-after-completion-hook
            #'minuet-capf--flush-session-hook nil t))

(defun minuet-capf--company-capf-backend-p ()
  "Return non-nil when Company is currently using `company-capf'."
  (let ((backend (bound-and-true-p company-backend)))
    (or (eq backend 'company-capf)
        (and (consp backend)
             (memq 'company-capf backend)))))

(defun minuet-capf--frontend-visible-p ()
  "Return non-nil when a completion frontend popup is active."
  (or (and (bound-and-true-p completion-in-region-mode)
           (or (not (boundp 'corfu-mode))
               (bound-and-true-p corfu-mode)))
      (and (fboundp 'company--active-p)
           (company--active-p)
           (minuet-capf--company-capf-backend-p))))

(defun minuet-capf--refresh-frontends ()
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
             (minuet-capf--company-capf-backend-p)
             (fboundp 'company--perform))
    (let ((non-essential nil))
      (ignore-errors
        (company--perform)))))

(defun minuet-capf--match-candidates (start end items &optional trim)
  "Return ITEMS that still match text from START to END.
When TRIM is non-nil, return only the suffix after the typed prefix."
  (when (>= end start)
    (let ((typed (buffer-substring-no-properties start end)))
      (if (string-empty-p typed)
          items
        (let ((matched
               (delq nil
                     (mapcar
                      (lambda (item)
                        (when (string-prefix-p typed item)
                          (if trim
                              (substring item (length typed))
                            item)))
                      items))))
          (when matched
            matched))))))

(defun minuet-capf--cached-match (point)
  "Return the newest cached entry that matches POINT.
Invalidated cache entries are removed lazily during the lookup."
  (let (kept match)
    (dolist (entry (minuet-capf--ensure-cache))
      (when-let* ((candidates
                   (minuet-capf--match-candidates
                    (minuet-capf--cache-entry-anchor entry)
                    point
                    (minuet-capf--cache-entry-candidates entry))))
        (push entry kept)
        (unless match
          (setq match (cons entry candidates)))))
    (setq minuet-capf--cache (nreverse kept))
    match))

(defun minuet-capf--commit-candidates (state items)
  "Commit completion ITEMS to STATE if STATE is still current."
  (let ((buffer (minuet-capf--state-buffer state)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (eq minuet-capf--session state)
                   (eq (minuet-capf--state-status state) 'pending))
          (let* ((anchor (minuet-capf--state-request-point state))
                 (key (point))
                 (candidates (minuet-capf--normalize-candidates items))
                 (session-candidates
                  (minuet-capf--match-candidates anchor key candidates t)))
            (setf (minuet-capf--state-point state) key)
            (setf (minuet-capf--state-candidates state) session-candidates)
            (when candidates
              (minuet-capf--store-cache anchor candidates))
            (when (and session-candidates
                       (minuet-capf--frontend-visible-p))
              (minuet-capf--refresh-frontends)))
          (unless (minuet-capf--live-request-p)
            (setf (minuet-capf--state-status state) 'done)))))))

(defun minuet-capf--request-wait-time ()
  "Return how many seconds to wait for throttle, or nil if no wait is needed."
  (when (and minuet-capf--last-request-time
             (> minuet-capf-throttle-delay 0))
    (let ((wait (- (+ minuet-capf--last-request-time
                      minuet-capf-throttle-delay)
                   (float-time))))
      (when (> wait 0)
        wait))))

(defun minuet-capf--start-request (state)
  "Start the completion request for STATE."
  (when (and (eq minuet-capf--session state)
             (eq (minuet-capf--state-status state) 'scheduled))
    (if-let* ((wait (minuet-capf--request-wait-time)))
        (setq minuet-capf--debounce-timer
              (run-with-timer wait nil
                              #'minuet-capf--dispatch-request
                              (current-buffer)
                              state))
      (setq minuet-capf--debounce-timer nil)
      (setf (minuet-capf--state-status state) 'pending)
      (setq minuet-capf--last-request-time (float-time))
      (minuet--cancel-requests)
      (condition-case err
          (funcall (minuet-capf--state-complete-fn state)
                   (minuet-capf--state-context state)
                   (lambda (items)
                     (minuet-capf--commit-candidates state items)))
        (error
         (minuet--log (format "Minuet CAPF request failed: %s" err)
                      minuet-show-error-message-on-minibuffer)
         (setf (minuet-capf--state-status state) 'done))))))

(defun minuet-capf--dispatch-request (buffer state)
  "Dispatch a debounced/throttled completion request for BUFFER and STATE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq minuet-capf--session state)
        (minuet-capf--start-request state)))))

(defun minuet-capf--schedule-request (state)
  "Schedule a background completion request for STATE."
  (when (eq (minuet-capf--state-status state) 'idle)
    (setf (minuet-capf--state-status state) 'scheduled)
    (minuet-capf--cancel-debounce-timer)
    (setq minuet-capf--debounce-timer
          (run-with-idle-timer
           (max 0 minuet-capf-debounce-delay)
           nil
           #'minuet-capf--dispatch-request
           (current-buffer)
           state))))

(defun minuet-capf--table (state string pred action)
  "Completion table for STATE with STRING, PRED, and ACTION."
  (pcase action
    ('metadata
     '(metadata (category . minuet-capf)))
    ('boundaries nil)
    (_
     (let* ((key (point))
            (session-candidates
             (and (= (minuet-capf--state-point state) key)
                  (minuet-capf--state-candidates state)))
            (cache-match (and (not session-candidates)
                              (minuet-capf--cached-match key)))
            (candidates (or session-candidates
                            (cdr cache-match))))
       (unless candidates
         (minuet-capf--schedule-request state))
       (complete-with-action action candidates string pred)))))

(defun minuet-capf--exit-function (state _string status)
  "Flush STATE when completion STATUS is finished or exact."
  (when (memq status '(finished exact))
    (let ((buffer (minuet-capf--state-buffer state)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq minuet-capf--session state)
            (minuet-capf--flush-session)))))))

(defun minuet-capf--create-session (point complete-fn)
  "Create a new CAPF session at POINT using COMPLETE-FN."
  (minuet-capf--state-create
   :buffer (current-buffer)
   :request-point point
   :point point
   :context (minuet--get-context)
   :complete-fn complete-fn
   :status 'idle))

(defun minuet-capf--ensure-session (point complete-fn)
  "Return the current session for POINT and COMPLETE-FN, creating one if needed."
  (unless (and minuet-capf--session
               (= (minuet-capf--state-point minuet-capf--session) point)
               (eq (minuet-capf--state-complete-fn minuet-capf--session)
                   complete-fn)
               (memq (minuet-capf--state-status minuet-capf--session)
                     '(idle scheduled pending done)))
    (minuet-capf--flush-session)
    (minuet-capf--ensure-cache)
    (setq minuet-capf--session
          (minuet-capf--create-session point complete-fn))
    (minuet-capf--install-flush-hooks))
  minuet-capf--session)

;;;###autoload
(defun minuet-completion-at-point ()
  "Return a Minuet completion table for `completion-at-point-functions'."
  (minuet--cleanup-suggestion t)
  (let ((available-p-fn (intern (format "minuet--%s-available-p" minuet-provider)))
        (complete-fn (intern (format "minuet--%s-complete" minuet-provider))))
    (if (not (funcall available-p-fn))
        (minuet-capf--flush-session)
      (let* ((point (point))
             (state (minuet-capf--ensure-session point complete-fn))
             (cache-match (minuet-capf--cached-match point))
             (beg (if cache-match
                      (minuet-capf--cache-entry-anchor (car cache-match))
                    point)))
        (list beg point
              (lambda (string pred action)
                (minuet-capf--table state string pred action))
              :exclusive 'no
              :exit-function
              (lambda (string status)
                (minuet-capf--exit-function state string status)))))))

(provide 'minuet-capf)
;;; minuet-capf.el ends here
