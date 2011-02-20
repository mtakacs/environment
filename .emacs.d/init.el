; -*- emacs-lisp -*-
;; =======================================================
;;
;; Mark Takacs, Nov 2000
;; $Id: init.el,v 1.23 2008/07/08 21:43:50 tak Exp $
;; $Name:  $
;; $File$
;;
;; http://wttools.sourceforge.net/emacs-stuff/emacs.html
;; =======================================================

;; =======================================================
;; where to put stuff for XEmacs customize. Load it too
;; =======================================================

;;{{{ Loading

;;;; Macros ;;;;
;; Are we running XEmacs or Emacs?
(defvar running-xemacs (string-match "XEmacs\\|Lucid" emacs-version))

;; Some simple macros to more easily tell if we're running GNUEmacs or XEmacs
;; taken from the .emacs of sukria@online.fr | http://sukria.online.fr
(defmacro GNUEmacs (&rest x)
  (list 'if (not running-xemacs) (cons 'progn x)))
(defmacro XEmacs (&rest x)
  (list 'if running-xemacs (cons 'progn x)))
(defmacro Xlaunch (&rest x)
  (list 'if (eq window-system 'x) (cons 'progn x)))
;;;; /Macros ;;;;


;; =======================================================
;; LoadPath Init
;; I've stopped referencing other people's dirs
;; after being burned a few times at NSCP when people
;; left and their .el file went away, clobbering the hell
;; out of my editting environment
;; curio: /usr/lib/xemacs/xemacs-packages
;; =======================================================


;; Create faces for XEmacs
;(unless (boundp 'font-lock-keyword-face)
;  (copy-face 'bold 'font-lock-keyword-face))
;(unless (boundp 'font-lock-constant-face)
;  (copy-face 'font-lock-keyword-face 'font-lock-constant-face))
(setq load-path
      (append
       (list
        (expand-file-name "~/.emacs.d/lisp")
        (expand-file-name "~/.emacs.d/lisp/pmwiki-mode")
        (expand-file-name "~/.emacs.d/lisp/nxml-mode")
        (expand-file-name "/usr/local/share/emacs/site-lisp")
        (expand-file-name "/usr/share/emacs/site-lisp")
        )
       load-path))

;; Dont load xemacs stuff when we're running under emacs
(if (string-match "XEmacs" emacs-version)
    (setq load-path
          (append
           (list
            (expand-file-name "/usr/share/xemacs/lisp")
            (expand-file-name "/usr/lib/xemacs/xemacs-packages/lisp/prog-modes")
            )
           load-path)))

;;}}}

;; =======================================================
;; =======================================================
;; which-func-mode ( From gnu emacs FAQ ) If you set
;; which-func-mode-global via customize, which-func-mode will not turn
;; on automatically. You need to add the following to your startup
;; file BEFORE the call to custom-set-variables:
(which-func-mode 1)

;; =======================================================
;; Shut off annoying beep
;; =======================================================
;(set-message-beep 'silent)

;; =======================================================
;; do NOT add newlines if I cursor past last line in file
;; =======================================================
(setq next-line-add-newlines nil)

;; =======================================================
;; Emacs look n Feel
;; =======================================================

(global-font-lock-mode t) ;;; EMACS only, NOT Xemacs

;; Disable the toolbar-bar
;(tool-bar-mode nil)

;; Disable the menu-bar
;(menu-bar-mode -1)

;; Disable scroll bar
;(scroll-bar-mode -1)

;; Automatic opening of zipped files
;(auto-compression-mode 1)

;; C-x 4a pops open a changelog
(setq change-log-version-info-enabled 1)

;; =======================================================
;; Oh yeah.. any good emacs session has LOTS of
;; custom keymaps
;; =======================================================

;;{{{ keymaps:  Oh yeah

(global-unset-key "\C-c")     ;; Disable fill-region
(global-unset-key "\M-g")     ;; rebind later
(global-unset-key "\C-xf")    ;; Disable hateful set-fill-column
(global-unset-key "\C-x\C-n") ;; Disable hateful set-goal-column
(global-unset-key "\C-x\C-p") ;; Disable hateful mark-page bindings
;(global-unset-key "\C-x\C-c") ;; Disable hateful quit (save-buffers-kill-emacs)

(global-set-key "\C-x\C-f"  'find-file)
(global-set-key "\C-x\C-v"  'find-file-other-window)

;; Bind regex searches to META normal searches
(global-set-key "\M-s"      'search-forward-regexp)
(global-set-key "\M-r"      'search-backward-regexp)

(global-set-key "\C-x\C-d"  'delete-window)
(global-set-key "\C-xd"     'delete-window)
(global-set-key "\C-xz"     'enlarge-window)
(global-set-key "\C-x\C-z"  'shrink-window)
;;(global-set-key "\C-x3"     'split-window-vertically-3)
;;(global-set-key "\C-z"        'scroll-one-line-up)
(global-set-key "\M-z"      'scroll-one-line-down)
(global-set-key "\C-xn"     'goto-next-window)
(global-set-key "\C-xp"     'goto-previous-window)
(global-set-key "\C-\\"     'just-one-space)
(global-set-key "\M-h"      'backward-kill-word)
(global-set-key "\M-j"      "\M-q")
(global-set-key "\^O"       'my-open-line)
(global-set-key "\M-g"      'goto-line)
(global-set-key "\C-x\C-i"      'insert-file)
(global-set-key "\C-x\C-u"      'undo)

(global-set-key "\C-x\C-m"  nil)
;;(global-set-key "\C-xr"     nil)
;;(global-set-key "\C-x\C-r"  nil)

(global-set-key "\M-="      'count-region)
(global-set-key "\^X="      'what-cursor-position-and-line)
(global-set-key "\M-\C-w"   'compare-windows)

(global-set-key "\C-X\C-B"  'electric-buffer-list)

(global-set-key "\M-\\"      'comment-region)

(global-set-key [home] 'beginning-of-line)
(global-set-key [end] 'end-of-line)

(global-set-key [f3] 'shrink-window)
(global-set-key [f4] 'enlarge-window)
(global-set-key [f5] 'enlarge-window-horizontally)
(global-set-key [f6] 'shrink-window-horizontally)
(global-set-key [f7] 'other-window )

;; (global-set-key [f2] 'save-buffer)
;; (global-set-key [f3] 'find-file)
;; (global-set-key [f4] 'compile)
;; (global-set-key [f5] 'switch-to-buffer)
;; (global-set-key [f6] 'other-window)
;; (global-set-key [f7] 'gud-step)
;; (global-set-key [f8] 'split-window-vertically)
;; (global-set-key [f9] 'gud-cont)
;; (global-set-key [f10] 'tmm-menubar)
;; (global-set-key [f11] 'list-buffers)

;(global-set-key [f8] 'gud-next)
;(global-set-key [f12] 'split-window-vertically)
;(global-set-key [C-f1] 'man)
;(global-set-key [C-f2] 'make-frame)
;(global-set-key [C-f4] 'delete-window)
;(global-set-key [C-f3] 'my-kill-buffer)
;(global-set-key [C-f5] 'delete-other-windows)
;(global-set-key [C-f6] 'other-frame)
;(global-set-key [C-end] 'end-of-buffer)
;(global-set-key [C-home] 'beginning-of-buffer)

(global-set-key "\C-xf" 'set-fill-column)

;;}}}

;;;========================================
;; Some C indentation style variables
;; Set up how *I* like it, so there. -Tak
;;;========================================

;;{{{ tak-c-settings

;; Customizations for all of c-mode, c++-mode, and objc-mode
(defun my-c-mode-common-hook ()
  (c-set-style "GNU")
  ;; add my personal style and set it for the current buffer
  ;; we like DO NOT auto-newline
  ;; we like DO NOT like hungry-delete
  (setq c-auto-newline nil)              ; auto newline b4 & after {}
  (setq c-basic-offset 4)
  (setq c-indent-level 4)
  (setq c-tab-always-indent t)         ; tabs reformat or normal tab? t: TAB = indent
  (c-toggle-hungry-state -1)
  (c-toggle-auto-state -1)
  ;; keybindings for all supported languages.  We can put these in
  ;; c-mode-base-map because c-mode-map, c++-mode-map, objc-mode-map,
  ;; java-mode-map, and idl-mode-map inherit from it.
  (define-key c-mode-base-map "\C-m" 'newline-and-indent)
  (define-key c-mode-base-map ";" 'self-insert-command)
  (define-key c-mode-base-map "," 'self-insert-command)
  )

(add-hook 'c-mode-common-hook 'my-c-mode-common-hook)

;;}}}

;; =======================================================
;; CEDET
;; http://cedet.sourceforge.net/
;; =======================================================

;(setq semantic-load-turn-useful-things-on t)
;(load-file (expand-file-name "~/.emacs.d/lisp/cedet/common/cedet.el"))

;; =======================================================
;; Good stuff for Java mode
;; =======================================================

;;{{{ java mode settings

;;; Load all JDEE related libraries
;;; JDEE, documentation and file are located at:
;;; http://jdee.sunsite.dk/
;;; To speed-up installation for JDEE beginners use:
;;; http://wttools.sourceforge.net/emacs-stuff/package.html#install-jdee

;(add-to-list 'load-path "~/.emacs.d/lisp/elib")
;(add-to-list 'load-path "~/.emacs.d/lisp/cedet/eieio")
;(add-to-list 'load-path "~/.emacs.d/lisp/cedet/semantic")
;(add-to-list 'load-path "~/.emacs.d/lisp/cedet/speedbar")
;(add-to-list 'load-path "~/.emacs.d/lisp/jde/lisp")
;(require 'jde)


;; If you want Emacs to defer loading the JDE until you open a
;; Java file, edit the following line
;(setq defer-loading-jde nil)

;(if defer-loading-jde
;    (progn
;      (autoload 'jde-mode "jde" "JDE mode." t))
;  (require 'jde))

;; Sets the basic indentation for Java source files
;; to two spaces.
;(defun my-jde-mode-hook ()
;  (setq c-basic-offset 4))

;(add-hook 'jde-mode-hook 'my-jde-mode-hook)

;;; Some more customization for JDEE
;; (defun my-jde-mode-hook ()
;;   "Hook for running Java file..."
;;   (message "Loading my-java-hook...")
;;   (define-key c-mode-base-map "\C-ca" 'jde-javadoc-generate-javadoc-template)
;;   (define-key c-mode-base-map "\C-m" 'newline-and-indent)
;;   (c-set-offset 'substatement-open 0)
;;   (c-set-offset 'statement-case-open 0)
;;   (c-set-offset 'case-label '+)
;;   (fset 'my-javadoc-code
;;         [?< ?c ?o ?d ?e ?>?< ?/ ?c ?o ?d ?e ?> left left left left left left left])
;;   (define-key c-mode-base-map "\C-cx" 'my-javadoc-code)
;;   (abbrev-mode t)
;;   (setq c-comment-continuation-stars "* "
;;         tab-width 4
;;         indent-tabs-mode nil
;;         tempo-interactive t
;;         c-basic-offset 4)
;;   (message "my-jde-mode-hook function executed")
;; )
;; (add-hook 'jde-mode-hook 'my-jde-mode-hook)

;;}}}

;; =======================================================
;; ECB
;;  http://ecb.sourceforge.net/
;; =======================================================

;(add-to-list 'load-path "~/.emacs.d/lisp/ecb")
;(require 'ecb)
;(require 'ecb-autoloads)


;; =======================================================
;; Generic-x mode
;; =======================================================

(require 'generic-x)

;; =======================================================
;; Wiki mode, Twiki
;; =======================================================
;(require 'pmwiki-mode)

;(defvar pmwiki-mode-hooks)
;;
;; If your auto-fill-mode is usually on, you might want to turn it off:
;;
;(add-hook 'pmwiki-mode-hooks 'turn-off-auto-fill)

;; =======================================================
;; Power Macros
;; http://www.blackie.dk/emacs/
;; =======================================================
;(require 'power-macros)
;(load-file (expand-file-name "~/.emacs.d/power_macros.el"))

;; =======================================================
;; Load whitespace.el library. Nukes trailing whitespace from the ends
;; of lines, and deletes excess newlines from the ends of buffers,
;; every time you save.
;; Author: Noah Friedman <friedman@splode.com>
;; =======================================================
(load "whitespace")

;; =======================================================
;; inline Line Numbering
;; =======================================================
;;{{{ setnu and setnu+ settings

;(load "setnu")
;(load "setnu+")

;; problems with indenting?
;; ugly ____11___ format as well and no font-face support?
;; (add-hook 'LaTeX-mode        'turn-on-setnu-mode)
;; (add-hook 'bibtex-mode       'turn-on-setnu-mode)
;; (add-hook 'c++-mode          'turn-on-setnu-mode)
;; (add-hook 'c++-mode          'turn-on-setnu-mode)
;; (add-hook 'c-mode            'turn-on-setnu-mode)
;; (add-hook 'changelog-mode    'turn-on-setnu-mode)
;; (add-hook 'css-mode          'turn-on-setnu-mode)
;; (add-hook 'emacs-lisp-mode   'turn-on-setnu-mode)
;; (add-hook 'html-mode         'turn-on-setnu-mode)
;; (add-hook 'java-mode         'turn-on-setnu-mode)
;; (add-hook 'javascript-mode   'turn-on-setnu-mode)
;; (add-hook 'jde-mode          'turn-on-setnu-mode)
;; (add-hook 'lisp-mode         'turn-on-setnu-mode)
;; (add-hook 'perl-mode         'turn-on-setnu-mode)
;; (add-hook 'php-mode          'turn-on-setnu-mode)
;; (add-hook 'sgml-mode         'turn-on-setnu-mode)
;; (add-hook 'shell-script-mode 'turn-on-setnu-mode)
;; (add-hook 'sql-mode          'turn-on-setnu-mode)
;; (add-hook 'tar-mode          'turn-on-setnu-mode)
;; (add-hook 'text-mode-hook    'turn-on-setnu-mode)
;; (add-hook 'tmp-file-mode     'turn-on-setnu-mode)
;; (add-hook 'Emacs-Lisp-mode   'turn-on-setnu-mode)
;; (add-hook 'xml-mode          'turn-on-setnu-mode)

;;}}}

;; =======================================================
;; SGML Mode
;; =======================================================
;;{{{ sgml settings

;; enable editing help with mouse-3 in all sgml files
;(defun go-bind-markup-menu-to-mouse3 ()
;  (define-key sgml-mode-map [(down-mouse-3)] 'sgml-tags-menu))
;(add-hook 'sgml-mode-hook 'go-bind-markup-menu-to-mouse3)


;(setq sgml-auto-activate-dtd t)  ;; parse immediately for syntax coloring

;; Turn on syntax coloring
;(cond ((fboundp 'global-font-lock-mode)
;       (global-font-lock-mode t)  ;; Turn on font-lock in all modes that support it
;       (setq font-lock-maximum-decoration t)))  ;; maximum colors

;; load sgml-mode
;(autoload 'sgml-mode "psgml" "Major mode to edit SGML files." t )
;(require 'psgml)
;(require 'psgml-parse)
;(load "psgml-html")

;; set the default SGML declaration. docbook.dcl should work for most DTDs
;(setq sgml-declaration "/usr/share/sgml/docbook/yelp/docbook/dtd/docbookx.dcl")

;; here we set the syntax color information for psgml
;(setq-default sgml-set-face t)
;;
;; Faces.
;;
;(make-face 'sgml-comment-face)
;(make-face 'sgml-doctype-face)
;(make-face 'sgml-end-tag-face)
;(make-face 'sgml-entity-face)
;(make-face 'sgml-ignored-face)
;(make-face 'sgml-ms-end-face)
;(make-face 'sgml-ms-start-face)
;(make-face 'sgml-pi-face)
;(make-face 'sgml-sgml-face)
;(make-face 'sgml-short-ref-face)
;(make-face 'sgml-start-tag-face)

;;
;; Assign variable names and colors
;;
;(set-face-foreground 'sgml-comment-face "magenta")
;(set-face-foreground 'sgml-doctype-face "red")
;(set-face-foreground 'sgml-entity-face "brightmagenta")
;(set-face-foreground 'sgml-ignored-face "green")
;(set-face-background 'sgml-ignored-face "brightred")
;(set-face-foreground 'sgml-ms-end-face "yellow")
;(set-face-foreground 'sgml-ms-start-face "yellow")
;(set-face-foreground 'sgml-pi-face "green")
;(set-face-foreground 'sgml-sgml-face "yellow")
;(set-face-foreground 'sgml-short-ref-face "brightblue")
;(set-face-foreground 'sgml-end-tag-face "cyan")
;(set-face-foreground 'sgml-start-tag-face "cyan")
;;
;; Assign color variable names to faces
;;

;(setq-default sgml-markup-faces
;              '((comment . sgml-comment-face)
;                (doctype . sgml-doctype-face)
;                (end-tag . sgml-end-tag-face)
;                (entity . sgml-entity-face)
;                (ignored . sgml-ignored-face)
;                (ms-end . sgml-ms-end-face)
;                (ms-start . sgml-ms-start-face)
;                (pi . sgml-pi-face)
;                (sgml . sgml-sgml-face)
;                (short-ref . sgml-short-ref-face)
;                (start-tag . sgml-start-tag-face)))

;; XML mode is really psgml mode with an XML DTD
;;(autoload 'xml-mode "psgml" nil t)
;(setq sgml-xml-declaration "/usr/share/sgml/xml.dcl")

;; PSGML pitches a fit if it cant find the DTDs.  So download em from
;; http://www.w3c.org and install em here for reference.
;(add-to-list 'sgml-catalog-files (expand-file-name "~/.emacs.d/DTDs/xhtml.soc"))
;(add-to-list 'sgml-catalog-files (expand-file-name "~/.emacs.d/DTDs/HTML32.soc"))
;(add-to-list 'sgml-catalog-files (expand-file-name "~/.emacs.d/DTDs/html4/HTML4.cat"))


;; From http://xemacs.sf.net/batch-psgml-validate.el
;; solves a problem with parsing xhtml/DTD documents that are hiding in .html files
;; http://list-archive.xemacs.org/xemacs-beta/200011/msg00153.html

;; (defun psgml-find-file-hook ()
;;   (condition-case nil
;;       (save-excursion
;;         (let (mdo)
;;           (goto-char (point-min))
;;           (setq mdo
;;                 (sgml-with-parser-syntax
;;                  (let (start)
;;                    (sgml-skip-upto "MDO")
;;                    (setq start (point))
;;                    (sgml-skip-upto-mdc)
;;                    (forward-char 1)
;;                    (buffer-substring start (point)))))
;;           (string-match "\\bDTD\\s-+\\(\\w+\\)\\b" mdo)
;;           (cond
;;            ((string= (match-string 1 mdo) "XHTML")
;;             (xml-mode))
;;            ((string= (match-string 1 mdo) "XML")
;;             (xml-mode))
;;            ((string= (match-string 1 mdo) "HTML")
;;             (html-mode))
;;            (t
;;             nil))))
;;     (t nil)))

;;}}}

;; =======================================================
;; Derived HTML mode
;; =======================================================

;;{{{ HTML / SGML fest settings

;; (defun hidden-sgml-html-mode ()
;;   "This version of html mode is just a wrapper around sgml mode."
;;   (interactive)
;;   (sgml-mode)
;;   (make-local-variable 'sgml-declaration)
;;   (make-local-variable 'sgml-default-doctype-name)
;;   (setq sgml-default-doctype-name    "html")
;;   (setq   sgml-declaration             "/usr/share/sgml/html.dcl")
;;   (setq   sgml-always-quote-attributes t)
;;   (setq   sgml-indent-step             4)
;;   (setq   sgml-indent-data             t)
;;   (setq   sgml-minimize-attributes     nil)
;;   (setq   sgml-omittag                 t)
;;   (setq   sgml-shorttag                t)
;;   )

;; (setq-default sgml-indent-data t)
;; (setq sgml-always-quote-attributes       t)
;; (setq sgml-auto-insert-required-elements t)
;; (setq sgml-auto-activate-dtd         t)
;; (setq sgml-indent-data               t)
;; (setq sgml-indent-step               4)
;; (setq sgml-minimize-attributes       nil)
;; (setq sgml-omittag                   nil)
;; (setq sgml-shorttag                  nil)


;;}}}



;;}}}

;; =======================================================
;; YICF mode
;; =======================================================

;;{{{ YICF settings

;(require 'yicf-mode)
;(autoload 'yicf-mode "yicf-mode" "yicf Mode" t)

;;}}}

;; =======================================================
;; PHP mode
;; =======================================================

;;{{{ PHP settings

;(require 'php-mode)
;(autoload 'php-mode "php-mode" "php Mode" t)
;(add-hook 'php-mode-hook 'auto-fill-mode)

;;}}}

;; =======================================================
;; html-script mode
;; narrows enclosing region and switches to that mode
;; useful for editting embedded css/js/php/html  within other modes
;; http://www.dur.ac.uk/p.j.heslin/Software/Emacs/
;; =======================================================

;(require 'html-script)

;; =======================================================
;; Javascript Modes
;;   ecma-script mode
;; =======================================================

(autoload 'ecmascript-mode "ecmascript-mode")
;(autoload 'javascript-mode "javascript" nil t)


;; =======================================================
;; Lorem Ipsum
;; func: Lorem-ipsum-...
;; =======================================================

;(require 'lorem-ipsum)

;; =======================================================
;; nXML mode
;; M-TAB: autocomplete tag
;; =======================================================

;(load "rng-auto.el")
;(require 'nxml-mode)

;; More options: type "M-x customize-group" and then type "nxml"

;(setq nxml-child-indent 4)
;(setq nxml-syntax-highlight-flag t)
;; non-nil: "</" inserts the rest of the tag
;; XXX: careful, messes up pasting into emacs buffer.
;;      you can get stuff like </DIV>DIV>
(setq nxml-slash-auto-complete-flag t)


;; Surround a region with a tag
;; (defun surround-region-with-tag (tag-name beg end)
;;   (interactive "sTag name: \nr")
;;   (save-excursion
;;     (goto-char beg)
;;     (insert "<" tag-name ">")
;;     (goto-char (+ end 2 (length tag-name)))
;;     (insert "</" tag-name ">")))

;; (define-key nxml-mode-map "\er" 'surround-region-with-tag)

;  (setq auto-mode-alist
;        (cons '("\\.\\(xml\\|xsl\\|rng\\|xhtml\\)\\'" . nxml-mode)
;         auto-mode-alist))


;; =======================================================
;; Tidy
;; =======================================================

;; Use tidy.el to provide support for tidy
;(autoload 'tidy-buffer "tidy" "Run Tidy HTML parser on current buffer" t)
;(autoload 'tidy-parse-config-file "tidy" "Parse the `tidy-config-file'" t)
;(autoload 'tidy-save-settings "tidy" "Save settings to `tidy-config-file'" t)
;(autoload 'tidy-build-menu  "tidy" "Install an options menu for HTML Tidy." t)
;(add-hook 'sgml-html-mode-hook #'(lambda () (tidy-build-menu sgml-html-mode-map)))
;(add-hook 'xml-html-mode-hook #'(lambda () (tidy-build-menu xml-html-mode-map)))

;; =======================================================
;; CSS  mode
;; =======================================================

;; css-mode.el - cssm-version / Lars Marius Garshol
;(autoload 'css-mode "css-mode" "css Mode" t)
;(setq css-mirror-mode nil)
;(setq cssm-indent-function #'cssm-c-style-indenter)
;(setq cssm-indent-level 4)

;; css-mode.el - anonymous author
;; Current fav
(autoload 'css-mode "css-mode" "css Mode" t)
(setq css-mode-indent-depth 4)

;;
;; Karl Landstrom
;(autoload 'css-mode "css-mode-karl" "css Mode" t)
;(setq css-indent-level 4)


;(autoload 'css-mode "css-mode" "css Mode" t)
;(add-hook 'css-mode-hook 'auto-fill-mode)
;(setq cssm-indent-function #'cssm-c-style-indenter)
;(setq css-indent-level '4)
;(setq cssm-indent-level '4)


;; =======================================================
;; MMM Mode
;; =======================================================

;;{{{ MMM settings

;(require 'mmm-mode)
;(setq mmm-global-mode 'maybe)

;;
;; set up an mmm group for fancy html editing
;(mmm-add-group 'fancy-html
;              '(
;                (html-php-tagged
;                 :submode php-mode
;                 :face mmm-code-submode-face
;                 :front "<[?]php"
;                 :back "[?]>")
;                (html-css-attribute
;                 :submode css-mode
;                 :face mmm-declaration-submode-face
;                 :front "style=\""
;                 :back "\"")))
;

;;
;; What files to invoke the new html-mode for?
;(add-to-list 'auto-mode-alist '("\\.inc\\'" . php-mode))
;(add-to-list 'auto-mode-alist '("\\.phtml\\'" . html-mode))
;(add-to-list 'auto-mode-alist '("\\.php[34]?\\'" . php-mode))
;(add-to-list 'auto-mode-alist '("\\.[sj]?html?\\'" . html-mode))
;(add-to-list 'auto-mode-alist '("\\.jsp\\'" . html-mode))
;;
;; What features should be turned on in this html-mode?
;(add-to-list 'mmm-mode-ext-classes-alist '(html-mode nil html-js))
;(add-to-list 'mmm-mode-ext-classes-alist '(html-mode nil embedded-css))
;(add-to-list 'mmm-mode-ext-classes-alist '(html-mode nil fancy-html))
;;


;; =======================================================
;; ISPELL Inits
;; =======================================================

;;{{{ ispell settings

;(autoload 'ispell-word "ispell" "Check the spelling of word in buffer." t)
;(autoload 'ispell-region "ispell" "Check the spelling of region." t)
;(autoload 'ispell-buffer "ispell" "Check the spelling of buffer." t)

;;}}}

;; =======================================================
;; We love auto-mode's -- recognize extra crap
;; =======================================================

;;{{{ auto-mode-alist: Defines

(setq auto-mode-alist
      (append
       '(
     ("\\.\\([1-8]\\|n\\|man\\)$" . maybe-manify-buffer)
     ("\\(^\\|/\\)[0-9]+$"        . tmp-file-mode)  ; all digits
     ("\\(^\\|/\\)\\(.\\|..\\)$"  . tmp-file-mode) ; 1 or 2 chars
     ("\\.uu$"                    . tmp-file-mode)
     ("\\.uue$"                   . tmp-file-mode)
     ; ("\\/twiki\\/"               . pmwiki-mode)
     ("CHANGES\\'"                . change-log-mode)
     ("ChangeLog\\'"              . change-log-mode)
     ("ChangeLog.[0-9]+\\'"       . change-log-mode)
     ("\\$CHANGE_LOG\\$\\.TXT"    . change-log-mode)
     ("\\(^\\|/\\)\\.\\\w+$"      . shell-script-mode) ; dot files
     ("\\.sh$"                    . shell-script-mode)
     ("\\.rc$"                    . shell-script-mode) ; rc files
     ("\\.conf\\'"                . shell-script-mode)
     ("\\.lst\\'"                 . shell-script-mode)
     ("\\.properties\\'"          . shell-script-mode)
     ("[]>:/]\\..*emacs\\'"       . emacs-lisp-mode)
     ("\\.el\\'"                  . emacs-lisp-mode)
     ("\\.ldif\\'"  . makefile-mode)
;    ("\\.java\\'"  . java-mode)  ;; java-mode vs jde-mode
     ("\\.java\\'"  . jde-mode)
     ("\\.tag\\'"   . nxml-mode)
     ("\\.policy\\'". jde-mode)
;    ("\\.php\\'"   . html-mode) ;; fancy HTML mode has php support
     ("\\.php\\'"   . php-mode)  ;; raw php-mode works better, overall
     ("\\.inc\\'"   . php-mode)  ;; php include file denotation
     ("\\.ros\\'"   . php-mode)  ;; yahoo rosetta files
     ("\\.tpl\\'"   . php-mode)
     ("\\.asp\\'"   . html-mode)
     ("\\.htm\\'"   . nxml-mode)
;     ("\\.html\\'"  . xml-mode)  ;; hurm
     ("\\.html\\'"  . nxml-mode)  ;; hurma
     ("\\.jsp\\'"   . html-mode)
     ("\\.pat\\'"   . html-mode)    ;; SAGE pattern files
     ("\\.tmpl\\'"  . html-mode)
     ("\\.tld\\'"   . html-mode)    ;; TagLib Definition (xml)
     ("\\.\\(xml\\|xsl\\|rng\\|xhtml\\)\\'" . nxml-mode)  ;; nXML mode
;;   ("\\.xml\\'"   . xml-mode)    ;; XML files
     ("\\.C\\'"     . c++-mode)
     ("\\.H\\'"     . c++-mode)
     ("\\.cc\\'"    . c++-mode)
     ("\\.cpp\\'"   . c++-mode)
     ("\\.cxx\\'"   . c++-mode)
     ("\\.h\\'"     . c++-mode)
     ("\\.hh\\'"    . c++-mode)
     ("\\.hpp\\'"   . c++-mode)
;     ("\\.js\\'"    . javascript-mode)
     ("\\.js\\'"    . ecmascript-mode)
     ("\\.c\\'"     . c-mode)
     ("\\.c\\'"     . c-mode)
     ("\\.lex\\'"   . c-mode)
     ("\\.pc\\'"    . c-mode)
     ("\\.y\\'"     . c-mode)
     ("\\.css\\'"   . css-mode)
     ("\\.sql$"     . sql-mode)
     ("\\.tbl$"     . sql-mode)
     ("\\.sp$"      . sql-mode)
     ("\\.pm$"      . perl-mode)
     ("\\.ph$"      . perl-mode)
     ("\\.baf$"      . perl-mode)
     ("\\.[12345678]\\'"  . nroff-mode)
     ("\\.mm\\'"          . nroff-mode)
     ("\\.me\\'"          . nroff-mode)
     ("\\.ms\\'"          . nroff-mode)
     ("\\.man\\'"         . nroff-mode)
     ("\\.dtd\\'"         . nxml-mode)
     ("\\.dec\\'"         . nxml-mode)
     ("\\.dcl\\'"         . nxml-mode)
     ("\\.ele\\'"         . nxml-mode)
     ("\\.mod\\'"         . nxml-mode)
;     ("\\.sgm\\'"         . sgml-mode)
;     ("\\.sgml\\'"        . sgml-mode)
     ("\\.sgm\\'"         . nxml-mode)
     ("\\.sgml\\'"        . nxml-mode)
     ("\\.tex\\'"         . TeX-mode)
     ("\\.TeX\\'"         . TeX-mode)
     ("\\.ltx\\'"         . LaTeX-mode)
     ("\\.sty\\'"         . LaTeX-mode)
     ("\\.bbl\\'"         . LaTeX-mode)
     ("\\.bib\\'"         . bibtex-mode)
     ("\\.texinfo\\'"     . texinfo-mode)
     ("\\.texi\\'"        . texinfo-mode)
     ("/Message[0-9]*\\'" . text-mode)
     ("\\.article\\'"     . text-mode)
     ("\\.letter\\'"      . text-mode)
     ("\\.text\\'"        . text-mode)
     ("^/tmp/"            . text-mode)
     ("^/tmp/Re"          . text-mode)
     ("\\.prolog\\'"      . prolog-mode)
;    ("\\.pl\\'"          . prolog-mode)
     ("\\.l\\'"           . lisp-mode)
     ("\\.lisp\\'"        . lisp-mode)
     ("\\.lsp\\'"         . lisp-mode)
     ("\\.ml\\'"          . lisp-mode)
     ("\\.awk\\'"         . awk-mode)
     ("\\.oak\\'"         . scheme-mode)
     ("\\.scm.[0-9]*\\'"  . scheme-mode)
     ("\\.scm\\'"         . scheme-mode)
     ("\\.tar\\'"         . tar-mode)
     ("\\.f\\'"           . fortran-mode)
     ("\\.for\\'"         . fortran-mode)
     ("\\.mss\\'"         . scribe-mode)
     ("\\.yicf\\'"        . yicf-mode)
     ("\\.s\\'"           . asm-mode)
     )
       auto-mode-alist))

;;}}} auto-mode-alist: Defines

;; =======================================================
;; Font-lock-mode is major win. It can convert VI
;; users to emacs. No shit
;; =======================================================

;;{{{ font-lock add-hooks

(setq font-lock-maximum-decoration t)

(cond ((or (string-match "Lucid" emacs-version)
           window-system)
       (add-hook 'c++-mode-hook         'turn-on-font-lock)
       (add-hook 'c-mode-hook           'turn-on-font-lock)
       (add-hook 'dired-mode-hook       'turn-on-font-lock)
       (add-hook 'emacs-lisp-mode-hook  'turn-on-font-lock)
       (add-hook 'java-mode-hook        'turn-on-font-lock)
       (add-hook 'javascript-mode-hook  'turn-on-font-lock)
       (add-hook 'ksh-mode-hook         'turn-on-font-lock)
       (add-hook 'lisp-mode-hook        'turn-on-font-lock)
       (add-hook 'perl-mode-hook        'turn-on-font-lock)
       (add-hook 'php-mode-hook         'turn-on-font-lock)
       (add-hook 'nxml-mode-hook        'turn-on-font-lock)
       (add-hook 'postscript-mode-hook  'turn-on-font-lock-small)
       (add-hook 'text-mode-hook        'turn-on-auto-fill)
       ))

;;}}}

;; =======================================================
;; Emacs Lisp hooks
;; =======================================================

;;{{{ lisp

(define-key emacs-lisp-mode-map "\^C\^C" 'compile-defun)
(define-key emacs-lisp-mode-map "\^C\^E" 'eval-defun)
(define-key emacs-lisp-mode-map "\^C\^X" 'edebug-defun)
(define-key emacs-lisp-mode-map "\^Xx"   'edebug-defun)

(put 'narrow-to-region 'disabled nil)

;;}}}

;; =======================================================
;; CVS Config
;; =======================================================

;;{{{ cvs-config

(if (file-exists-p "/usr/bin/cvs")
    (setq cvs-program "/usr/bin/cvs")
  (setq cvs-program "/usr/bin/cvs"))

(setq cvs-diff-flags nil)   ; normal diffs please

(require 'vc-svn nil t) ; load up svn support

;;}}}

;; ========================================
;; Some ksh indentation style variables
;; ========================================

;;{{{ ksh settings

(setq ksh-indent 4)

;;}}}

;; =======================================================
;; SQL mode
;; =======================================================

;;{{{ sql mode

;(require 'sql-mode)
;(sql-initialize)
(autoload 'sql-mode "sql-mode" "SQL Editing Mode" t)

;;}}}

;; =======================================================
;; Good stuff for PERL mode
;; =======================================================

;;{{{ perl mode

(add-hook 'perl-mode-hook
      '(lambda ()
         (setq perl-tab-to-comment t)  ; tabs again
         (define-key (current-local-map) "\C-h" nil)
         (define-key (current-local-map) "\M-\C-h" nil)))

;;}}}

;; =======================================================
;; Are we running Lucid Emacs ??
;; =======================================================

;;{{{ Lucid emacs sniff

(cond
 ((string-match "Lucid" emacs-version)
;;  (global-set-key "\C-x\C-c" nil)
  (global-set-key '(control tab)    [tab])
  (global-set-key 'insert nil) ; hateful Indy keyboard
  (global-set-key 'f1 'undo)  ; why for?? -Tak

  (define-key emacs-lisp-mode-map '(control A) 'describe-function-arglist)
  (define-key emacs-lisp-mode-map '(control C) 'compile-defun)
  (define-key emacs-lisp-mode-map '(control E) 'eval-defun)
  (define-key emacs-lisp-mode-map '(control M) 'show-elisp-macroexpansion)

  ;; Make ^X^M and ^X RET be different (since I do the latter by accident)
;  (define-key global-map [(control x) return] nil)

  (global-set-key [(control !)] 'line-to-top-of-window)
  (global-set-key [(meta !)] 'shell-command)


  ;; =======================================================
  ;; If we're in a window, do snazzy stuff in the title bar
  ;; =======================================================

  (cond ((eq window-system 'x)
     (let ((s (system-name)))
       (if (string-match "\\.\\(wigwamlab\\|wigwam\\)\\.com" s)
           (setq s (substring s 0 (match-beginning 0))))
       (if (equal screen-icon-title-format "%b")
           (setq screen-icon-title-format
             s
             ;(concat s "  " emacs-version "  (%b)")
             )))
     ))

  ;; This is cool. Don't loose your place if we split windows.
  (cond
   ((and (= emacs-major-version 19)
     (>= emacs-minor-version 12))
    (setq split-window-keep-point nil)
    ))

  ))


;; =======================================================
;; This is kinda cool -- the icon looks like what the buffer had
;; =======================================================

(if (and (string-match "XEmacs" emacs-version) (eq window-system 'x))
    (require 'live-icon))

;;}}}

;; =======================================================
;; Mode-line hacking
;; =======================================================

;;{{{ modeline-setqs

(setq line-number-mode t)             ; I LIKE seeing the line number
(setq column-number-mode t)           ; show column numnbers in mode line too
(setq default-mode-line-format
      '("" mode-line-modified
        mode-line-buffer-identification "   "
        (line-number-mode "#%5l") " "
        (column-number-mode "#%5c")
        global-mode-string
        "   %[(" mode-name minor-mode-alist "%n"
        mode-line-process ")%]--" (-3 . "%p")
        "--<" default-directory ">%-"
        )
      mode-line-format default-mode-line-format
      )

;;}}}

;; =======================================================
;; Fun with Line numbers
;; =======================================================

;;{{{ Line numbers

(defun show-line-numbers ()
  "Show line numbers in a copy of the current buffer."
  (interactive)
  (let ((n 0))
    (goto-char (point-min))
    (while (< (point) (point-max))
      (setq n (1+ n))
      (insert (format "%5d:\t" n))
      (forward-line 1)))
  (toggle-read-only))

(defun remove-line-numbers ()
  "Remove line numbers installed by show-line-numbers."
  (interactive)
  (toggle-read-only)
  (save-excursion
    (goto-char (point-min))
    ;; use loop rather than replace-regexp so M-x undo can undo it
    (while (re-search-forward "^[ 0-9][ 0-9][ 0-9][ 0-9][ 0-9]:\t"
                  (point-max) t)
      (replace-match "" t t))))

;;}}}

;; =======================================================
;; By default we starting in text mode.
;; =======================================================

;;{{{ default mode
(setq default-major-mode 'text-mode)
(hl-line-mode t)
(setq initial-major-mode (lambda ()
               (text-mode)
               (turn-on-auto-fill)
               (font-lock-mode)
               ))

;;}}}

;; =======================================================
;; Folding mode
;; =======================================================

;;{{{ Folding mode

;;(load "folding" 'nomessage 'noerror)
;;(folding-mode-add-find-file-hook)

;;(folding-add-to-marks-list 'jde-mode "// {{{ " "// }}}" nil t)
;;(folding-add-to-marks-list 'html-mode "<!-- [[[ " " ]]] -->" nil t)

;;}}}

;; =======================================================
;; Where info lives
;; =======================================================

;;{{{ info


;(setq Info-directory-list (append Info-directory-list '(
;                           "~/.emacs.d/info/"
;                           "/tools/contrib/info/")))

;;}}}

;; =======================================================
;; douglas crockford's jslint
;; =======================================================
;(load-library "jslint")

;; =======================================================
;; Hilit mode (java)
;; =======================================================
;(load "hilit19")
;(load "hilit-java")

;; =======================================================
;; The Mystery that is Emacs TAB support
;; http://www.emacswiki.org/cgi-bin/wiki/NoTabs
;; =======================================================
(setq-default tab-width 4)
(setq indent-tabs-mode nil)   ; nil: tabs are NOT to be used for indents
(setq-default tab-stop-list
              '(4 8 12 16 20 24 28 32 36 40 44 48 52 56 60 64 68 72 76 80 84 88 92 96 100 104))


;(require 'show-wspace)
(load "show-wspace")
;   M-x toggle-tabs-font-lock to manually flip
(setq highlight-tabs-flag t)
(setq highlight-hard-spaces-flag t)
(setq highlight-trailing-whitespace-flag t) ;

;(add-hook 'font-lock-mode-hook 'highlight-tabs)


;; =======================================================
;; Misc stuff
;; =======================================================


;; =======================================================
;; Misc stuff
;; =======================================================

;;{{{ leftover

;;; Make all yes-or-no questions as y-or-n
(fset 'yes-or-no-p 'y-or-n-p)

(defconst inhibit-startup-message t)
(put 'downcase-region 'disabled nil)

(put 'upcase-region 'disabled nil)
(auto-compression-mode)
(defun my-kill-buffer () "Kills the current buffer ; mostly for keymap support"
  (interactive)
  (kill-buffer nil))

(put 'eval-expression 'disabled nil)
; hooks for filling in text and (la)tex mode
(toggle-text-mode-auto-fill)



;; =======================================================
;; Enable the commands `narrow-to-region' ("C-x n n") and
;; `eval-expression' ("M-ESC", or "ESC ESC").  Both are useful
;; commands, but they can be confusing for a new user, so they're
;; disabled by default.
;; =======================================================

(put 'narrow-to-region 'disabled nil)
(put 'eval-expression 'disabled nil)


;;}}}

;; =======================================================
;; Coscend Templates
;;  -- from Rob Weltman/Tobias Crawley
;; =======================================================

;;{{{ Coscend mods

;;(load-file (expand-file-name "~/emacs/lisp/csCopyright.elc"))
;;(load-file (expand-file-name "~/emacs/lisp/javautil.elc"))

;;}}}

;; =======================================================
;; Load a PreFormated Color Scheme
;; Further customized via Customization Buffer that get loaded when
;; this file finishes.
;; =======================================================
(require 'color-theme)
;(color-theme-tty-dark)  ;; works well for DSL / ANSI restricted
;(color-theme-xemacs) ;; default XEmacs 21 colors


;; =======================================================
;; Hide passwords entered in *shell* buffers
;; =======================================================

(add-hook 'comint-output-filter-functions
          'comint-watch-for-password-prompt)

;; =======================================================
;; eof


