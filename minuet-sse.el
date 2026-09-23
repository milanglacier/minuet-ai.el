;;; minuet-sse.el --- Robust SSE decoding for Minuet -*- lexical-binding: t; -*-

;;; Commentary:

;; Some OpenAI-compatible servers emit multiple `data:' events on one line.
;; Minuet's original decoder assumed one event per line.  This override keeps
;; the normal newline-delimited SSE format while also accepting compact output.

;;; Code:

(require 'minuet)

(defun minuet-sse--stream-decode (response get-text-fn)
  "Decode RESPONSE's SSE data events using GET-TEXT-FN.
Empty successful completions and `[DONE]' are valid responses and do not
produce a stream-decoding error."
  (let ((events (split-string response
                             "[[:space:]]*data:[[:space:]]*"
                             t))
        result
        parsed-event)
    (dolist (event events)
      (unless (string= (string-trim event) "[DONE]")
        (when-let* ((json (ignore-errors
                            (json-parse-string
                             (string-trim event)
                             :object-type 'plist
                             :array-type 'list))))
          (setq parsed-event t)
          (when-let ((text (ignore-errors (funcall get-text-fn json))))
            (when (and (stringp text) (not (string-empty-p text)))
              (push text result))))))
    (setq result (apply #'concat (nreverse result)))
    (cond
     ((not (string-empty-p result)) result)
     (parsed-event nil)
     (t
      (minuet--log "Minuet: Stream decoding failed for response:"
                   minuet-show-error-message-on-minibuffer)
      (minuet--log response)
      nil))))

(advice-add 'minuet--stream-decode :override #'minuet-sse--stream-decode)

(provide 'minuet-sse)
;;; minuet-sse.el ends here
