;;; enghi-log.el --- Work log of enghi GTD tasks -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Write the work log of GTD tasks from Emacs: timestamped Markdown entries
;; per task, and the start/pause marks that say which task is being worked on
;; (`/api/tasks/{id}/logs', `/api/task-logs/{id}').
;;
;;   * `enghi-task-log' writes a new entry in a Markdown buffer, like a page.
;;   * `enghi-task-log-edit' / `enghi-task-log-delete' change an entry.
;;   * `enghi-task-start' / `enghi-task-pause' / `enghi-task-toggle' mark it.
;;   * `enghi-code-link' appends a link to the code at point (a permalink from
;;     browse-at-remote, if installed) and the region to the working task.
;;
;; Every command picks the task the same way (`enghi-read-task'): open tasks,
;; the ones being worked on first, with the task shown in xwidget or the only
;; working one as the default.

;;; Code:

(require 'enghi)
(require 'parse-time)
(require 'seq)
(require 'subr-x)

;; browse-at-remote is optional: without it, code links are plain text
(declare-function browse-at-remote-get-url "browse-at-remote" ())
(defvar browse-at-remote-add-line-number-if-no-region-selected)
(declare-function project-root "project" (project))
(declare-function vc-root-dir "vc" ())

;;;; ---------------------------------------------------------------- Errors

(defmacro enghi--with-user-errors (&rest body)
  "Run BODY, turning enghi errors into `user-error's with the server's message.
Version conflicts are left alone, for the caller to show."
  (declare (indent 0) (debug t))
  `(condition-case err
       (progn ,@body)
     (enghi-version-conflict (signal (car err) (cdr err)))
     (enghi-http-error (user-error "%s" (or (nth 2 err) (nth 1 err))))
     (enghi-error (user-error "%s" (error-message-string err)))))

;;;; ---------------------------------------------------------------- Picker

(defconst enghi--open-states '("next" "inbox" "waiting" "scheduled" "later" "someday")
  "Task states that can be worked on, in the order the picker lists them.
Done, dropped and filed tasks are left out.")

(defconst enghi--working-mark "▶"
  "Mark shown before tasks being worked on.")

(defun enghi--open-tasks ()
  "Return open tasks, the ones being worked on first.
Ask per state: listing every task would bring back all the done ones too, and
the server caps a list at 1000."
  (let ((tasks (seq-mapcat
                (lambda (state)
                  (alist-get 'tasks (enghi-request "GET" "/api/tasks" nil
                                                   `((state . ,state) (limit . 1000)))))
                enghi--open-states)))
    (append (seq-filter (lambda (task) (alist-get 'working task)) tasks)
            (seq-remove (lambda (task) (alist-get 'working task)) tasks))))

(defun enghi--xwidget-task-id ()
  "Return the id of the task on an enghi Clarify page, or nil.
Look at the current buffer, then at the buffers shown in this frame."
  (seq-some (lambda (buffer)
              (with-current-buffer buffer
                (when-let* ((path (enghi--xwidget-path)))
                  (when (string-match "\\`/gtd/clarify/\\([0-9]+\\)/?\\'" path)
                    (string-to-number (match-string 1 path))))))
            (delete-dups (cons (current-buffer) (mapcar #'window-buffer (window-list))))))

(defun enghi--default-task-id (tasks)
  "Return the id of the task to offer first among TASKS, or nil.
That is the task shown in xwidget, otherwise the only task being worked on."
  (let ((shown (enghi--xwidget-task-id))
        (working (seq-filter (lambda (task) (alist-get 'working task)) tasks)))
    (cond ((and shown (seq-find (lambda (task) (equal (alist-get 'id task) shown)) tasks))
           shown)
          ((= (length working) 1) (alist-get 'id (car working))))))

(defun enghi--task-candidates (tasks)
  "Return TASKS as an alist of (NAME . TASK) for `completing-read'."
  (let (cands)
    (dolist (task tasks)
      (let ((name (format "%s %s%s"
                          (if (alist-get 'working task) enghi--working-mark " ")
                          (alist-get 'title task)
                          (if-let* ((project (enghi--task-field task 'project_title)))
                              (format "  (%s)" project)
                            ""))))
        ;; Two tasks may have the same title
        (when (assoc name cands)
          (setq name (format "%s  #%s" name (alist-get 'id task))))
        (push (cons name task) cands)))
    (nreverse cands)))

(defun enghi-read-task (prompt)
  "Read an open task with PROMPT and return it (an alist)."
  (let* ((tasks (enghi--with-user-errors (enghi--open-tasks)))
         (cands (or (enghi--task-candidates tasks) (user-error "No open tasks")))
         (default-id (enghi--default-task-id tasks))
         (default (car (seq-find (lambda (c) (equal (alist-get 'id (cdr c)) default-id))
                                 cands)))
         (choice (completing-read prompt
                                  (lambda (string pred action)
                                    ;; Keep the order: working tasks first
                                    (if (eq action 'metadata)
                                        '(metadata (display-sort-function . identity))
                                      (complete-with-action action cands string pred)))
                                  nil t nil nil default)))
    (or (cdr (assoc choice cands)) (user-error "No task chosen"))))

;;;; ---------------------------------------------------------------- Entries

(defun enghi--task-logs (task)
  "Return the work log of TASK, oldest first."
  (alist-get 'logs (enghi--with-user-errors
                     (enghi-request "GET" (format "/api/tasks/%s/logs" (alist-get 'id task))))))

(defun enghi--log-time (log)
  "Return when LOG was written, as local \"YYYY-MM-DD HH:MM\"."
  (let ((utc (alist-get 'created_at log)))
    (condition-case nil
        ;; The server writes \"2006-01-02 15:04:05\" in UTC
        (format-time-string
         "%F %R" (parse-iso8601-time-string
                  (concat (string-replace " " "T" utc) "Z")))
      (error utc))))

(defun enghi--log-label (log)
  "Return a one-line description of LOG for choosing it."
  (let ((first (car (split-string (string-trim (or (alist-get 'body log) "")) "\n"))))
    (string-trim-right
     (format "%s  %s%s" (enghi--log-time log)
            (pcase (alist-get 'kind log)
              ("start" "▶ Started ")
              ("pause" "⏸ Paused ")
              (_ ""))
             (or first "")))))

(defun enghi--read-log (task prompt &optional notes-only)
  "Read an entry of TASK's work log with PROMPT, newest first.
With NOTES-ONLY, leave out the start/pause marks."
  (let* ((logs (reverse (enghi--task-logs task)))
         (logs (if notes-only
                   (seq-filter (lambda (l) (equal (alist-get 'kind l) "note")) logs)
                 logs))
         (cands (mapcar (lambda (l) (cons (enghi--log-label l) l)) logs)))
    (unless cands
      (user-error "No entries in the work log of %s" (enghi--task-title task)))
    (cdr (assoc (completing-read prompt
                                 (lambda (string pred action)
                                   (if (eq action 'metadata)
                                       '(metadata (display-sort-function . identity))
                                     (complete-with-action action cands string pred)))
                                 nil t nil nil (caar cands))
                cands))))

;;;; ---------------------------------------------------------------- Log buffer

(defvar-local enghi-log-task-id nil "Id of the task this buffer logs to.")
(defvar-local enghi-log-task-title nil "Title of the task this buffer logs to.")
(defvar-local enghi-log-id nil "Id of the entry edited here, or nil for a new one.")
(defvar-local enghi-log-version nil "Version of the entry when fetched.")

(defvar enghi-log-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'enghi-log-commit)
    (define-key map (kbd "C-c C-k") #'enghi-log-discard)
    (define-key map (kbd "C-c C-l") #'enghi-insert-link)
    (define-key map (kbd "C-c C-o") #'enghi-log-browse)
    (define-key map (kbd "C-c C-d") #'enghi-task-log-delete)
    map)
  "Keymap for `enghi-log-mode'.")

;;;###autoload
(define-minor-mode enghi-log-mode
  "Minor mode for writing an entry of an enghi task's work log.
Used on top of `markdown-mode'.

\\{enghi-log-mode-map}"
  :lighter " enghi-log"
  :keymap enghi-log-mode-map)

(defun enghi--log-buffer-name (title &optional log-id)
  "Return the buffer name for a new entry of TITLE, or for editing LOG-ID."
  (if log-id
      (format "*enghi log: %s #%s*" title log-id)
    (format "*enghi log: %s*" title)))

(defun enghi--log-header ()
  "Set the header line of this log buffer."
  (setq header-line-format
        (concat (if enghi-log-id
                    (format "%s  (editing v%s)" enghi-log-task-title enghi-log-version)
                  (format "Log: %s" enghi-log-task-title))
                (propertize (concat "  C-c C-c " (if enghi-log-id "Save" "Log")
                                    "  C-c C-k Discard  C-c C-l Link  C-c C-o Open"
                                    (if enghi-log-id "  C-c C-d Delete" ""))
                            'face 'shadow))))

(defun enghi--log-buffer (task &optional log)
  "Return the buffer for a new entry of TASK, or for editing LOG.
An unsent new entry is kept: asking again returns the same buffer."
  (let* ((title (enghi--task-title task))
         (name (enghi--log-buffer-name title (alist-get 'id log)))
         (existing (get-buffer name)))
    (if (and existing (not log))
        existing
      (with-current-buffer (get-buffer-create name)
        (enghi--markdown-mode)
        (enghi-log-mode 1)
        (setq enghi-log-task-id (alist-get 'id task)
              enghi-log-task-title title
              enghi-log-id (alist-get 'id log)
              enghi-log-version (alist-get 'version log))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (or (alist-get 'body log) "")))
        (goto-char (point-min))
        (set-buffer-modified-p nil)
        (enghi--log-header)
        (current-buffer)))))

(defun enghi--log-close ()
  "Kill this log buffer, restoring its window."
  (let ((buffer (current-buffer)))
    (set-buffer-modified-p nil)
    (if-let* ((win (get-buffer-window buffer)))
        (quit-window t win)
      (kill-buffer buffer))))

(defun enghi--check-log-buffer ()
  "Signal a `user-error' unless this is an enghi log buffer."
  (unless enghi-log-task-id (user-error "Not an enghi log buffer")))

(defun enghi--log-path (task-id &optional log-id)
  "Return the path of TASK-ID's Clarify page, at LOG-ID if given."
  (format "/gtd/clarify/%s%s" task-id (if log-id (format "#log-%s" log-id) "")))

(defun enghi-log-commit (&optional browse)
  "Send this entry to the server and close the buffer.
A new entry is added; an edited one is saved with optimistic locking. With
prefix argument BROWSE, then open the entry on the task's Clarify page."
  (interactive "P")
  (enghi--check-log-buffer)
  (let ((body (buffer-substring-no-properties (point-min) (point-max)))
        (task-id enghi-log-task-id)
        (title enghi-log-task-title))
    (when (string-empty-p (string-trim body))
      (user-error "Cannot log an empty entry"))
    (condition-case err
        (let ((log (enghi--with-user-errors
                     (if enghi-log-id
                         (enghi-request "PATCH" (format "/api/task-logs/%s" enghi-log-id)
                                        `((body . ,body) (version . ,enghi-log-version)))
                       (alist-get 'log (enghi-request
                                        "POST" (format "/api/tasks/%s/logs" task-id)
                                        `((kind . "note") (body . ,body))))))))
          (message "%s %s" (if enghi-log-id "Saved the entry of" "Logged to") title)
          (enghi--log-close)
          (when browse
            (enghi-browse (enghi--log-path task-id (alist-get 'id log))))
          log)
      ;; **Do not discard input.** Show the server's text next to ours.
      (enghi-version-conflict
       (enghi--show-conflict (nth 2 err) body)
       (message "Version conflict. Check the diff and merge.")
       nil))))

(defun enghi-log-discard ()
  "Close this log buffer without sending, asking first if it has text."
  (interactive)
  (enghi--check-log-buffer)
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "Discard this entry? "))
    (enghi--log-close)
    (message "Discarded")))

(defun enghi-log-browse ()
  "Open the task's Clarify page, at the entry being edited if any."
  (interactive)
  (enghi--check-log-buffer)
  (enghi-browse (enghi--log-path enghi-log-task-id enghi-log-id)))

;;;; ---------------------------------------------------------------- Commands

;;;###autoload
(defun enghi-task-log (task)
  "Write a new entry in the work log of TASK.
Interactively, pick an open task; the one being worked on comes first."
  (interactive (list (enghi-read-task "Log to task: ")))
  (let ((buffer (enghi--log-buffer task)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun enghi-task-log-edit (task log)
  "Edit LOG, an entry in the work log of TASK."
  (interactive
   (let ((task (enghi-read-task "Edit the log of task: ")))
     (list task (enghi--read-log task "Entry: " t))))
  (let ((buffer (enghi--log-buffer task log)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun enghi-task-log-delete ()
  "Delete an entry of a task's work log, after confirming.
In a buffer editing an entry, delete that one and close the buffer."
  (interactive)
  (if (and enghi-log-task-id (not enghi-log-id))
      (user-error "This entry is not sent yet; discard it with C-c C-k")
    (let* ((editing enghi-log-id)
           (id (or editing
                   (let ((task (enghi-read-task "Delete from the log of task: ")))
                     (alist-get 'id (enghi--read-log task "Delete entry: "))))))
      (when (yes-or-no-p "Delete this entry of the work log? ")
        (enghi--with-user-errors
          (enghi-request "DELETE" (format "/api/task-logs/%s" id)))
        (when editing (enghi--log-close))
        (message "Deleted the entry")
        t))))

(defun enghi--read-comment (arg)
  "Read a one-line comment when ARG (the prefix argument) is non-nil."
  (when arg
    (let ((comment (string-trim (read-string "Comment: "))))
      (unless (string-empty-p comment) comment))))

(defun enghi--task-mark (task kind comment)
  "Mark TASK with KIND (\"start\" or \"pause\") and COMMENT; return a message."
  (let* ((res (enghi--with-user-errors
                (enghi-request "POST" (format "/api/tasks/%s/logs" (alist-get 'id task))
                               `((kind . ,kind) (body . ,(or comment ""))))))
         (title (enghi--task-title task))
         (created (alist-get 'created res))
         (logged (alist-get 'kind (alist-get 'log res))))
    (cond ((not created)
           (if (equal kind "start")
               (format "Already working on %s" title)
             (format "%s is not being worked on" title)))
          ;; A comment on a start/pause that changes nothing becomes a note
          ((equal logged "note")
           (format "%s %s; comment logged" (if (equal kind "start") "Already working on"
                                             "Not working on")
                   title))
          ((equal kind "start") (format "%s Started: %s" enghi--working-mark title))
          (t (format "⏸ Paused: %s" title)))))

;;;###autoload
(defun enghi-task-start (task &optional comment)
  "Start working on TASK. Interactively, a prefix argument asks for COMMENT."
  (interactive (list (enghi-read-task "Start task: ")
                     (enghi--read-comment current-prefix-arg)))
  (message "%s" (enghi--task-mark task "start" comment)))

;;;###autoload
(defun enghi-task-pause (task &optional comment)
  "Pause work on TASK. Interactively, a prefix argument asks for COMMENT."
  (interactive (list (enghi-read-task "Pause task: ")
                     (enghi--read-comment current-prefix-arg)))
  (message "%s" (enghi--task-mark task "pause" comment)))

;;;###autoload
(defun enghi-task-toggle (task &optional comment)
  "Pause TASK if it is being worked on, start it otherwise.
Interactively, a prefix argument asks for COMMENT."
  (interactive (list (enghi-read-task "Start/pause task: ")
                     (enghi--read-comment current-prefix-arg)))
  (message "%s" (enghi--task-mark task (if (alist-get 'working task) "pause" "start")
                                  comment)))

;;;; ---------------------------------------------------------------- Code links
;;
;; Replace the org-capture templates that noted where code was read: append a
;; link to the code (and the code itself) to the working task's log.

(defcustom enghi-code-link-url-function #'enghi--browse-at-remote-url
  "Function returning the URL of the code at point (or the region), or nil.
Without a URL, the code link is written as plain text."
  :type 'function
  :group 'enghi)

(defconst enghi--code-langs
  '(("emacs-lisp" . "elisp") ("lisp-interaction" . "elisp") ("c++" . "cpp")
    ("js" . "javascript") ("sh" . "sh") ("bash" . "bash")
    ("fundamental" . "") ("text" . "") ("prog" . ""))
  "Fenced code block languages for modes whose name is not the language.")

(defun enghi--code-lang (mode)
  "Return the fenced code block language for major MODE (\"\" if unsure)."
  (let ((name (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" (symbol-name mode))))
    (or (cdr (assoc name enghi--code-langs))
        (if (equal name (symbol-name mode)) "" name))))

(defun enghi--browse-at-remote-url ()
  "Return the browse-at-remote URL of the code at point, or nil.
Nil when browse-at-remote is not installed, or the file has no known remote."
  (when (or (featurep 'browse-at-remote) (require 'browse-at-remote nil t))
    (dlet ((browse-at-remote-add-line-number-if-no-region-selected t))
      (ignore-errors (browse-at-remote-get-url)))))

(defun enghi--code-path (file)
  "Return FILE relative to its project or VC root, or abbreviated if neither."
  (let ((root (or (and (require 'project nil t)
                       (when-let* ((project (project-current nil (file-name-directory file))))
                         (project-root project)))
                  (ignore-errors (vc-root-dir)))))
    (if (and root (file-in-directory-p file root))
        (file-relative-name file root)
      (abbreviate-file-name file))))

(defun enghi--dedent (text)
  "Return TEXT with the leading whitespace common to its non-blank lines removed.
Tabs stay tabs: Go code, for one, is indented with them."
  (let* ((lines (split-string text "\n"))
         (prefix nil))
    (dolist (line lines)
      (unless (string-match-p "\\`[ \t]*\\'" line)
        (string-match "\\`[ \t]*" line)
        (let ((indent (match-string 0 line))
              (i 0))
          (if (null prefix)
              (setq prefix indent)
            (while (and (< i (min (length prefix) (length indent)))
                        (eq (aref prefix i) (aref indent i)))
              (setq i (1+ i)))
            (setq prefix (substring prefix 0 i))))))
    (if (member prefix '(nil ""))
        text
      (mapconcat (lambda (line) (string-remove-prefix prefix line)) lines "\n"))))

(defun enghi--code-link-entry ()
  "Return the work log entry linking to the code at point or in the region.
With an active region, the link covers its lines and the lines go in a code
block. Without one, it links to the current line only."
  (unless buffer-file-name (user-error "This buffer is not visiting a file"))
  (let* ((region (use-region-p))
         (beg (if region (region-beginning) (point)))
         ;; A region ending at the start of a line does not include that line,
         ;; as for browse-at-remote
         (end (if region
                  (let ((e (region-end)))
                    (if (and (> e beg) (eq (char-before e) ?\n)) (1- e) e))
                (point)))
         (first (line-number-at-pos beg t))
         (last (line-number-at-pos end t))
         (lines (if (= first last) (format "L%d" first) (format "L%d-%d" first last)))
         (label (format "%s %s" (enghi--code-path buffer-file-name) lines))
         (url (funcall enghi-code-link-url-function)))
    (concat (if url (format "[%s](%s)" label url) label)
            (when region
              (let ((code (save-excursion
                            (buffer-substring-no-properties
                             (progn (goto-char beg) (line-beginning-position))
                             (progn (goto-char end) (line-end-position))))))
                (format "\n\n```%s\n%s\n```" (enghi--code-lang major-mode)
                        (string-trim-right (enghi--dedent code))))))))

;;;###autoload
(defun enghi-code-link (&optional comment)
  "Append a link to the code at point (or the region) to a task's work log.
The picker offers the task being worked on first. With prefix argument
COMMENT, open the entry in a log buffer to add a comment first (see
`enghi-code-link-with-comment')."
  (interactive "P")
  (if comment
      (enghi-code-link-with-comment)
    (let* ((entry (enghi--code-link-entry))
           (task (enghi-read-task "Code link to task: ")))
      (enghi--with-user-errors
        (enghi-request "POST" (format "/api/tasks/%s/logs" (alist-get 'id task))
                       `((kind . "note") (body . ,entry))))
      (deactivate-mark)
      (message "Logged to %s: %s" (enghi--task-title task)
               (car (split-string entry "\n"))))))

;;;###autoload
(defun enghi-code-link-with-comment ()
  "Like `enghi-code-link', but add a comment in a log buffer before sending.
The link goes at the end of the task's unsent entry, if there is one."
  (interactive)
  (let* ((entry (enghi--code-link-entry))
         (task (enghi-read-task "Code link to task: "))
         (buffer (enghi--log-buffer task)))
    (deactivate-mark)
    (with-current-buffer buffer
      (goto-char (point-max))
      (delete-horizontal-space)
      (skip-chars-backward "\n")
      (delete-region (point) (point-max))
      (unless (bobp) (insert "\n\n"))
      (insert entry "\n\n"))
    (pop-to-buffer buffer)
    (goto-char (point-max))
    buffer))

(provide 'enghi-log)
;;; enghi-log.el ends here
