; -*- emacs-lisp -*-
;; =======================================================
;; $Id: .emacs,v 1.2 2005/06/02 22:45:28 tak Exp $
;;; Emacs config
;; =======================================================

(setq user-init-file (expand-file-name "init.el" (expand-file-name ".emacs.d" "~")))
(setq custom-file (expand-file-name "custom.el" (expand-file-name ".emacs.d" "~")))

(load-file user-init-file)
(load-file custom-file)

; gentoo broken?
; (load "/usr/share/emacs/site-lisp/site-gentoo")

