;;; minuet-diff.el --- Minimal line diff for minuet-duet -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

;; Author: Milan Glacier <dev@milanglacier.com>
;; Maintainer: Milan Glacier <dev@milanglacier.com>

;; This file is part of GNU Emacs

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;; Commentary:

;; Minimal LCS-based line diff used by minuet-duet preview rendering.
;; Exposes a single entry point `minuet-diff-line-hunks'.

;;; Code:

(require 'cl-lib)

(defun minuet-diff--as-vector (lines)
  "Return LINES as a vector."
  (if (vectorp lines)
      lines
    (vconcat lines)))

(defun minuet-diff--lcs-length-table (original proposed)
  "Compute the LCS length table for ORIGINAL and PROPOSED.
ORIGINAL and PROPOSED are vectors of lines.  Return a 2D vector of
size (len-original+1) x (len-proposed+1)."
  (let* ((la (length original))
         (lb (length proposed))
         (dp (make-vector (1+ la) nil)))
    (dotimes (i (1+ la))
      (aset dp i (make-vector (1+ lb) 0)))
    (dotimes (i la)
      (let ((row (aref dp i))
            (next-row (aref dp (1+ i)))
            (original-line (aref original i)))
        (dotimes (j lb)
          (aset next-row (1+ j)
                (if (equal original-line (aref proposed j))
                    (1+ (aref row j))
                  (max (aref row (1+ j))
                       (aref next-row j)))))))
    dp))

(defun minuet-diff--backtrack (dp original proposed)
  "Backtrack through DP to produce edit operations for ORIGINAL and PROPOSED.
Returns a list of (:type :a-idx :b-idx) plists in forward order.
:type is one of `equal', `delete', `insert'."
  (let ((i (length original))
        (j (length proposed))
        ops)
    (while (or (> i 0) (> j 0))
      (cond
       ((and (> i 0) (> j 0)
             (equal (aref original (1- i)) (aref proposed (1- j))))
        (push (list :type 'equal :a-idx (1- i) :b-idx (1- j)) ops)
        (cl-decf i)
        (cl-decf j))
       ((and (> j 0)
             (or (= i 0)
                 (> (aref (aref dp i) (1- j))
                    (aref (aref dp (1- i)) j))))
        (push (list :type 'insert :b-idx (1- j)) ops)
        (cl-decf j))
       (t
        (push (list :type 'delete :a-idx (1- i)) ops)
        (cl-decf i))))
    ops))

(defun minuet-diff--ops-to-hunks (ops)
  "Convert OPS into diff hunks.
Each returned hunk is a plist with `:original-start', `:original-count',
`:proposed-start', and `:proposed-count'.  Start positions are 0-based.

For pure insertions, `:original-start' is the insertion position in the
original sequence: 0 means before the first original line, and
`(length ORIGINAL)' means after the last original line."
  (let ((original-pos 0)
        (proposed-pos 0)
        hunks
        hunk-original-start
        hunk-proposed-start
        hunk-original-count
        hunk-proposed-count)
    (cl-labels
        ((start-hunk ()
                     (unless hunk-original-start
                       (setq hunk-original-start original-pos
                             hunk-proposed-start proposed-pos
                             hunk-original-count 0
                             hunk-proposed-count 0)))
         (flush-hunk ()
                     (when hunk-original-start
                       (push (list :original-start hunk-original-start
                                   :original-count hunk-original-count
                                   :proposed-start hunk-proposed-start
                                   :proposed-count hunk-proposed-count)
                             hunks)
                       (setq hunk-original-start nil
                             hunk-proposed-start nil
                             hunk-original-count nil
                             hunk-proposed-count nil))))
      (dolist (op ops)
        (pcase (plist-get op :type)
          ('equal
           (flush-hunk)
           (cl-incf original-pos)
           (cl-incf proposed-pos))
          ('delete
           (start-hunk)
           (cl-incf hunk-original-count)
           (cl-incf original-pos))
          ('insert
           (start-hunk)
           (cl-incf hunk-proposed-count)
           (cl-incf proposed-pos))))
      (flush-hunk))
    (nreverse hunks)))

(defun minuet-diff-line-hunks (original proposed)
  "Compute line-level diff hunks between ORIGINAL and PROPOSED.
ORIGINAL and PROPOSED are lists of strings (lines).
Returns a list of hunks, each a plist with keys:
  :original-start  - 0-based start index in ORIGINAL
  :original-count  - number of lines from ORIGINAL
  :proposed-start  - 0-based start index in PROPOSED
  :proposed-count  - number of lines from PROPOSED

A hunk with :original-count 0 is a pure insertion.  In that case
`:original-start' is the insertion position in ORIGINAL, where 0 means
before the first line and `(length ORIGINAL)' means after the last.
A hunk with :proposed-count 0 is a pure deletion.
Otherwise it is a replacement."
  (let* ((original (minuet-diff--as-vector original))
         (proposed (minuet-diff--as-vector proposed))
         (dp (minuet-diff--lcs-length-table original proposed))
         (ops (minuet-diff--backtrack dp original proposed)))
    (minuet-diff--ops-to-hunks ops)))

(provide 'minuet-diff)
;;; minuet-diff.el ends here
