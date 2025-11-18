; -*- emacs-lisp -*-

;; Are we running XEmacs or Emacs?
(defvar running-xemacs (string-match "XEmacs\\|Lucid" emacs-version))

;; Set up the keyboard so the delete key on both the regular keyboard
;; and the keypad delete the character under the cursor and to the right
;; under X, instead of the default, backspace behavior.
(global-set-key [delete] 'delete-char)
(global-set-key [kp-delete] 'delete-char)

;; Turn on font-lock mode for Emacs
(cond ((not running-xemacs)
	(global-font-lock-mode t)
))

;; Always end a file with a newline
(setq require-final-newline t)

;; Stop at the end of the file, not just add lines
(setq next-line-add-newlines nil)


(custom-set-variables
  ;; custom-set-variables was added by Custom.
  ;; If you edit it by hand, you could mess it up, so be careful.
  ;; Your init file should contain only one such instance.
  ;; If there is more than one, they won't work right.
 '(auto-compression-mode t nil (jka-compr))
 '(backup-by-copying t)
 '(backup-directory-alist (quote (("~/.backups/" . "."))))
 '(bookmark-default-file "~/.emacs.d/emacs.bmk")
 '(bookmark-save-flag 1)
 '(case-fold-search t)
 '(column-number-mode t)
 '(current-language-environment "English")
 '(delete-old-versions t)
 '(fill-column 77)
 '(global-font-lock-mode t nil (font-lock))
 '(global-hl-line-mode t nil (hl-line))
 '(indent-tabs-mode nil)
 '(line-number-mode t)
 '(make-backup-files t)
 '(nxml-attribute-indent 2)
 '(nxml-child-indent 2)
 '(nxml-syntax-highlight-flag t)
 '(paren-match-face (quote paren-face-match-light))
 '(paren-sexp-mode t)
 '(power-macros-file "/homes/tak/.emacs.d/power_macros.el")
 '(query-user-mail-address nil)
 '(rng-schema-locating-files (quote ("schemas.xml" "~/.emacs.d/schemas-nxml.xml" "~/.emacs.d/lisp/nxml-mode/schema/schemas.xml")))
 '(show-paren-mode t nil (paren))
 '(show-trailing-whitespace t)
 '(tidy-shell-command "/usr/local/bin/tidy")
 '(transient-mark-mode t)
 '(uniquify-buffer-name-style (quote forward) nil (uniquify))
 '(user-mail-address "tak@yahoo-inc.com")
 '(vc-display-status t)
 '(vc-handled-backends (quote (RCS SCCS CVS SVN)))
 '(vc-initial-comment t)
 '(vc-keep-workfiles nil)
 '(vc-make-backup-files nil)
 '(version-control nil)
 '(visible-bell t))

(custom-set-faces
  ;; custom-set-faces was added by Custom.
  ;; If you edit it by hand, you could mess it up, so be careful.
  ;; Your init file should contain only one such instance.
  ;; If there is more than one, they won't work right.
 )
