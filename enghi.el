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
(declare-function enghi-consult-read-result "enghi-consult" (&optional prompt initial))

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
(declare-function xwidget-webkit-reload "xwidget" ())
(declare-function org-read-date "org"
                  (&optional with-time to-time from-string prompt
                             default-time default-input inactive))

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
    ;; Keys for the GTD screens. By default, Emacs consumes keys in xwidget,
    ;; so these are either handled in Emacs or passed through to the page.
    ;; (Allows pressing them without entering `xwidget-webkit-edit-mode' with
    ;; `e')
    ;; `enghi-xwidget-key' decides per screen what each one does.
    (dolist (key '("j" "k" "RET" "n" "w" "s" "l" "m" "d" "S" "f" "t" "x" "c" "/"
                   "i" "p" "g"))
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

(defun enghi--xwidget-send-key-name (session key)
  "Send KEY (a KeyboardEvent `key' value) to the page in SESSION."
  (xwidget-webkit-execute-script session (enghi--xwidget-key-script key)))

(defun enghi-xwidget-send-key ()
  "Send the key used to invoke this command to the page as a keydown."
  (interactive)
  (enghi--xwidget-send-key-name (xwidget-webkit-current-session)
                                (enghi--xwidget-key-name last-command-event)))

(defconst enghi--xwidget-gtd-lists
  '(("i" . "/gtd/inbox") ("n" . "/gtd/next") ("w" . "/gtd/waiting")
    ("s" . "/gtd/scheduled") ("m" . "/gtd/someday") ("p" . "/gtd/projects"))
  "Keys on the GTD top page and the lists they open.")

