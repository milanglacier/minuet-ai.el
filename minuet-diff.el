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

(defun minuet-diff--lcs-length-table (a b)
  "Compute LCS length table for sequences A and B.
Returns a 2D vector of size (len-a+1) x (len-b+1)."
  (let* ((la (length a))
         (lb (length b))
         (dp (make-vector (1+ la) nil)))
    (dotimes (i (1+ la))
      (aset dp i (make-vector (1+ lb) 0)))
    (dotimes (i la)
      (dotimes (j lb)
        (aset (aref dp (1+ i)) (1+ j)
              (if (equal (nth i a) (nth j b))
                  (1+ (aref (aref dp i) j))
                (max (aref (aref dp i) (1+ j))
                     (aref (aref dp (1+ i)) j))))))
    dp))

(defun minuet-diff--backtrack (dp a b)
  "Backtrack through DP table to produce edit operations for A and B.
Returns a list of (:type :a-idx :b-idx) plists in forward order.
:type is one of `equal', `delete', `insert'."
  (let ((i (length a))
        (j (length b))
        ops)
    (while (or (> i 0) (> j 0))
      (cond
       ((and (> i 0) (> j 0)
             (equal (nth (1- i) a) (nth (1- j) b)))
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

(defun minuet-diff-line-hunks (original proposed)
  "Compute line-level diff hunks between ORIGINAL and PROPOSED.
ORIGINAL and PROPOSED are lists of strings (lines).
Returns a list of hunks, each a plist with keys:
  :original-start  - 1-based start index in ORIGINAL
  :original-count  - number of lines from ORIGINAL
  :proposed-start  - 1-based start index in PROPOSED
  :proposed-count  - number of lines from PROPOSED

A hunk with :original-count 0 is a pure insertion.
A hunk with :proposed-count 0 is a pure deletion.
Otherwise it is a replacement."
  (let* ((dp (minuet-diff--lcs-length-table original proposed))
         (ops (minuet-diff--backtrack dp original proposed))
         hunks
         cur-del-start cur-del-count
         cur-ins-start cur-ins-count)
    (cl-flet ((flush ()
                     (when (or (and cur-del-count (> cur-del-count 0))
                               (and cur-ins-count (> cur-ins-count 0)))
                       (push (list :original-start (1+ (or cur-del-start 0))
                                   :original-count (or cur-del-count 0)
                                   :proposed-start (1+ (or cur-ins-start 0))
                                   :proposed-count (or cur-ins-count 0))
                             hunks))
                     (setq cur-del-start nil cur-del-count nil
                           cur-ins-start nil cur-ins-count nil)))
      (dolist (op ops)
        (let ((type (plist-get op :type)))
          (cond
           ((eq type 'equal)
            (flush))
           ((eq type 'delete)
            (let ((ai (plist-get op :a-idx)))
              (if cur-del-count
                  (cl-incf cur-del-count)
                (setq cur-del-start ai
                      cur-del-count 1))))
           ((eq type 'insert)
            (let ((bi (plist-get op :b-idx)))
              (if cur-ins-count
                  (cl-incf cur-ins-count)
                (setq cur-ins-start bi
                      cur-ins-count 1)))))))
      (flush))
    (nreverse hunks)))

(provide 'minuet-diff)
;;; minuet-diff.el ends here
