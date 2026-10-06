;;; enghi-peek.el --- Peek at enghi's web screens in a posframe -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Look at an enghi web screen over the frame without giving it a window: the
;; dashboard, or the task being worked on with its work log, whose diagrams
;; and code only the web page renders.
;;
;;   * `enghi-peek-dashboard' shows the dashboard (/).
;;   * `enghi-peek-working' shows the Clarify page of the task being worked
;;     on, at its latest log entry.
;;   * `enghi-peek-read' shows a page and reads its keys until it closes, for
;;     callers that read keys themselves: RET in `enghi-task-list'.
;;
;; The page is an xwidget-webkit view in a posframe (a child frame). The child
;; frame takes no input, so the keys are read in the frame below it through a
;; transient keymap, `enghi-peek-map': j/k scroll, d and w switch screens, q
;; closes. Any other key closes the peek and does what it does.
;;
;; **One view is kept and reused**, so a page is not loaded from scratch each
;; time. It carries no xwidget-webkit callback: the events that would call it
;; (title, load progress) rename the buffer, and nothing here needs them. The
;; page follows changes by itself through the server's /api/events, so the
;; work log stays current while it is shown.
;;
;; Needs posframe and an Emacs built with xwidgets.

;;; Code:

(require 'enghi)
(require 'seq)
(require 'subr-x)

(declare-function posframe-show "posframe" (buffer-or-name &rest args))
(declare-function posframe-hide "posframe" (buffer-or-name))
(declare-function posframe-workable-p "posframe" ())
(declare-function posframe-poshandler-frame-center "posframe" (info))
(declare-function make-xwidget "xwidget.c"
                  (type title width height arguments &optional buffer related))
(declare-function xwidget-live-p "xwidget.c" (object))
(declare-function xwidget-resize "xwidget.c" (xwidget new-width new-height))
(declare-function xwidget-webkit-goto-uri "xwidget.c" (xwidget uri))
(declare-function xwidget-webkit-uri "xwidget" (xwidget))
(declare-function xwidget-webkit-execute-script "xwidget" (xwidget script &optional callback))
(declare-function xwidget-buffer "xwidget" (xwidget))

(defcustom enghi-peek-size '(0.8 . 0.85)
  "Size of the peek, as (WIDTH . HEIGHT), each a fraction of the frame."
  :type '(cons float float)
  :group 'enghi)

(defcustom enghi-peek-poshandler #'posframe-poshandler-frame-center
  "Function placing the peek; see `posframe-show'."
  :type 'function
  :group 'enghi)

(defcustom enghi-peek-scroll-step 80
  "Pixels that `j' and `k' scroll the peek."
  :type 'integer
  :group 'enghi)

(defconst enghi--peek-buffer-name " *enghi-peek*"
  "Buffer holding the peek's webkit view.")

(defconst enghi--peek-keys
  '(("j/k" . "Scroll") ("SPC/S-SPC" . "Page") ("</>" . "Top/Bottom")
    ("d" . "Dashboard") ("w" . "Working") ("r" . "Reload")
    ("E" . "Window") ("o" . "Browser") ("q" . "Close"))
  "Keys shown on the peek's header line.")

(defvar enghi--peek-xwidget nil
  "The peek's webkit view, kept between peeks.")

(defvar enghi-peek-map)                 ; below, with its commands

(defvar enghi--peek-exit nil
  "Function that ends `enghi-peek-map', while the peek is shown.")

(defvar enghi--peek-shown nil
  "Non-nil while the peek is shown.")

;;;; ---------------------------------------------------------------- Paths

