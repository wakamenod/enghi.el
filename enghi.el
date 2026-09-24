;;; enghi.el --- Client for local Wiki + GTD (enghi) -*- lexical-binding: t; -*-

;; Author: jun
;; Package-Requires: ((emacs "28.1"))
;; Keywords: outlines, hypermedia, convenience

;;; Commentary:

;; Use a running enghi server (http://127.0.0.1:7777) from Emacs.
;;
;; The design corresponds to stage 3 in docs/DESIGN.md. Key points:
;;
;;   * Search and indexing live on the server. Emacs holds none.
;;     This layout structurally avoids the causes of org-roam's slowness
;;     (result conversion in Elisp, IPC with external processes,
;;     and full recrawls on every save).
;;   * Edit pages in native Emacs buffers.
;;   * Saves are PUTs with optimistic locking. There are two kinds of 409,
;;     and they are handled differently.
;;   * No authentication. The server protects via Host / Origin / Content-Type
;;     (the decision is recorded in DESIGN.md 4.4). There is no setting for
;;     a token.

;;; Code:

(require 'url)
(require 'url-http)
(require 'url-util)
(require 'json)
(require 'seq)
(require 'subr-x)

;; Set buffer-locally by url-http. Declared here to reference it.
(defvar url-http-response-status)

;; Defined in another file. Declared here only to avoid circular requires.
(declare-function markdown-mode "markdown-mode" ())
(declare-function enghi-consult-search "enghi-consult" ())

(defgroup enghi nil
  "Client for local Wiki + GTD (enghi)."
  :group 'applications
  :prefix "enghi-")

(defcustom enghi-server-url "http://127.0.0.1:7777"
  "URL of the enghi server.
Pointing to anything other than loopback results in a 403 from the server's
Host check."
  :type 'string)

(defcustom enghi-request-timeout 10
  "Timeout for synchronous requests in seconds."
  :type 'integer)

;; Allow the display function to be replaced (DESIGN.md 8-26). **Default is
;; `browse-url' (external browser).** To open inside Emacs, use
;; `enghi-browse-in-xwidget' (with padding) or `xwidget-webkit-browse-url'
;; (full buffer). Editing is done in native Emacs buffers, so it avoids known
;; xwidget weaknesses (editable text areas, fighting over key input).
(defvar enghi-browse-function #'browse-url
  "Function to open enghi pages in a browser.")

;;;; ---------------------------------------------------------------- HTTP

(define-error 'enghi-error "enghi request failed")
(define-error 'enghi-http-error "enghi returned an HTTP error" 'enghi-error)

;; 409 has two different meanings, and the client must handle them completely
;; differently (DESIGN.md 4.2). Do not mix them up.
(define-error 'enghi-version-conflict
  "Version conflict (updated elsewhere)" 'enghi-error)
(define-error 'enghi-title-conflict
  "A page with the same title (case-insensitive) already exists" 'enghi-error)

(defun enghi--url (path)
  "Convert PATH to an absolute URL."
  (concat (string-remove-suffix "/" enghi-server-url) path))

(defun enghi--encode-query (params)
  "Encode PARAMS (alist) into a query string, dropping entries with nil values."
  (let ((parts (delq nil
                     (mapcar (lambda (kv)
                               (when (and (cdr kv) (not (equal (cdr kv) "")))
                                 (concat (url-hexify-string (format "%s" (car kv)))
                                         "="
                                         (url-hexify-string (format "%s" (cdr kv))))))
                             params))))
    (if parts (concat "?" (string-join parts "&")) "")))

(defun enghi--parse-json (text)
  "Parse TEXT as JSON and return an alist, or nil if empty or malformed."
  (when (and text (not (string-empty-p (string-trim text))))
    (condition-case nil
        (json-parse-string text
                           :object-type 'alist :array-type 'list
                           :null-object nil :false-object nil)
      (error nil))))

(defun enghi--response (buffer)
  "Convert url response BUFFER to (STATUS . DATA)."
  (unwind-protect
      (with-current-buffer buffer
        (let ((status (or url-http-response-status 0)))
          (goto-char (point-min))
          ;; Move to the boundary between headers and body
          (if (re-search-forward "\n\r?\n" nil t)
              (let ((raw (buffer-substring-no-properties (point) (point-max))))
                ;; **Because url buffers are unibyte, `decode-coding-region\'
                ;; does not make them multibyte, passing garbled Japanese to
                ;; JSON** (verified experimentally). Decode as a string. If
                ;; already multibyte, url has already decoded it.
                (cons status
                      (enghi--parse-json
                       (if (multibyte-string-p raw) raw (decode-coding-string raw 'utf-8)))))
            (cons status nil))))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(defun enghi--signal-for (status data)
  "Signal an appropriate error from STATUS and DATA."
  (let ((code (alist-get 'error data))
        (msg (or (alist-get 'message data) "")))
    (cond
     ;; **version_conflict — Optimistic lock version mismatch.** Show diff
     ;; against current data to let the user merge. Do not discard input.
     ((equal code "version_conflict")
      (signal 'enghi-version-conflict (list msg (alist-get 'current data))))
     ;; **title_conflict — New title conflicts with another page's canonical
     ;; title or alias.** Prompt for a different title while keeping the body
     ;; intact.
     ((equal code "title_conflict")
      (signal 'enghi-title-conflict (list msg (alist-get 'conflicting_page data))))
     (t
      (signal 'enghi-http-error (list status (if (string-empty-p msg) code msg)))))))

(defun enghi-request (method path &optional payload params)
  "Send a synchronous request to enghi and return JSON as an alist.
METHOD is a string such as \"GET\". PAYLOAD is an alist, sent as JSON if
non-nil. PARAMS is an alist for the query string."
  (let* ((url-request-method method)
         (url-request-extra-headers
          (when payload
            ;; **Write operations only accept application/json** (DESIGN.md
            ;; 4.4).
            '(("Content-Type" . "application/json"))))
         (url-request-data
          (when payload
            ;; url-request-data must be unibyte
            (encode-coding-string (json-encode payload) 'utf-8)))
         (url (enghi--url (concat path (enghi--encode-query params))))
         (buffer (url-retrieve-synchronously url t t enghi-request-timeout)))
    (unless buffer
      (signal 'enghi-error
              (list (format "Cannot connect to enghi server: %s.
Make sure `enghi serve' is running"
                            enghi-server-url))))
    (pcase-let ((`(,status . ,data) (enghi--response buffer)))
      (if (and (>= status 200) (< status 300))
          data
        (enghi--signal-for status data)))))

(defun enghi-request-async (method path callback &optional payload params)
  "Send an asynchronous request to enghi, calling CALLBACK with JSON on success.
On failure, call CALLBACK with nil (to avoid errors during search-as-you-type)."
  (let* ((url-request-method method)
         (url-request-extra-headers
          (when payload '(("Content-Type" . "application/json"))))
         (url-request-data
          (when payload (encode-coding-string (json-encode payload) 'utf-8)))
         (url (enghi--url (concat path (enghi--encode-query params)))))
    (url-retrieve
     url
     (lambda (status cb)
       (if (plist-get status :error)
           (funcall cb nil)
         (pcase-let ((`(,code . ,data) (enghi--response (current-buffer))))
           (funcall cb (and (>= code 200) (< code 300) data)))))
     (list callback) t t)))

;;;; ------------------------------------------------------------- Fetch

(defun enghi-search (query &optional kind limit)
  "Search across all items for QUERY and return a list of results.
Filter by KIND such as \"page\". LIMIT defaults to the server-side 50."
  (alist-get 'results
             (enghi-request "GET" "/api/search"
                            nil `((q . ,query) (kind . ,kind) (limit . ,limit)))))

(defun enghi-page (slug)
  "Return the page for SLUG."
  (enghi-request "GET" (format "/api/pages/%s" (url-hexify-string slug))))

(defun enghi-pages (&optional limit sort)
  "Return a list of pages."
  (alist-get 'pages
             (enghi-request "GET" "/api/pages" nil
                            `((limit . ,(or limit 500)) (sort . ,sort)))))

(defun enghi-dashboard ()
  "Return dashboard aggregates in a single request."
  (enghi-request "GET" "/api/dashboard"))

(defun enghi-status ()
  "Return server status (for checking connectivity)."
  (enghi-request "GET" "/api/status"))


;;;; ---------------------------------------------------------------- xwidget

;; The xwidget view fills the window body, so by default page edges stick to
;; the fringes and mode line. Shave a little off all four sides to add
;; padding. Because view size is determined by `window-inside-pixel-edges'
;; (the area excluding margins and fringes), left and right can be trimmed via
;; window margins, and top via the header line. Only the bottom requires
;; tweaking the function that returns height.

(defcustom enghi-xwidget-padding '(24 . 12)
  "Padding in pixels left around the view by `enghi-browse-in-xwidget'.
An integer applies equally to all four sides; (HORIZ . VERT) specifies
horizontal and vertical separately. Horizontal padding is rounded to character
width, so it will not match the exact value. Setting to 0 expands to the full
buffer."
  :type '(choice (integer :tag "Same on all four sides")
                 (cons :tag "Separate horizontal and vertical"
                       (integer :tag "Horizontal") (integer :tag "Vertical"))))

(defvar-local enghi--xwidget-padded nil
  "Non-nil means pad the view in this buffer.")

(declare-function xwidget-webkit-browse-url "xwidget" (url &optional new-session))
(declare-function xwidget-webkit-current-session "xwidget" ())
(declare-function xwidget-buffer "xwidget" (xwidget))
(declare-function xwidget-webkit-adjust-size-to-window "xwidget" (xwidget &optional window))
(declare-function xwidget-webkit-uri "xwidget" (xwidget))
(declare-function xwidget-at "xwidget" (pos))
(declare-function xwidget-webkit-execute-script "xwidget" (xwidget script &optional callback))
(declare-function xwidget-webkit-forward "xwidget" ())
(declare-function xwidget-webkit-goto-uri "xwidget" (xwidget uri))

(defun enghi--xwidget-padding (axis)
  "Return the padding for AXIS from `enghi-xwidget-padding'.
AXIS is `horizontal' or `vertical'."
  (let ((pad enghi-xwidget-padding))
    (cond ((consp pad) (if (eq axis 'horizontal) (car pad) (cdr pad)))
          ((integerp pad) pad)
          (t 0))))

(defun enghi--xwidget-shrink-height (height)
  "Shrink view height HEIGHT only in padded buffers.
Used as :filter-return for `xwidget-window-inside-pixel-height'. That function
is called with the target buffer current during size adjustment, so checking
`enghi--xwidget-padded' affects only buffers opened by enghi."
  (if enghi--xwidget-padded
      (max 1 (- height (enghi--xwidget-padding 'vertical)))
    height))

(defvar enghi-xwidget-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "E") #'enghi-xwidget-edit-page)
    ;; GTD list operations are handled by page-side JS. By default, Emacs
    ;; consumes keys in xwidget, so pass only these keys through to the page.
    ;; (Allows pressing them without entering `xwidget-webkit-edit-mode' with
    ;; `e')
    ;; `enghi-xwidget-key' decides per screen what each one does.
    (dolist (key '("j" "k" "RET" "n" "w" "s" "l" "m" "d" "S" "f" "t" "x" "c" "/"
                   "i" "p"))
      (define-key map (kbd key) #'enghi-xwidget-key))
    map)
  "Keymap for webkit buffers opened by enghi.
Since `e' is xwidget's native `xwidget-webkit-edit-mode' (passes keys to the
page), use uppercase rather than overriding it.")

(define-minor-mode enghi-xwidget-mode
  "Minimal mode for webkit buffers opened by enghi.

\\{enghi-xwidget-mode-map}"
  :lighter " enghi"
  :keymap enghi-xwidget-mode-map)

(defun enghi--xwidget-path ()
  "Return enghi path opened in this webkit buffer, or nil for another server.

Check the URL origin as well, since external sites may be viewed in the same
view."
  (when (eq major-mode 'xwidget-webkit-mode)
    (when-let* ((session (xwidget-at (point-min)))
                (uri (ignore-errors (xwidget-webkit-uri session)))
                (parsed (url-generic-parse-url uri))
                (path (car (url-path-and-query parsed)))
                (server (url-generic-parse-url enghi-server-url)))
      (when (and (equal (url-host parsed) (url-host server))
                 (equal (url-port parsed) (url-port server)))
        path))))

(defun enghi--xwidget-slug ()
  "Return slug of the enghi page displayed in this webkit buffer, or nil."
  (when-let* ((path (enghi--xwidget-path)))
    (when (string-match "\\`/wiki/\\([^/]+\\)\\'" path)
      ;; The slug is percent-encoded in the URL
      (decode-coding-string (url-unhex-string (match-string 1 path)) 'utf-8))))

;;;; Sending keys to the page
;;
;; `xwidget-webkit-pass-command-event' does nothing on macOS: the function it
;; relies on (`xwidget-perform-lispy-event') is implemented only for GTK. So
;; dispatch a keydown event with JS instead, which reaches the page's
;; document-level handler (`web/static/app.js') on every platform.

(defun enghi--xwidget-key-name (event)
  "Return the KeyboardEvent `key' value for EVENT."
  (if (memq event '(13 return)) "Enter" (string event)))

(defun enghi--xwidget-key-script (key)
  "Return JS that dispatches a keydown for KEY to the page's document."
  (format "document.dispatchEvent(new KeyboardEvent('keydown', {key: %s, bubbles: true}));"
          (json-encode-string key)))

(defun enghi-xwidget-send-key ()
  "Send the key used to invoke this command to the page as a keydown."
  (interactive)
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   (enghi--xwidget-key-script (enghi--xwidget-key-name last-command-event))))

(defconst enghi--xwidget-gtd-lists
  '(("i" . "/gtd/inbox") ("n" . "/gtd/next") ("w" . "/gtd/waiting")
    ("s" . "/gtd/scheduled") ("m" . "/gtd/someday") ("p" . "/gtd/projects"))
  "Keys on the GTD top page and the lists they open.")

(defun enghi--xwidget-gtd-top-p (path)
  "Return non-nil if PATH is the GTD top page."
  (member path '("/gtd" "/gtd/")))

(defun enghi-xwidget-key ()
  "Handle the key used to invoke this command, according to the screen.

On the GTD top page, keys in `enghi--xwidget-gtd-lists' open that list, `c'
captures from Emacs (`enghi-capture'), and the rest do nothing. Elsewhere the
key goes to the page. `f' stays webkit's forward everywhere except the GTD
lists."
  (interactive)
  (let ((path (or (enghi--xwidget-path) ""))
        (key (enghi--xwidget-key-name last-command-event)))
    (cond ((enghi--xwidget-gtd-top-p path)
           (cond ((equal key "c") (call-interactively #'enghi-capture))
                 ((assoc key enghi--xwidget-gtd-lists)
                  (xwidget-webkit-goto-uri
                   (xwidget-webkit-current-session)
                   (concat (string-remove-suffix "/" enghi-server-url)
                           (cdr (assoc key enghi--xwidget-gtd-lists)))))
                 ((equal key "f") (xwidget-webkit-forward))))
          ((and (equal key "f") (not (string-prefix-p "/gtd" path)))
           (xwidget-webkit-forward))
          (t (enghi-xwidget-send-key)))))

;;;; Header line — show available keys tailored to the screen
;;
;; **Assume keys won't be remembered.** Since GTD state changes are handled
;; by page-side JS (`enghi-xwidget-mode-map' forwards them), show different
;; keys for each screen.

(defconst enghi--xwidget-keys-gtd-top
  '(("i" . "Inbox") ("n" . "Next") ("w" . "Waiting") ("s" . "Scheduled")
    ("m" . "Someday") ("p" . "Projects") ("c" . "Capture"))
  "Keys available on the GTD top page.")

(defconst enghi--xwidget-keys-gtd
  '(("j/k" . "Move") ("RET" . "Open") ("n" . "Next") ("w" . "Waiting")
    ("s" . "Scheduled") ("l" . "Later") ("m" . "Someday") ("d" . "Done")
    ("S" . "Skip") ("f" . "File") ("t" . "Rename") ("x" . "Drop") ("c" . "Capture"))
  "Keys available in the GTD list.")

(defconst enghi--xwidget-keys-page
  '(("E" . "Edit") ("b/f" . "Back/Fwd") ("r" . "Reload") ("+/-" . "Zoom")
    ("e" . "Keys to page"))
  "Keys available when viewing a page.")

(defconst enghi--xwidget-keys-other
  '(("j/k" . "Move") ("RET" . "Open") ("/" . "Search") ("c" . "Capture")
    ("b/f" . "Back/Fwd") ("r" . "Reload"))
  "Keys available on other screens.")

(defun enghi--xwidget-keys-string (keys)
  "Format KEYS (KEY . DESC) into a single line for the header line."
  (mapconcat (lambda (cell)
               (concat (propertize (car cell) 'face 'help-key-binding)
                       " " (propertize (cdr cell) 'face 'shadow)))
             keys
             (propertize "  " 'face 'shadow)))

(defun enghi--xwidget-header ()
  "Return header line content, called via :eval from `header-line-format'."
  (let ((path (enghi--xwidget-path)))
    (concat " "
            (cond ((null path) "")
                  ((enghi--xwidget-gtd-top-p path)
                   (enghi--xwidget-keys-string enghi--xwidget-keys-gtd-top))
                  ((string-prefix-p "/gtd" path)
                   (enghi--xwidget-keys-string enghi--xwidget-keys-gtd))
                  ((string-prefix-p "/wiki/" path)
                   (enghi--xwidget-keys-string enghi--xwidget-keys-page))
                  (t (enghi--xwidget-keys-string enghi--xwidget-keys-other))))))

;;;###autoload
(defun enghi-xwidget-edit-page ()
  "Open the displayed page as an Emacs buffer below this window.

Saving (\\[enghi-save]) broadcasts the update from the server, and the window
above reloads itself (see updated handling in `web/static/app.js')."
  (interactive)
  (let ((slug (or (enghi--xwidget-slug)
                  (user-error "This screen is not an enghi page")))
        ;; Use the window if already open, otherwise show below this window
        (display-buffer-overriding-action
         '((display-buffer-reuse-window display-buffer-below-selected)
           (window-height . 0.5))))
    (enghi-open slug)))

(defun enghi--xwidget-pad (session)
  "Add padding to the current buffer displaying SESSION."
  (unless (or enghi--xwidget-padded
              (and (<= (enghi--xwidget-padding 'horizontal) 0)
                   (<= (enghi--xwidget-padding 'vertical) 0)))
    (setq enghi--xwidget-padded t)
    (let ((cols (round (/ (float (enghi--xwidget-padding 'horizontal))
                          (frame-char-width)))))
      (setq-local left-margin-width cols
                  right-margin-width cols))
    ;; Top padding is created with the header line. Show available keys here
    ;; (so they can be used without memorizing them). Lines or colors would
    ;; keep it from looking like padding, so blend into the background.
    (setq-local header-line-format '(:eval (enghi--xwidget-header)))
    (face-remap-add-relative 'header-line '(:inherit default :box nil :underline nil))
    (unless (advice-member-p #'enghi--xwidget-shrink-height
                             'xwidget-window-inside-pixel-height)
      (advice-add 'xwidget-window-inside-pixel-height :filter-return
                  #'enghi--xwidget-shrink-height)))
  (when-let* ((win (get-buffer-window (current-buffer))))
    ;; Apply margins to the window before remeasuring the view
    (set-window-buffer win (current-buffer))
    (xwidget-webkit-adjust-size-to-window session win)))

;;;###autoload
(defun enghi-browse-in-xwidget (url)
  "Open URL in xwidget webkit, leaving padding around the view.
Use by setting `enghi-browse-function':

  (setq enghi-browse-function #\\='enghi-browse-in-xwidget)

The amount of padding can be changed with `enghi-xwidget-padding'."
  (require 'xwidget)
  (xwidget-webkit-browse-url url)
  (when-let* ((session (xwidget-webkit-current-session))
              (buf (xwidget-buffer session)))
    (with-current-buffer buf
      (enghi-xwidget-mode 1)
      (enghi--xwidget-pad session))))

;;;; ---------------------------------------------------------------- focus

(defun enghi-focus (path)
  "Navigate open browser tabs to PATH (DESIGN.md 4.3).
Intended for workflows where you search and select in Emacs and the browser on
another display follows."
  (interactive "sPath: ")
  (let ((res (enghi-request "POST" "/api/focus" `((path . ,path)))))
    (when (called-interactively-p 'interactive)
      (let ((n (or (alist-get 'clients res) 0)))
        (if (> n 0)
            (message "Navigated to %s (%d clients)" path n)
          (message "Navigated to %s, but no browsers are connected" path))))
    res))

(defun enghi--browse-url-for (path)
  "Build a URL from PATH suitable for passing to a browser.

**Always percent-encode before passing.** Passing a URL containing Japanese as
a raw string leaves the result dependent on how the display function encodes
it. `browse-url' and `xwidget-webkit-browse-url' handle this differently."
  (url-encode-url (enghi--url path)))

(defun enghi--ensure-server ()
  "Ensure the server is reachable, raising a clear error if not.

If you only notice it is down after handing off to the browser, WebKit displays
an error page and the cause cannot be determined."
  (condition-case nil
      (let ((enghi-request-timeout 3))
        (enghi-request "GET" "/api/status")
        t)
    (error
     (user-error "Cannot connect to enghi server (%s).
Check that `enghi serve' is running"
                 enghi-server-url))))

(defun enghi-browse (path)
  "Open PATH with `enghi-browse-function'."
  (enghi--ensure-server)
  (funcall enghi-browse-function (enghi--browse-url-for path)))

;;;; ---------------------------------------------------------- Page editing

(defvar-local enghi-page-slug nil "Slug of the page edited in this buffer.")
(defvar-local enghi-page-version nil "Version when fetched (for optimistic locking).")
(defvar-local enghi-page-title nil "Page title of this buffer.")
(defvar-local enghi-page-tags nil "Tags of the page in this buffer (list of strings).")

(defvar enghi-page-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'enghi-save)
    (define-key map (kbd "C-c C-k") #'enghi-revert-page)
    (define-key map (kbd "C-c C-o") #'enghi-browse-this-page)
    (define-key map (kbd "C-c C-t") #'enghi-set-tags)
    (define-key map (kbd "C-c C-r") #'enghi-rename-page)
    (define-key map (kbd "C-c C-l") #'enghi-insert-link)
    map)
  "Keymap for `enghi-page-mode'.")

;;;###autoload
(define-minor-mode enghi-page-mode
  "Minor mode for editing enghi pages.
Used on top of `markdown-mode'."
  :lighter " enghi"
  :keymap enghi-page-mode-map)

(defun enghi--markdown-mode ()
  "Enable `markdown-mode' if available.
Checking only with `fboundp' misses cases where package.el autoloads are not
yet set up (such as bare `emacs -Q' with only load-path added)."
  (when (or (fboundp 'markdown-mode) (require 'markdown-mode nil t))
    (markdown-mode)))

(defun enghi--page-buffer-name (title)
  (format "*enghi: %s*" title))

(defun enghi--fill-page-buffer (page)
  "Populate current buffer with contents of PAGE (alist)."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (or (alist-get 'body page) ""))
    (goto-char (point-min)))
  (setq enghi-page-slug (alist-get 'slug page)
        enghi-page-version (alist-get 'version page)
        enghi-page-title (alist-get 'title page)
        enghi-page-tags (alist-get 'tags page))
  (set-buffer-modified-p nil)
  (setq header-line-format
        (list (format "%s  v%s" enghi-page-title enghi-page-version)
              (when enghi-page-tags
                (format "  [%s]" (string-join enghi-page-tags ", ")))
              "  C-c C-c Save")))

;;;###autoload
(defun enghi-open (slug)
  "Open page SLUG in an Emacs buffer."
  (interactive (list (enghi--read-page-slug "Open page: ")))
  (let* ((page (enghi-page slug))
         (buf (get-buffer-create (enghi--page-buffer-name (alist-get 'title page)))))
    (with-current-buffer buf
      (enghi--markdown-mode)
      (enghi-page-mode 1)
      (enghi--fill-page-buffer page))
    (pop-to-buffer buf)
    buf))

;;;###autoload
(defun enghi-find-page ()
  "Select and open a page."
  (interactive)
  (enghi-open (enghi--read-page-slug "Page: ")))

;;;###autoload
(defun enghi-open-in-browser ()
  "Select and open a page in the browser (`enghi-browse-function')."
  (interactive)
  (enghi-browse (format "/wiki/%s" (enghi--read-page-slug "Open in browser: "))))

;;;###autoload
(defun enghi-focus-page ()
  "Select a page and navigate open browser tabs to it."
  (interactive)
  (enghi-focus (format "/wiki/%s" (enghi--read-page-slug "Focus in browser: "))))

(defun enghi--read-page-slug (prompt)
  "Prompt for a page with PROMPT and return its slug."
  (let* ((pages (enghi-pages 500))
         (cands (mapcar (lambda (p)
                          (cons (format "%s%s"
                                        (alist-get 'title p)
                                        (if-let* ((tags (alist-get 'tags p)))
                                            (format "  [%s]" (string-join tags ", "))
                                          ""))
                                (alist-get 'slug p)))
                        pages)))
    (unless cands (user-error "No pages yet"))
    (cdr (assoc (completing-read prompt cands nil t) cands))))

(defun enghi-browse-this-page ()
  "Open this buffer's page in the browser."
  (interactive)
  (unless enghi-page-slug (user-error "Not an enghi page buffer"))
  (enghi-browse (format "/wiki/%s" enghi-page-slug)))

(defun enghi-revert-page ()
  "Revert the buffer to server contents."
  (interactive)
  (unless enghi-page-slug (user-error "Not an enghi page buffer"))
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "Discard changes and revert to server contents? "))
    (enghi--fill-page-buffer (enghi-page enghi-page-slug))
    (message "Reverted to server contents")))

(defun enghi-set-tags (tags)
  "Set this page's tags to TAGS (comma-separated)."
  (interactive
   (list (read-string "Tags (comma-separated): " (string-join (or enghi-page-tags '()) ", "))))
  (unless enghi-page-slug (user-error "Not an enghi page buffer"))
  (setq enghi-page-tags
        (seq-remove #'string-empty-p
                    (mapcar #'string-trim (split-string tags "[,、]" t))))
  ;; **Even changing only tags increments version**, so proceed with saving
  ;; (DESIGN.md 4.2).
  (enghi-save))

(defun enghi-rename-page (new-title)
  "Change this page's title to NEW-TITLE."
  (interactive (list (read-string "New title: " enghi-page-title)))
  (unless enghi-page-slug (user-error "Not an enghi page buffer"))
  (setq enghi-page-title new-title)
  (enghi-save))

(defun enghi-insert-link (slug)
  "Select a page and insert [[title]]."
  (interactive (list (enghi--read-page-slug "Link target: ")))
  (let ((page (enghi-page slug)))
    (insert (format "[[%s]]" (alist-get 'title page)))))

(defun enghi-save ()
  "Save this buffer's contents to the server (PUT with optimistic locking).
If 409 is returned, handle it differently depending on the type (DESIGN.md
4.2)."
  (interactive)
  (unless enghi-page-slug (user-error "Not an enghi page buffer"))
  (let ((body (buffer-substring-no-properties (point-min) (point-max))))
    (condition-case err
        (let ((page (enghi-request
                     "PUT" (format "/api/pages/%s" (url-hexify-string enghi-page-slug))
                     `((title . ,enghi-page-title)
                       (body . ,body)
                       (tags . ,(or enghi-page-tags []))
                       (version . ,enghi-page-version)))))
          (setq enghi-page-version (alist-get 'version page)
                enghi-page-slug (alist-get 'slug page)
                enghi-page-title (alist-get 'title page))
          (set-buffer-modified-p nil)
          (setq header-line-format
                (list (format "%s  v%s" enghi-page-title enghi-page-version)
                      (when enghi-page-tags
                        (format "  [%s]" (string-join enghi-page-tags ", ")))
                      "  C-c C-c Save"))
          (message "Saved (v%s)" enghi-page-version))

      ;; **Do not discard input.** Show diff against current data and let the
      ;; user merge.
      (enghi-version-conflict
       (enghi--show-conflict (nth 2 err) body)
       (message "Version conflict. Check the diff and merge."))

      ;; **Keep the body and prompt for a different title.**
      (enghi-title-conflict
       (let ((other (nth 2 err)))
         (message "Page with the same name already exists: %s (/wiki/%s)"
                  (alist-get 'title other) (alist-get 'slug other))
         (setq enghi-page-title
               (read-string "Different title: " enghi-page-title))
         (enghi-save))))))

(defun enghi--show-conflict (current body)
  "Show diff between CURRENT (current server page) and BODY (local content)."
  (let ((server-buf (get-buffer-create "*enghi conflict: server*"))
        (local-buf (get-buffer-create "*enghi conflict: local*")))
    (with-current-buffer server-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or (alist-get 'body current) ""))
        (enghi--markdown-mode)
        (setq header-line-format
              (format "Server side v%s — this is current" (alist-get 'version current)))))
    (with-current-buffer local-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert body)
        (enghi--markdown-mode)
        (setq header-line-format "Local edits — do not discard")))
    (ediff-buffers local-buf server-buf)))

;;;; ---------------------------------------------------------------- capture

;;;###autoload
(defun enghi-capture (title)
  "Add TITLE to the GTD Inbox as a single line, usable from anywhere."
  (interactive "sTo Inbox: ")
  (when (string-empty-p (string-trim title))
    (user-error "Cannot add an empty item"))
  (let ((task (enghi-request "POST" "/api/tasks" `((title . ,title)))))
    (message "Added to Inbox: %s" (alist-get 'title task))
    task))

;;;###autoload
(defun enghi-capture-region (start end)
  "Add the region between START and END to the Inbox.
The first line becomes the title, the rest becomes the note."
  (interactive "r")
  (let* ((text (string-trim (buffer-substring-no-properties start end)))
         (lines (split-string text "\n"))
         (title (car lines))
         (note (string-join (cdr lines) "\n")))
    (enghi-request "POST" "/api/tasks" `((title . ,title) (note . ,note)))
    (message "Added to Inbox: %s" title)))

;;;###autoload
(defun enghi-file-region-as-page (start end title)
  "Create a Wiki page from the region."
  (interactive "r\nsTitle: ")
  (let ((page (enghi-request "POST" "/api/pages"
                             `((title . ,title)
                               (body . ,(buffer-substring-no-properties start end))
                               (tags . [])))))
    (message "Created page: %s" (alist-get 'title page))
    (enghi-open (alist-get 'slug page))))


;;;; ------------------------------------------------------- Entry points

(defvar enghi-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "f") #'enghi-find-page)
    (define-key map (kbd "s") #'enghi-search-command)
    (define-key map (kbd "c") #'enghi-capture)
    (define-key map (kbd "b") #'enghi-open-in-browser)
    (define-key map (kbd "o") #'enghi-focus-page)
    (define-key map (kbd "d") #'enghi-browse-dashboard)
    (define-key map (kbd "n") #'enghi-new-page)
    map)
  "Keymap for enghi commands.
Example:
  (global-set-key (kbd \"C-c n\") enghi-command-map)")

;; Placing the keymap in the symbol's function cell allows keymap autoloading
;; (autoload 'enghi-command-map "enghi" nil nil 'keymap) to bind only the
;; prefix key in advance and load it when pressed. ###autoload (autoload
;; 'enghi-command-map "enghi" nil nil 'keymap)
(defalias 'enghi-command-map enghi-command-map)

;;;###autoload
(defun enghi-search-command ()
  "Search, using consult if available."
  (interactive)
  (if (require 'enghi-consult nil t)
      (call-interactively #'enghi-consult-search)
    ;; Keep it working even in environments without consult
    (let* ((query (read-string "Search enghi: "))
           (results (enghi-search query))
           (cands (mapcar (lambda (r)
                            (cons (format "[%s] %s" (alist-get 'kind r) (alist-get 'title r)) r))
                          results)))
      (unless cands (user-error "No results found"))
      (let ((chosen (cdr (assoc (completing-read "Result: " cands nil t) cands))))
        (if (equal (alist-get 'kind chosen) "page")
            (enghi-open (alist-get 'slug chosen))
          (enghi-browse "/"))))))

;;;###autoload
(defun enghi-new-page (title)
  "Create and open a new page with TITLE."
  (interactive "sNew page title: ")
  (condition-case err
      (let ((page (enghi-request "POST" "/api/pages"
                                 `((title . ,title) (body . "") (tags . [])))))
        (enghi-open (alist-get 'slug page)))
    (enghi-title-conflict
     (let ((other (nth 2 err)))
       (message "A page with the same name already exists: %s" (alist-get 'title other))
       (enghi-open (alist-get 'slug other))))))

;;;###autoload
(defun enghi-browse-dashboard ()
  "Open the dashboard in the browser."
  (interactive)
  (enghi-browse "/"))

;;;###autoload
(defun enghi-setup ()
  "Apply recommended configuration, called from init.el.
(require \='enghi) (enghi-setup)"
  (interactive)
  (autoload 'enghi-consult-search "enghi-consult" nil t)
  (global-set-key (kbd "C-c n") enghi-command-map)
  (message "enghi: available on C-c n (f page / s search / c capture / d dashboard)"))

(provide 'enghi)
;;; enghi.el ends here