(defun enghi--xwidget-gtd-top-p (path)
  "Return non-nil if PATH is the GTD top page."
  (member path '("/gtd" "/gtd/")))

;;;; Acting on the selected task
;;
;; The GTD lists have a web modal for moving a task, but inside Emacs the
;; minibuffer is the better place to answer it. So the destination keys read
;; the task under the page's cursor (`li.cur', see `moveCursor' in
;; `web/static/app.js'), ask in the minibuffer, write through the JSON API and
;; reload the list with the same row selected. Without a task row, such as in
;; the Projects list, the key goes to the page as before.

(defconst enghi--xwidget-task-actions
  '(("n" . enghi--task-next) ("l" . enghi--task-later)
    ("w" . enghi--task-waiting) ("s" . enghi--task-schedule)
    ("x" . enghi--task-drop) ("f" . enghi--task-file)
    ("t" . enghi--task-rename) ("m" . enghi--task-someday)
    ("d" . enghi--task-done) ("S" . enghi--task-skip)
    ("Enter" . enghi--task-details))
  "Keys acting on the selected task and their functions.
Each function takes the task (see `enghi--xwidget-selected-task-script') and
returns a message after changing it, or nil when the list needs no reload.")

(defconst enghi--xwidget-selected-task-script
  "(function () {
  var li = document.querySelector('ul.rows > li.cur');
  if (!li || !li.dataset.taskId) return '';
  var d = li.dataset;
  var rows = Array.prototype.slice.call(document.querySelectorAll('ul.rows > li'));
  return JSON.stringify({
    id: d.taskId, state: d.state || '', title: d.title || '',
    project_id: d.projectId || '', project_title: d.projectTitle || '',
    context_id: d.contextId || '', waiting_for: d.waitingFor || '',
    scheduled_on: d.scheduledOn || '', recurrence: d.recurrence || '',
    recurrence_ends_on: d.recurrenceEndsOn || '',
    index: rows.indexOf(li), contexts: document.body.dataset.contexts === 'on'
  });
})()"
  "JS returning the task under the cursor as JSON, or \"\" if there is none.
The fields come from the row's data attributes (`web/templates/task_row.html').")

(defvar enghi--xwidget-callbacks nil
  "Script callbacks that WebKit has not called yet.
On macOS, Emacs does not protect the callback given to
`xwidget-webkit-execute-script' from GC (the GTK build does). If GC runs
before WebKit answers, the callback is freed: the answer is dropped, or Emacs
crashes printing it in `xwidget-event-handler'. Holding them here keeps them
alive.")

(defun enghi--xwidget-execute-script (session script callback)
  "Run SCRIPT in SESSION and call CALLBACK with its value, kept safe from GC."
  (let (held)
    (setq held (lambda (value)
                 (setq enghi--xwidget-callbacks (delq held enghi--xwidget-callbacks))
                 (funcall callback value)))
    ;; A script on a page that is going away may never answer. Do not hold on
    ;; to those for ever.
    (setq enghi--xwidget-callbacks (seq-take (cons held enghi--xwidget-callbacks) 16))
    (xwidget-webkit-execute-script session script held)))

(defun enghi--xwidget-task-action (key)
  "Run the action for KEY on the selected task, or send KEY to the page."
  (let ((session (xwidget-webkit-current-session))
        (buffer (current-buffer)))
    (enghi--xwidget-execute-script
     session enghi--xwidget-selected-task-script
     (lambda (json)
       ;; This runs inside the xwidget event handler. Leave it before opening
       ;; the minibuffer.
       (run-at-time 0 nil #'enghi--xwidget-run-task-action
                    session buffer key
                    (and (stringp json) (enghi--parse-json json)))))))

(defun enghi--xwidget-run-task-action (session buffer key task)
  "Run the action for KEY on TASK, shown in SESSION in BUFFER.
With no TASK, send KEY to the page instead."
  (if (null task)
      (enghi--xwidget-send-key-name session key)
    (condition-case err
        (when-let* ((msg (with-current-buffer (if (buffer-live-p buffer)
                                                  buffer
                                                (current-buffer))
                           ;; The last input was the script's xwidget event, a
                           ;; cons, so `y-or-n-p' would take it for a mouse
                           ;; click and open a dialog box
                           (let ((use-dialog-box nil))
                             (funcall (cdr (assoc key enghi--xwidget-task-actions))
                                      task)))))
          (enghi--xwidget-reload-keeping-row session (alist-get 'index task))
          (message "%s" msg))
      (quit (message "Cancelled"))
      ((user-error enghi-error) (message "%s" (error-message-string err))))))

(defun enghi--xwidget-select-row-script (index)
  "Return JS that selects row INDEX once, when the reloaded page is ready.
It does nothing while the old page is still there, or once it has run."
  (format "(function () {
  if (window.__enghiOld || window.__enghiRestored || document.readyState !== 'complete') return;
  window.__enghiRestored = true;
  var list = document.querySelectorAll('ul.rows > li');
  if (!list.length) return;
  var i = Math.min(%d, list.length - 1);
  for (var j = 0; j < list.length; j++) list[j].classList.remove('cur');
  list[i].classList.add('cur');
  list[i].scrollIntoView({block: 'nearest'});
})()" index))

(defun enghi--xwidget-reload-keeping-row (session index)
  "Reload the page in SESSION and select row INDEX again.
The list does not follow task changes made through the API, so reload it
here. The cursor is only a class on the row, so setting it from outside is
enough.

The polling scripts take no callback: a script sent to the page being
unloaded may never answer (see `enghi--xwidget-callbacks'). Instead, the
script itself makes sure it runs once, on the new page."
  (xwidget-webkit-execute-script
   session "window.__enghiOld = true; location.reload();")
  (when index
    (let ((tries 0) timer)
      (setq timer
            (run-at-time
             0.1 0.1
             (lambda ()
               (setq tries (1+ tries))
               (if (> tries 30)
                   (cancel-timer timer)
                 (condition-case nil
                     (xwidget-webkit-execute-script
                      session (enghi--xwidget-select-row-script index))
                   ;; The view is gone
                   (error (cancel-timer timer))))))))))

;;;;; Reading answers

(defconst enghi--none "(none)"
  "Candidate meaning no project or no context.")

(defun enghi--task-field (task key)
  "Return field KEY of TASK, or nil if it is empty."
  (let ((v (alist-get key task)))
    (unless (or (null v) (equal v "")) v)))

(defun enghi--task-number (task key)
  "Return field KEY of TASK (a number in a string) as a number, or nil."
  (when-let* ((v (enghi--task-field task key)))
    (string-to-number v)))

(defun enghi--read-choice (prompt cands current allow-none)
  "Read one of CANDS, an alist of (NAME . ID), with PROMPT.
CURRENT is the ID to offer as the default. With ALLOW-NONE, also offer
`enghi--none'. Return the chosen (NAME . ID), or nil for none."
  (let* ((cands (if allow-none (append cands (list (list enghi--none))) cands))
         (default (or (car (rassoc current cands)) (and allow-none enghi--none)))
         (choice (completing-read prompt cands nil t nil nil default))
         (cell (assoc choice cands)))
    (and cell (cdr cell) cell)))

(defun enghi--read-project (task allow-none)
  "Read an active project for TASK. With ALLOW-NONE, it may be none."
  (let* ((cands (mapcar (lambda (p) (cons (alist-get 'title p) (alist-get 'id p)))
                        (alist-get 'projects
                                   (enghi-request "GET" "/api/projects" nil
                                                  '((status . "active"))))))
         (current (enghi--task-number task 'project_id)))
    ;; The task may belong to a project that is no longer active
    (when (and current (not (rassoc current cands)))
      (push (cons (alist-get 'project_title task) current) cands))
    (unless (or cands allow-none)
      (user-error "No active projects"))
    (or (enghi--read-choice (if allow-none "Project: " "Project (required): ")
                            cands current allow-none)
        (unless allow-none (user-error "A project is required")))))

(defun enghi--read-context (task)
  "Read a context for TASK, or nil for none."
  (enghi--read-choice
   "Context: "
   (delq nil (mapcar (lambda (c)
                       (unless (alist-get 'archived c)
                         (cons (alist-get 'name c) (alist-get 'id c))))
                     (alist-get 'contexts (enghi-request "GET" "/api/contexts"))))
   (enghi--task-number task 'context_id) t))

(defun enghi--date-time (date)
  "Return DATE (YYYY-MM-DD) as a Lisp time, or nil if it is not one."
  (when (and date (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\'" date))
    (encode-time (list 0 0 0
                       (string-to-number (match-string 3 date))
                       (string-to-number (match-string 2 date))
                       (string-to-number (match-string 1 date))
                       nil -1 nil))))

(defun enghi--read-date (prompt current)
  "Read a date with PROMPT, defaulting to CURRENT (YYYY-MM-DD) or today."
  (require 'org)
  (org-read-date nil nil nil prompt (enghi--date-time current)))

(defconst enghi--no-repeat "Does not repeat"
  "Candidate meaning a task that does not repeat.")

(defun enghi--repeat-presets (date)
  "Return repeat rules that fit DATE, as an alist of (RULE . DESCRIPTION).
The syntax is ParseRecurrence's (`internal/gtd/recurrence.go')."
  (let* ((decoded (decode-time (enghi--date-time date)))
         (dow (nth (decoded-time-weekday decoded)
                   '("sun" "mon" "tue" "wed" "thu" "fri" "sat")))
         (day (decoded-time-day decoded))
         (month (decoded-time-month decoded)))
    `(("+1d" . "every day")
      ("+1w" . "every week")
      (,(format "weekly:%s" dow) . ,(format "every %s" (capitalize dow)))
      ("+1m" . "every month")
      (,(format "monthly:%d" day) . ,(format "on day %d of every month" day))
      ("+1y" . "every year")
      (,(format "yearly:%02d-%02d" month day) . "on this date every year"))))

(defun enghi--read-repeat (date current)
  "Read a repeat rule for a task scheduled on DATE.
CURRENT is the task's rule. Any rule may be typed; the server validates it.
Return \"\" for no repeat."
  (let* ((presets (enghi--repeat-presets date))
         (cands (append (list (cons enghi--no-repeat ""))
                        (when (and current (not (assoc current presets)))
                          (list (cons current "current rule")))
                        presets))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (c) (when-let* ((d (cdr (assoc c cands))))
                           (unless (equal d "") (concat "  " d))))))
         (rule (string-trim
                (completing-read "Repeat: " cands nil nil nil nil
                                 (or current enghi--no-repeat)))))
    (if (member rule (list "" enghi--no-repeat)) "" rule)))

;;;;; The actions

(defun enghi--patch-task (task fields)
  "Update TASK with FIELDS (an alist) and return the updated task."
  (enghi-request "PATCH" (format "/api/tasks/%s" (alist-get 'id task)) fields))

(defun enghi--task-post (task action payload)
  "POST PAYLOAD to ACTION (such as \"complete\") of TASK."
  (enghi-request "POST" (format "/api/tasks/%s/%s" (alist-get 'id task) action)
                 payload))

(defun enghi--task-title (task)
  "Return the title of TASK for messages."
  (alist-get 'title task))

(defun enghi--task-next (task)
  "Move TASK to Next, asking for its project and context."
  (let* ((project (enghi--read-project task t))
         (context (when (eq (alist-get 'contexts task) t)
                    (list (enghi--read-context task)))))
    (enghi--patch-task
     task `((state . "next")
            ,(if project `(project_id . ,(cdr project)) '(clear_project . t))
            ,@(when context
                (list (if (car context)
                          `(context_id . ,(cdar context))
                        '(clear_context . t))))))
    (format "→ Next: %s%s" (enghi--task-title task)
            (if project (format " (%s)" (car project)) ""))))

(defun enghi--task-later (task)
  "Move TASK to Later, asking for its project."
  (let ((project (enghi--read-project task nil)))
    (enghi--patch-task task `((state . "later") (project_id . ,(cdr project))))
    (format "→ Later: %s (%s)" (enghi--task-title task) (car project))))

(defun enghi--task-waiting (task)
  "Move TASK to Waiting, asking who it waits for."
  (let ((who (string-trim (read-string "Waiting for: "
                                       (enghi--task-field task 'waiting_for)))))
    (when (string-empty-p who)
      (user-error "Say who or what the task is waiting for"))
    (enghi--patch-task task `((state . "waiting") (waiting_for . ,who)))
    (format "→ Waiting: %s (for %s)" (enghi--task-title task) who)))

(defun enghi--task-schedule (task)
  "Schedule TASK, asking for the date and how it repeats."
  (let* ((date (enghi--read-date "Date: " (enghi--task-field task 'scheduled_on)))
         (rule (enghi--read-repeat date (enghi--task-field task 'recurrence)))
         (ends (if (and (not (string-empty-p rule))
                        (y-or-n-p "Stop repeating on a date? "))
                   (enghi--read-date "Last date: "
                                     (enghi--task-field task 'recurrence_ends_on))
                 "")))
    ;; Empty strings clear the rule and its end, as the web picker does
    (enghi--patch-task task `((state . "scheduled") (scheduled_on . ,date)
                              (recurrence . ,rule) (recurrence_ends_on . ,ends)))
    (format "→ Scheduled: %s (%s%s%s)" (enghi--task-title task) date
            (if (string-empty-p rule) "" (concat ", " rule))
            (if (string-empty-p ends) "" (concat " until " ends)))))

(defun enghi--task-drop (task)
  "Drop TASK after confirming."
  (if (not (y-or-n-p (format "Drop \"%s\"? " (enghi--task-title task))))
      (progn (message "Cancelled") nil)
    (enghi--patch-task task '((state . "dropped")))
    (format "Dropped: %s" (enghi--task-title task))))

(defun enghi--task-file (task)
  "File TASK as a wiki page, then open the page below the list."
  (let* ((title (string-trim (read-string "Page title: " (enghi--task-title task))))
         (tags (completing-read-multiple
                "Tags (comma-separated, may be empty): "
                (mapcar (lambda (tag) (alist-get 'name tag))
                        (alist-get 'tags (enghi-request "GET" "/api/tags")))))
         (res (enghi--task-post task "file" `((title . ,title) (body . "")
                                              (tags . ,(vconcat tags)))))
         (page (alist-get 'page res)))
    (when-let* ((win (get-buffer-window)))
      (select-window win))
    (enghi--open-below (alist-get 'slug page))
    (format "Filed: %s → %s" (enghi--task-title task) (alist-get 'title page))))

(defun enghi--task-rename (task)
  "Rename TASK."
  (let ((title (string-trim (read-string "Title: " (enghi--task-title task)))))
    (cond ((string-empty-p title) (user-error "The title cannot be empty"))
          ((equal title (enghi--task-title task)) (message "Unchanged") nil)
          (t (enghi--patch-task task `((title . ,title)))
             (format "Renamed: %s" title)))))

(defun enghi--task-someday (task)
  "Move TASK to Someday."
  (enghi--patch-task task '((state . "someday")))
  (format "→ Someday: %s" (enghi--task-title task)))

(defun enghi--task-completed-message (verb task res)
  "Return a message for TASK completed with VERB, from the response RES."
  (let ((next (enghi--task-field (alist-get 'next res) 'scheduled_on)))
    (format "%s: %s%s" verb (enghi--task-title task)
            (if next (format " (next: %s)" next) ""))))

(defun enghi--task-done (task)
  "Complete TASK. A recurring task gets its next instance."
  (enghi--task-completed-message
   "Done" task (enghi--task-post task "complete" (make-hash-table))))

(defun enghi--task-skip (task)
  "Skip this instance of recurring TASK."
  (if (not (enghi--task-field task 'recurrence))
      (progn (message "Not a recurring task") nil)
    (enghi--task-completed-message
     "Skipped" task (enghi--task-post task "complete" '((skip . t))))))

(defun enghi--task-details (task)
  "Open the detail page of TASK in this view."
  (xwidget-webkit-goto-uri
   (xwidget-webkit-current-session)
   (enghi--url (format "/gtd/clarify/%s" (alist-get 'id task))))
  nil)

(defun enghi--xwidget-task-list-p (path)
  "Return non-nil if PATH is a GTD screen that may list tasks."
  (and (string-prefix-p "/gtd/" path) (not (enghi--xwidget-gtd-top-p path))))

(defun enghi--xwidget-capture (path)
  "Capture to the Inbox from Emacs, then refresh PATH if it is a GTD screen."
  (call-interactively #'enghi-capture)
  ;; The page does not follow task updates, so refresh GTD screens ourselves
  (when (string-prefix-p "/gtd" path)
    (xwidget-webkit-reload)))

(defun enghi--xwidget-search ()
  "Search from Emacs and show the chosen result in this view."
  (let ((session (xwidget-webkit-current-session)))
    (when-let* ((result (enghi-read-search-result))
                (path (enghi--result-path result)))
      (xwidget-webkit-goto-uri session (enghi--browse-url-for path)))))

(defun enghi-xwidget-key ()
  "Handle the key used to invoke this command, according to the screen.

On every enghi screen, `c' captures from Emacs (`enghi-capture') and `/'
searches from Emacs, showing the result in this view. On the dashboard
\(`/'), `g' opens the GTD top page; everywhere else `g' stays
`xwidget-webkit-browse-url'. On the GTD top page,
keys in `enghi--xwidget-gtd-lists' open that list and the rest do nothing.
On the other GTD screens, keys in `enghi--xwidget-task-actions' act on the
selected task from Emacs (`enghi--xwidget-task-action'). Elsewhere the key
goes to the page. `f' stays webkit's forward everywhere except the GTD
lists."
  (interactive)
  (let* ((enghi-path (enghi--xwidget-path))
         (path (or enghi-path ""))
         (key (enghi--xwidget-key-name last-command-event)))
    (cond ((and enghi-path (equal key "c")) (enghi--xwidget-capture path))
          ((and enghi-path (equal key "/")) (enghi--xwidget-search))
          ((equal key "g")
           (if (equal enghi-path "/")
               (xwidget-webkit-goto-uri
                (xwidget-webkit-current-session)
                (concat (string-remove-suffix "/" enghi-server-url) "/gtd"))
             (call-interactively #'xwidget-webkit-browse-url)))
          ((enghi--xwidget-gtd-top-p path)
           (cond ((assoc key enghi--xwidget-gtd-lists)
                  (xwidget-webkit-goto-uri
                   (xwidget-webkit-current-session)
                   (concat (string-remove-suffix "/" enghi-server-url)
                           (cdr (assoc key enghi--xwidget-gtd-lists)))))
                 ((equal key "f") (xwidget-webkit-forward))))
          ((and (enghi--xwidget-task-list-p path)
                (assoc key enghi--xwidget-task-actions))
           (enghi--xwidget-task-action key))
          ((and (equal key "f") (not (string-prefix-p "/gtd" path)))
           (xwidget-webkit-forward))
          (t (enghi-xwidget-send-key)))))

;;;; Header line — show available keys tailored to the screen
;;
;; **Assume keys won't be remembered.** What a key does depends on the screen
;; (see `enghi-xwidget-key'), so show different keys for each screen.

(defconst enghi--xwidget-keys-gtd-top
  '(("i" . "Inbox") ("n" . "Next") ("w" . "Waiting") ("s" . "Scheduled")
    ("m" . "Someday") ("p" . "Projects") ("c" . "Capture") ("/" . "Search"))
  "Keys available on the GTD top page.")

(defconst enghi--xwidget-keys-gtd
  '(("j/k" . "Move") ("RET" . "Details") ("n" . "Next") ("w" . "Waiting")
    ("s" . "Scheduled") ("l" . "Later") ("m" . "Someday") ("d" . "Done")
    ("S" . "Skip") ("f" . "File") ("t" . "Rename") ("x" . "Drop") ("c" . "Capture")
    ("/" . "Search"))
  "Keys available in the GTD list.")

(defconst enghi--xwidget-keys-page
  '(("E" . "Edit") ("c" . "Capture") ("/" . "Search") ("b/f" . "Back/Fwd")
    ("r" . "Reload") ("+/-" . "Zoom"))
  "Keys available when viewing a page.")

(defconst enghi--xwidget-keys-other
  '(("j/k" . "Move") ("RET" . "Open") ("/" . "Search") ("c" . "Capture")
    ("b/f" . "Back/Fwd") ("r" . "Reload"))
  "Keys available on other screens.")

(defconst enghi--xwidget-keys-dashboard
  (append enghi--xwidget-keys-other '(("g" . "GTD")))
  "Keys available on the dashboard.")

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
                  ((equal path "/")
                   (enghi--xwidget-keys-string enghi--xwidget-keys-dashboard))
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
  (enghi--open-below (or (enghi--xwidget-slug)
                         (user-error "This screen is not an enghi page"))))

(defun enghi--open-below (slug)
  "Open page SLUG in the window below the selected one."
  ;; Use the window if already open, otherwise show below this window
  (let ((display-buffer-overriding-action
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

;; The work log lives in enghi-log.el, loaded on first use
(autoload 'enghi-task-log "enghi-log" nil t)
(autoload 'enghi-task-log-edit "enghi-log" nil t)
(autoload 'enghi-task-log-delete "enghi-log" nil t)
(autoload 'enghi-task-start "enghi-log" nil t)
(autoload 'enghi-task-pause "enghi-log" nil t)
(autoload 'enghi-task-toggle "enghi-log" nil t)
(autoload 'enghi-code-link "enghi-log" nil t)
(autoload 'enghi-code-link-with-comment "enghi-log" nil t)

(defvar enghi-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "f") #'enghi-find-page)
    (define-key map (kbd "s") #'enghi-search-command)
    (define-key map (kbd "c") #'enghi-capture)
    (define-key map (kbd "b") #'enghi-open-in-browser)
    (define-key map (kbd "o") #'enghi-focus-page)
    (define-key map (kbd "d") #'enghi-browse-dashboard)
    (define-key map (kbd "D") #'enghi-day)
    (define-key map (kbd "n") #'enghi-new-page)
    ;; Work log (enghi-log.el)
    (define-key map (kbd "l") #'enghi-task-log)
    (define-key map (kbd "L") #'enghi-task-log-edit)
    (define-key map (kbd "r") #'enghi-code-link)
    (define-key map (kbd "R") #'enghi-code-link-with-comment)
    (define-key map (kbd "t") #'enghi-task-toggle)
    map)
  "Keymap for enghi commands.
Example:
  (global-set-key (kbd \"C-c n\") enghi-command-map)")

;; Placing the keymap in the symbol's function cell allows keymap autoloading
;; (autoload 'enghi-command-map "enghi" nil nil 'keymap) to bind only the
;; prefix key in advance and load it when pressed. ###autoload (autoload
;; 'enghi-command-map "enghi" nil nil 'keymap)
(defalias 'enghi-command-map enghi-command-map)

(defun enghi--result-path (result)
  "Return the path that shows search RESULT, or nil for an unknown kind."
  (pcase (alist-get 'kind result)
    ("page" (format "/wiki/%s" (alist-get 'slug result)))
    ("project" (format "/gtd/project/%s" (alist-get 'id result)))
    ("task" (format "/gtd/clarify/%s" (alist-get 'id result)))
    ("area" (format "/gtd/area/%s" (alist-get 'id result)))
    ;; A work log entry, on its task's Clarify page
    ("log" (format "/gtd/clarify/%s#log-%s" (alist-get 'task_id result) (alist-get 'id result)))))

(defun enghi-read-search-result (&optional prompt)
  "Search enghi with PROMPT and return the chosen result, or nil.
Use consult if available, searching on every keystroke."
  (if (require 'enghi-consult nil t)
      (enghi-consult-read-result prompt)
    ;; Keep it working even in environments without consult
    (let* ((query (read-string (or prompt "Search enghi: ")))
           (cands (mapcar (lambda (r)
                            (cons (format "[%s] %s" (alist-get 'kind r) (alist-get 'title r)) r))
                          (enghi-search query))))
      (unless cands (user-error "No results found"))
      (cdr (assoc (completing-read "Result: " cands nil t) cands)))))

(defun enghi-visit-result (result)
  "Open search RESULT: a page in an Emacs buffer, anything else in a browser."
  (let ((path (enghi--result-path result)))
    (cond ((equal (alist-get 'kind result) "page")
           (enghi-open (alist-get 'slug result)))
          (path (enghi-browse path))
          (t (message "Cannot open kind: %s" (alist-get 'kind result))))))

;;;###autoload
(defun enghi-search-command ()
  "Search, using consult if available, and open the chosen result."
  (interactive)
  (when-let* ((result (enghi-read-search-result)))
    (enghi-visit-result result)))

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

(defun enghi--read-day-string ()
  "Read a date as YYYY-MM-DD with `read-string', defaulting to today."
  (let* ((today (format-time-string "%F"))
         (date (string-trim (read-string (format "Day (default %s): " today)
                                         nil nil today))))
    (unless (enghi--date-time date)
      (user-error "Not a date (YYYY-MM-DD): %s" date))
    date))

(defun enghi--read-day ()
  "Read a date as YYYY-MM-DD, with org's calendar when org is available."
  (if (require 'org nil t)
      (org-read-date nil nil nil "Day: ")
    (enghi--read-day-string)))

;;;###autoload
(defun enghi-day (&optional date)
  "Open the work record page of DATE (YYYY-MM-DD), or of today.
Interactively, with a prefix argument, ask for the date."
  (interactive (list (when current-prefix-arg (enghi--read-day))))
  (enghi-browse (if date (format "/gtd/day/%s" date) "/gtd/day")))

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