(defun enghi--peek-working-path ()
  "Return the path of the working task's page at its latest note, or nil.
Without a note, the page opens at its work log."
  (when-let* ((task (car (alist-get 'working (alist-get 'gtd (enghi-dashboard))))))
    (let* ((id (alist-get 'id task))
           (logs (alist-get 'logs (enghi-request "GET" (format "/api/tasks/%s/logs" id))))
           (note (car (last (seq-filter (lambda (log) (equal (alist-get 'kind log) "note"))
                                        logs)))))
      (format "/gtd/clarify/%s#%s" id
              (if note (format "log-%s" (alist-get 'id note)) "log")))))

;;;; ---------------------------------------------------------------- View

(defun enghi-peek-available-p ()
  "Return non-nil if this Emacs can show the peek."
  (and (featurep 'xwidget-internal)
       (require 'posframe nil t)
       (posframe-workable-p)))

(defun enghi--peek-check ()
  "Signal a `user-error' unless this Emacs can show the peek."
  (unless (featurep 'xwidget-internal)
    (user-error "The peek needs an Emacs built with xwidgets"))
  (unless (enghi-peek-available-p)
    (user-error "The peek needs posframe and a graphical frame")))

(defun enghi--peek-view ()
  "Return the peek's webkit view, made the first time."
  (let ((buffer (get-buffer-create enghi--peek-buffer-name)))
    (unless (and enghi--peek-xwidget
                 (xwidget-live-p enghi--peek-xwidget)
                 (eq (xwidget-buffer enghi--peek-xwidget) buffer))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          ;; The size is set each time it is shown
          (setq enghi--peek-xwidget (make-xwidget 'webkit "enghi" 400 300 nil buffer))
          (insert (propertize "*" 'display (list 'xwidget :xwidget enghi--peek-xwidget))))
        (setq-local header-line-format
                    (concat " " (enghi--xwidget-keys-string enghi--peek-keys)))))
    enghi--peek-xwidget))

(defun enghi--peek-open (url &optional no-keymap)
  "Show URL in the peek over the selected frame, and read its keys.
With NO-KEYMAP, the caller reads them instead (`enghi-peek-read')."
  (let* ((view (enghi--peek-view))
         (width (round (* (frame-pixel-width) (car enghi-peek-size))))
         (height (round (* (frame-pixel-height) (cdr enghi-peek-size))))
         (frame (apply #'posframe-show enghi--peek-buffer-name
                       :poshandler enghi-peek-poshandler
                       :respect-header-line t
                       ;; In characters, so the poshandler places the right size
                       :width (/ width (frame-char-width))
                       :height (/ height (frame-char-height))
                       (enghi--posframe-look)))
         (window (frame-root-window frame)))
    (set-frame-size frame width height t)
    (xwidget-resize view (window-body-width window t) (window-body-height window t))
    (xwidget-webkit-goto-uri view url)
    (setq enghi--peek-shown t)
    (unless (or no-keymap enghi--peek-exit)
      (setq enghi--peek-exit (set-transient-map enghi-peek-map t #'enghi--peek-hide)))))

(defun enghi--peek-hide ()
  "Hide the peek. Its view stays, for the next time."
  (setq enghi--peek-exit nil
        enghi--peek-shown nil)
  (when (get-buffer enghi--peek-buffer-name)
    (posframe-hide enghi--peek-buffer-name)))

(defun enghi--peek (path)
  "Show PATH on the server in the peek."
  (enghi--peek-check)
  (enghi--ensure-server)
  (enghi--peek-open (enghi--browse-url-for path)))

(defun enghi--peek-script (script)
  "Run SCRIPT in the page the peek shows."
  (when enghi--peek-xwidget
    (xwidget-webkit-execute-script enghi--peek-xwidget script)))

;;;; ---------------------------------------------------------------- Commands

(defun enghi-peek-read (path)
  "Show PATH on the server in the peek, and read its keys until it closes.
For callers that read keys themselves, such as `enghi-task-list': they go on
once it closes. The keys are those of `enghi-peek-map'; any other key, C-g
included, closes the peek and is not passed on."
  (enghi--peek-check)
  (enghi--ensure-server)
  (enghi--peek-open (enghi--browse-url-for path) t)
  (unwind-protect
      (while enghi--peek-shown
        (let* ((key (condition-case nil (read-key) (quit ?\C-g)))
               ;; A mouse wheel event is a list; its type is the key
               (command (lookup-key enghi-peek-map (vector (if (consp key) (car key) key)))))
          (if (commandp command)
              (call-interactively command)
            (enghi--peek-hide))))
    (enghi--peek-hide)))

;;;###autoload
(defun enghi-peek-dashboard ()
  "Show the web dashboard over the frame, without taking a window.
The keys are in `enghi-peek-map'; any other key closes it."
  (interactive)
  (enghi--peek "/"))

;;;###autoload
(defun enghi-peek-working ()
  "Show the task being worked on over the frame, at its latest log entry.
The page is the task's Clarify page, with its work log rendered as on the
web, diagrams included. The keys are in `enghi-peek-map'; any other key
closes it."
  (interactive)
  (enghi--peek-check)
  (enghi--ensure-server)
  (enghi--peek-open
   (enghi--browse-url-for
    (or (enghi--peek-working-path) (user-error "No task is being worked on")))))

(defun enghi-peek-forward ()
  "Scroll the peek down a little."
  (interactive)
  (enghi--peek-script (format "window.scrollBy(0, %d);" enghi-peek-scroll-step)))

(defun enghi-peek-backward ()
  "Scroll the peek up a little."
  (interactive)
  (enghi--peek-script (format "window.scrollBy(0, -%d);" enghi-peek-scroll-step)))

(defun enghi-peek-page-forward ()
  "Scroll the peek down a page."
  (interactive)
  (enghi--peek-script "window.scrollBy(0, window.innerHeight * 0.9);"))

(defun enghi-peek-page-backward ()
  "Scroll the peek up a page."
  (interactive)
  (enghi--peek-script "window.scrollBy(0, -window.innerHeight * 0.9);"))

(defun enghi-peek-top ()
  "Scroll the peek to the top of the page."
  (interactive)
  (enghi--peek-script "window.scrollTo(0, 0);"))

(defun enghi-peek-bottom ()
  "Scroll the peek to the bottom of the page."
  (interactive)
  (enghi--peek-script "window.scrollTo(0, document.documentElement.scrollHeight);"))

(defun enghi-peek-reload ()
  "Load the page in the peek again."
  (interactive)
  (enghi--peek-script "location.reload();"))

(defun enghi-peek-goto-dashboard ()
  "Show the dashboard in the peek."
  (interactive)
  (xwidget-webkit-goto-uri enghi--peek-xwidget (enghi--browse-url-for "/")))

(defun enghi-peek-goto-working ()
  "Show the task being worked on in the peek."
  (interactive)
  (if-let* ((path (enghi--peek-working-path)))
      (xwidget-webkit-goto-uri enghi--peek-xwidget (enghi--browse-url-for path))
    (message "No task is being worked on")))

(defun enghi-peek-close ()
  "Close the peek."
  (interactive)
  (when enghi--peek-exit
    (funcall enghi--peek-exit))
  (enghi--peek-hide))

(defun enghi-peek-open-window ()
  "Close the peek and open its page in a window, in xwidget."
  (interactive)
  (let ((url (xwidget-webkit-uri enghi--peek-xwidget)))
    (enghi-peek-close)
    (enghi-browse-in-xwidget url)))

(defun enghi-peek-open-browser ()
  "Close the peek and open its page in the browser."
  (interactive)
  (let ((url (xwidget-webkit-uri enghi--peek-xwidget)))
    (enghi-peek-close)
    (browse-url url)))

(defvar enghi-peek-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'enghi-peek-forward)
    (define-key map (kbd "C-n") #'enghi-peek-forward)
    (define-key map (kbd "<down>") #'enghi-peek-forward)
    (define-key map (kbd "<wheel-down>") #'enghi-peek-forward)
    (define-key map (kbd "k") #'enghi-peek-backward)
    (define-key map (kbd "C-p") #'enghi-peek-backward)
    (define-key map (kbd "<up>") #'enghi-peek-backward)
    (define-key map (kbd "<wheel-up>") #'enghi-peek-backward)
    (define-key map (kbd "SPC") #'enghi-peek-page-forward)
    (define-key map (kbd "C-v") #'enghi-peek-page-forward)
    (define-key map (kbd "S-SPC") #'enghi-peek-page-backward)
    (define-key map (kbd "DEL") #'enghi-peek-page-backward)
    (define-key map (kbd "M-v") #'enghi-peek-page-backward)
    (define-key map (kbd "<") #'enghi-peek-top)
    (define-key map (kbd ">") #'enghi-peek-bottom)
    (define-key map (kbd "r") #'enghi-peek-reload)
    (define-key map (kbd "d") #'enghi-peek-goto-dashboard)
    (define-key map (kbd "w") #'enghi-peek-goto-working)
    (define-key map (kbd "E") #'enghi-peek-open-window)
    (define-key map (kbd "o") #'enghi-peek-open-browser)
    (define-key map (kbd "q") #'enghi-peek-close)
    (define-key map (kbd "<escape>") #'enghi-peek-close)
    map)
  "Keys read while the peek is shown. Any other key closes it.")

(provide 'enghi-peek)
;;; enghi-peek.el ends here
