;;; show-wspace.el --- Highlight whitespace.
;;
;; Filename: show-wspace.el
;; Description: Highlight whitespace.
;; Author: Peter Steiner <unistein@isbe.ch>, Drew Adams
;; Maintainer: Drew Adams
;; Copyright (C) 2000-2005, Drew Adams, all rights reserved.
;; Created: Wed Jun 21 08:54:53 2000
;; Version: 21.0
;; Last-Updated: Mon Jul 04 10:45:22 2005
;;           By: dradams
;;     Update #: 153
;; Keywords: highlight
;; Compatibility: GNU Emacs 20.x, GNU Emacs 21.x, GNU Emacs 22.x
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;;    Highlight whitespace.
;;
;; New user options (variables) defined here:
;;
;;    `highlight-hard-spaces-flag', `highlight-tabs-flag',
;;    `highlight-trailing-whitespace-flag', `pesche-hardspace-face',
;;    `pesche-space-face', `pesche-tab-face'.
;;
;; New functions defined here:
;;
;;    `highlight-hard-spaces', `highlight-tabs',
;;    `highlight-trailing-whitespace', `toggle-hardspace-font-lock',
;;    `toggle-tabs-font-lock', `toggle-trailing-whitespace-font-lock'.
;;
;; Drew Adams wrote the `toggle-*' commands and `*-p' variables.
;;
;; Peter Steiner wrote the original code that did the equivalent of
;; the `highlight-*' commands here in his `hilite-trail.el'.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Change log:
;;
;; 2005/01/25 dadams
;;     Renamed *-p to *-flag.
;;     Removed ###autoload for defvars.
;; 2004/06/10 dadams
;;     Fixed minor bug in highlight-* functions.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:


(and (< emacs-major-version 20) (eval-when-compile (require 'cl))) ;; when, push

;; Get macro `define-face-const' when this is compiled,
;; or run interpreted, but not when the compiled code is loaded.
(eval-when-compile (require 'def-face-const))

;;;;;;;;;;;;;;;;;;;;;;;;;



(unless (boundp 'lemonchiffon-background-face)
  (define-face-const nil "LemonChiffon"))
(unless (boundp 'gold-background-face)
  (define-face-const nil "Gold"))
(unless (boundp 'palegreen-background-face)
  (define-face-const nil "PaleGreen"))

(defvar pesche-tab-face lemonchiffon-background-face
  "*Face for highlighting tab characters (`C-i') in Font-Lock mode.")

(defvar pesche-space-face gold-background-face
  "*Face for highlighting whitespace at line ends in Font-Lock mode.")

(defvar pesche-hardspace-face palegreen-background-face
  "*Face for highlighting hard spaces (`\040')in Font-Lock mode.")

(defvar highlight-tabs-flag nil
  "*Non-nil means font-Lock mode highlights TABs (`C-i').")
(defvar highlight-trailing-whitespace-flag nil
  "*Non-nil means font-Lock mode highlights whitespace at line ends.")
(defvar highlight-hard-spaces-flag nil
  "*Non-nil means font-Lock mode highlights hard spaces (`\040').")

(defun highlight-tabs ()
  "Highlight tab characters (`C-i')."
  (setq font-lock-keywords
        (append font-lock-keywords '(("[\t]+" (0 pesche-tab-face t))))))
(defun highlight-hard-spaces ()
  "Highlight hard-space characters (`\040')."
  (setq font-lock-keywords
        (append font-lock-keywords '(("[\240]+" (0 pesche-hardspace-face t))))))
(defun highlight-trailing-whitespace ()
  "Highlight whitespace characters at line ends."
  (setq font-lock-keywords
        (append font-lock-keywords '(("[\040\t]+$" (0 pesche-space-face t))))))

;;;###autoload
(defun toggle-tabs-font-lock ()
  "Toggle highlighting of TABs, using face `pesche-tab-face'."
  (interactive)
  (if highlight-tabs-flag
      (remove-hook 'font-lock-mode-hook 'highlight-tabs)
    (add-hook 'font-lock-mode-hook 'highlight-tabs))
  (setq highlight-tabs-flag (not highlight-tabs-flag))
  (font-lock-mode)(font-lock-mode)
  (message "TAB highlighting is now %s." (if highlight-tabs-flag "ON" "OFF")))

;;;###autoload
(defun toggle-hardspace-font-lock ()
  "Toggle highlighting of hard SPACE characters.
Uses face `pesche-hardspace-face'."
  (interactive)
  (if highlight-hard-spaces-flag
      (remove-hook 'font-lock-mode-hook 'highlight-hard-spaces)
    (add-hook 'font-lock-mode-hook 'highlight-hard-spaces))
  (setq highlight-hard-spaces-flag (not highlight-hard-spaces-flag))
  (font-lock-mode)(font-lock-mode)
  (message "Hard space highlighting is now %s."
           (if highlight-hard-spaces-flag "ON" "OFF")))

;;;###autoload
(defun toggle-trailing-whitespace-font-lock ()
  "Toggle highlighting of trailing whitespace.
Uses face `pesche-space-face'."
  (interactive)
  (if highlight-trailing-whitespace-flag
      (remove-hook 'font-lock-mode-hook 'highlight-trailing-whitespace)
    (add-hook 'font-lock-mode-hook 'highlight-trailing-whitespace))
  (setq highlight-trailing-whitespace-flag (not highlight-trailing-whitespace-flag))
  (font-lock-mode)(font-lock-mode)
  (message "Trailing whitespace highlighting is now %s."
           (if highlight-trailing-whitespace-flag "ON" "OFF")))


;;;;;;;;;;;;;;;;;;;;;;;

(provide 'show-wspace)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; show-wspace.el ends here
