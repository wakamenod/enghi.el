;;; enghi-triage.el --- Sort enghi GTD tasks from Emacs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Sort GTD tasks without taking a window. One key acts on a task, and the
;; questions it asks (project, date, who to wait for) are the minibuffer
;; prompts of the GTD lists in xwidget: the actions are the same functions
;; (`enghi--task-next' and the others in enghi.el).
;;
;; `enghi-task-list' shows the GTD lists, Inbox first: j/k choose a task, Tab
;; goes to the next list, and the action keys act on the chosen task.
;;
;; `.' starts working on the task, moving it to Next first if it is
;; elsewhere (`enghi--task-start-now'). The server pauses the task that was
;; being worked on.
;;
;; `p' makes the task a project of its own and keeps it as the project's first
;; next action (`enghi--triage-to-project').
;;
;; The last list holds the active projects, those with no next action marked.
;; Its keys act on the project (`enghi--triage-project-actions').
;;
;; It shows in the echo area, or with `enghi-triage-display' set to
;; `posframe', in a child frame: by default in the middle of the frame, where
;; a posframe completion UI such as vertico-posframe asks its questions. The
;; child frame takes no input; the keys are read in the frame below it, as
;; vertico-posframe does. It hides while a question is asked, so the two take
;; turns in one place.

;;; Code:

(require 'enghi)
(require 'enghi-log)
(require 'parse-time)
(require 'seq)
(require 'subr-x)

;; posframe is optional: without it, the menu is in the echo area
(declare-function enghi-peek-available-p "enghi-peek" ())
(declare-function enghi-peek-read "enghi-peek" (path))
(declare-function posframe-show "posframe" (buffer-or-name &rest args))
(declare-function posframe-hide "posframe" (buffer-or-name))
(declare-function posframe-workable-p "posframe" ())
(declare-function posframe-poshandler-frame-center "posframe" (info))

(defcustom enghi-triage-display 'echo-area
  "Where the task list and the action keys show.
`echo-area', or `posframe' for a child frame placed by
`enghi-triage-posframe-poshandler', with the look of
`enghi-posframe-border-width' and `enghi-posframe-border'. `posframe' needs
the posframe package and a graphical frame; without them the echo area is
used."
  :type '(choice (const :tag "Echo area" echo-area)
                 (const :tag "Child frame (posframe)" posframe))
  :group 'enghi)

(defcustom enghi-triage-posframe-poshandler #'enghi-triage-poshandler-top-center
  "Function placing the posframe; see `posframe-show'.
By default the top stays at `enghi-triage-posframe-top', so a taller list
grows downward."
  :type 'function
  :group 'enghi)

(defcustom enghi-triage-posframe-top 0.1
  "Where `enghi-triage-poshandler-top-center' puts the top of the posframe.
A fraction of the frame's height, from its top."
  :type 'float
  :group 'enghi)

(defcustom enghi-task-list-title-width 48
  "Columns the task titles take in `enghi-task-list'.
A longer title is cut with an ellipsis. The list is this much wider."
  :type 'integer
  :group 'enghi)

(defcustom enghi-task-list-side-width 20
  "Columns the right column takes in `enghi-task-list'.
It holds the project, the date, who a task waits for or when it was
captured; a longer one is cut with an ellipsis."
  :type 'integer
  :group 'enghi)

(defcustom enghi-task-list-height 15
  "Number of tasks `enghi-task-list' shows at a time."
  :type 'integer
  :group 'enghi)

(defconst enghi--triage-buffer " *enghi-triage*"
  "Buffer shown in the posframe.")

(defconst enghi--triage-actions
  '((?n "Next" enghi--task-next)
    (?p "Project" enghi--triage-to-project)
    (?l "Later" enghi--task-later)
    (?w "Waiting" enghi--task-waiting)
    (?s "Scheduled" enghi--task-schedule)
    (?m "Someday" enghi--task-someday)
    (?d "Done" enghi--task-done)
    (?S "Skip" enghi--task-skip)
    (?x "Drop" enghi--task-drop)
    (?f "File" enghi--triage-file)
    (?t "Rename" enghi--task-rename)
    (?. "Start" enghi--task-start-now)
    (?o "Open URL" enghi--task-open-url)
    (?\r "Details" enghi--triage-details))
  "Action keys, as (KEY LABEL FUNCTION).
Each function takes the task and returns a message after changing it, or nil
when nothing changed, like those in `enghi--xwidget-task-actions'.")

(defconst enghi--triage-columns
  '(("Move to" ?n ?p ?l ?w ?s ?m)
    ("Finish" ?d ?S ?x)
    ("Task" ?. ?t ?f)
    ("View" ?\r ?o))
  "The action keys in columns, each a heading and keys of `enghi--triage-actions'.")

(defconst enghi--triage-project-actions
  '((?a "Add next" enghi--triage-project-add-next)
    (?t "Rename" enghi--triage-project-rename)
    (?d "Done" enghi--triage-project-done)
    (?m "Someday" enghi--triage-project-someday)
    (?x "Drop" enghi--triage-project-drop)
    (?o "Open URL" enghi--task-open-url)
    (?\r "Details" enghi--triage-project-details))
  "Action keys on the list of projects, as in `enghi--triage-actions'.
Each function takes the project.")

(defconst enghi--triage-project-columns
  '(("Project" ?a ?t)
    ("Status" ?d ?m ?x)
    ("View" ?\r ?o))
  "The keys of `enghi--triage-project-actions' in columns.")

(defface enghi-triage-key
  '((((type graphic)) :inherit help-key-binding :box (:line-width (1 . -1) :color "gray50"))
    (t :inherit help-key-binding))
  "Face of the keys in the task lists, drawn as keycaps on a graphical frame."
  :group 'enghi)

(defface enghi-triage-heading
  '((t :inherit (font-lock-keyword-face bold)))
  "Face of the headings over the keys in the task lists."
  :group 'enghi)

;;;; ---------------------------------------------------------------- Actions
;;
;; The two actions whose xwidget versions act on the view.

(defun enghi--triage-file (task)
  "File TASK as a wiki page. Unlike on the list in xwidget, the page is not opened."
  (let ((page (enghi--file-task task)))
    (format "Filed: %s → %s" (enghi--task-title task) (alist-get 'title page))))

(defun enghi--triage-details-path (path)
  "Show PATH on the server in the peek, over the list.
The list comes back when the peek closes. Without what the peek needs
\(posframe and xwidgets), open it with `enghi-browse' instead."
  (if (and (require 'enghi-peek nil t) (enghi-peek-available-p))
      (enghi-peek-read path)
    (enghi-browse path))
  nil)

(defun enghi--triage-details (task)
  "Show the detail page of TASK in the peek; see `enghi--triage-details-path'."
  (enghi--triage-details-path (format "/gtd/clarify/%s" (alist-get 'id task))))

(defun enghi--triage-read-title (prompt default)
  "Read a title with PROMPT, offering DEFAULT. It may not be empty."
  (let ((title (string-trim (read-string prompt default))))
    (if (string-empty-p title) (user-error "The title cannot be empty") title)))

(defun enghi--triage-to-project (task)
  "Make TASK a project of its own, keeping TASK as its first next action.
Ask for the project's title and outcome, then for the next action, which
may reword TASK, and its context. Nothing is made until every answer is
in, so a question cancelled leaves no project without a next action."
  (let* ((title (enghi--triage-read-title "Project title: " (enghi--task-title task)))
         (outcome (string-trim (read-string "Outcome (optional): ")))
         (action (enghi--triage-read-title "Next action: " (enghi--task-title task)))
         (context (enghi--read-context-field task))
         (project (enghi-request "POST" "/api/projects"
                                 `((title . ,title) (outcome . ,outcome)))))
    (enghi--patch-task task `((state . "next") (project_id . ,(alist-get 'id project))
                              ,@(unless (equal action (enghi--task-title task))
                                  `((title . ,action)))
                              ,@context))
    (format "→ Project: %s (next: %s)" (alist-get 'title project) action)))

;;;; ---------------------------------------------------------------- Project actions
;;
;; On the list of projects. Each takes the project and returns a message, as
;; the task actions do.

(defun enghi--triage-patch-project (project fields)
  "Update PROJECT with FIELDS (an alist) and return the updated project."
  (enghi-request "PATCH" (format "/api/projects/%s" (alist-get 'id project)) fields))

(defun enghi--triage-project-add-next (project)
  "Add a next action to PROJECT, asking for it and its context."
  (let* ((title (enghi--triage-read-title "Next action: " nil))
         (context (enghi--read-context-field project))
         ;; Captured first: if the move fails, the task waits in the Inbox
         (task (enghi-request "POST" "/api/tasks" `((title . ,title)))))
    (enghi--patch-task task `((state . "next") (project_id . ,(alist-get 'id project))
                              ,@context))
    (format "+ Next: %s (%s)" title (alist-get 'title project))))

(defun enghi--triage-project-rename (project)
  "Rename PROJECT."
  (let ((title (enghi--triage-read-title "Title: " (alist-get 'title project))))
    (if (equal title (alist-get 'title project))
        (progn (message "Unchanged") nil)
      (enghi--triage-patch-project project `((title . ,title)))
      (format "Renamed: %s" title))))

(defun enghi--triage-project-done (project)
  "Mark PROJECT done."
  (enghi--triage-patch-project project '((status . "done")))
  (format "Done: %s" (alist-get 'title project)))

(defun enghi--triage-project-someday (project)
  "Move PROJECT to Someday, with a review date if one is wanted.
Once the date has come, the project shows in the weekly review."
  (let ((review (when (y-or-n-p "Set a review date? ")
                  (enghi--read-date "Review on: " (enghi--task-field project 'review_on)))))
    (enghi--triage-patch-project project `((status . "someday")
                                           ,@(when review `((review_on . ,review)))))
    (format "→ Someday: %s%s" (alist-get 'title project)
            (if review (format " (review: %s)" review) ""))))

(defun enghi--triage-project-drop (project)
  "Drop PROJECT after confirming."
  (if (not (y-or-n-p (format "Drop project \"%s\"? " (alist-get 'title project))))
      (progn (message "Cancelled") nil)
    (enghi--triage-patch-project project '((status . "dropped")))
    (format "Dropped: %s" (alist-get 'title project))))

(defun enghi--triage-project-details (project)
  "Show the page of PROJECT in the peek, as `enghi--triage-details' does."
  (enghi--triage-details-path (format "/gtd/project/%s" (alist-get 'id project))))

;;;; ---------------------------------------------------------------- Display

(defun enghi--triage-key-name (key)
  "Return how KEY is written in the menu."
  (pcase key (?\r "RET") (?\t "Tab") (?\s "SPC") ((pred stringp) key) (_ (string key))))

(defun enghi--triage-keycap (key)
  "Return KEY as a keycap."
  (propertize (format " %s " (enghi--triage-key-name key)) 'face 'enghi-triage-key))

(defun enghi--triage-pad (string width)
  "Return STRING padded with spaces to WIDTH columns."
  (concat string (make-string (max 0 (- width (string-width string))) ?\s)))

(defun enghi--triage-key-row (keys)
  "Return KEYS, a list of (KEY LABEL ...), as one row."
  (mapconcat (lambda (k)
               (concat (enghi--triage-keycap (car k)) " " (propertize (cadr k) 'face 'shadow)))
             keys "   "))

(defun enghi--triage-keys (actions columns)
  "Return the keys of ACTIONS in COLUMNS, as `enghi--triage-columns' lays them.
Each column has its heading on top, and its keys and labels line up."
  (let* ((columns
          (mapcar (lambda (column)
                    (let* ((actions (mapcar (lambda (key) (assq key actions))
                                            (cdr column)))
                           (cap (apply #'max (mapcar (lambda (a) (string-width
                                                                  (enghi--triage-keycap (car a))))
                                                     actions))))
                      (cons (propertize (car column) 'face 'enghi-triage-heading)
                            (mapcar (lambda (a)
                                      (concat (enghi--triage-pad (enghi--triage-keycap (car a)) cap)
                                              " " (cadr a)))
                                    actions))))
                  columns))
         (widths (mapcar (lambda (column) (apply #'max (mapcar #'string-width column))) columns)))
    (mapconcat (lambda (row)
                 (string-trim-right
                  (concat " " (mapconcat (lambda (cell)
                                           (enghi--triage-pad (or (nth row (car cell)) "")
                                                              (+ (cdr cell) 4)))
                                         (seq-mapn #'cons columns widths) ""))))
               (number-sequence 0 (1- (apply #'max (mapcar #'length columns))))
               "\n")))

(defun enghi-triage-poshandler-top-center (info)
  "Place a posframe in the middle of the frame across, with its top fixed.
The top is `enghi-triage-posframe-top' of the frame's height down, so a
taller posframe grows downward. INFO is what `posframe-show' passes."
  (cons (max 0 (/ (- (plist-get info :parent-frame-width) (plist-get info :posframe-width)) 2))
        (round (* (plist-get info :parent-frame-height) enghi-triage-posframe-top))))

(defun enghi--triage-posframe-p ()
  "Return non-nil if the menu goes in a posframe."
  (and (eq enghi-triage-display 'posframe)
       (require 'posframe nil t)
       (posframe-workable-p)))

(defun enghi--triage-show (menu)
  "Show MENU in the posframe."
  (with-current-buffer (get-buffer-create enghi--triage-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert menu)))
  (apply #'posframe-show enghi--triage-buffer
         :poshandler enghi-triage-posframe-poshandler
         (enghi--posframe-look)))

(defun enghi--triage-hide ()
  "Hide the posframe, if it is there."
  (when (get-buffer enghi--triage-buffer)
    (posframe-hide enghi--triage-buffer)))

(defun enghi--triage-read-key (menu keys)
  "Show MENU and read one of KEYS, ignoring other keys.
MENU is the prompt, or with a posframe, what the posframe shows. C-g reads
as `?q', C-n and down as `?j', C-p and up as `?k', and S-Tab as `backtab'."
  (let ((prompt (if (enghi--triage-posframe-p)
                    (progn (enghi--triage-show menu) nil)
                  menu))
        key)
    (while (not (memq (setq key (condition-case nil
                                    (pcase (read-key prompt)
                                      ('return ?\r)
                                      ('tab ?\t)
                                      ((or 'backtab 'S-tab 'S-iso-lefttab) 'backtab)
                                      ((or ?\C-n 'down) ?j)
                                      ((or ?\C-p 'up) ?k)
                                      (?\C-g ?q)
                                      (k k))
                                  (quit ?q)))
                      keys)))
    key))

(defun enghi--triage-run (key task actions)
  "Run the action for KEY in ACTIONS on TASK. Return (CHANGED . MESSAGE).
MESSAGE is what to show next: the action's result, or what it said on the
way when it changed nothing, as `enghi--task-skip' does. The posframe
hides first: the questions are asked where it was."
  (enghi--triage-hide)
  (message nil)
  (condition-case err
      (let* ((use-dialog-box nil)
             (msg (funcall (nth 2 (assq key actions)) task)))
        (cons (and msg t) (or msg (current-message))))
    (quit (cons nil "Cancelled"))
    ((user-error enghi-error) (cons nil (error-message-string err)))))

(defun enghi--triage-contexts ()
  "Return whether contexts are on, which `n' needs to know."
  (eq (alist-get 'contexts (enghi--with-user-errors
                             (enghi-request "GET" "/api/settings")))
      t))

(defun enghi--triage-age (created)
  "Return how long ago CREATED (UTC \"YYYY-MM-DD HH:MM:SS\") was, or nil."
  (when-let* ((time (and (stringp created)
                         (ignore-errors
                           (parse-iso8601-time-string
                            (concat (string-replace " " "T" created) "Z"))))))
    (let ((days (floor (float-time (time-subtract nil time)) 86400)))
      (if (< days 1) "today" (format "%d d. ago" days)))))

;;;; ---------------------------------------------------------------- The lists

(defconst enghi--task-list-lists
  '(("inbox" . "Inbox") ("next" . "Next") ("waiting" . "Waiting")
    ("scheduled" . "Scheduled") ("later" . "Later") ("someday" . "Someday")
    ("projects" . "Projects"))
  "The lists of `enghi-task-list', as (STATE . LABEL), in the order Tab goes.
\"projects\" holds the active projects rather than tasks.")

(defconst enghi--task-list-nav
  '(("j/k" "Move") (?\t "List") (?g "Refresh") (?q "Quit"))
  "Keys of `enghi-task-list' besides the actions, as shown under them.")

(defun enghi--task-list-actions (state)
  "Return the action keys of the list STATE, as (ACTIONS . COLUMNS)."
  (if (equal state "projects")
      (cons enghi--triage-project-actions enghi--triage-project-columns)
    (cons enghi--triage-actions enghi--triage-columns)))

(defun enghi--task-list-projects (contexts)
  "Return the active projects, each marked with CONTEXTS and whether it is stalled.
A stalled project has no next action (`/api/projects/stalled')."
  (let ((stalled (mapcar (lambda (p) (alist-get 'id p))
                         (alist-get 'projects (enghi--with-user-errors
                                                (enghi-request "GET" "/api/projects/stalled"))))))
    (mapcar (lambda (project)
              `((contexts . ,contexts)
                (stalled . ,(and (memql (alist-get 'id project) stalled) t))
                ,@project))
            (alist-get 'projects (enghi--with-user-errors
                                   (enghi-request "GET" "/api/projects" nil
                                                  '((status . "active"))))))))

(defun enghi--task-list-fetch (contexts)
  "Return every list as (STATE . TASKS), each task marked with CONTEXTS.
Each list is as its screen shows it: the Inbox oldest first, and Next the
Next Actions list, with the scheduled tasks whose date has come. The list
of projects holds projects (`enghi--task-list-projects')."
  (mapcar (lambda (list)
            (if (equal (car list) "projects")
                (cons (car list) (enghi--task-list-projects contexts))
              (enghi--task-list-fetch-tasks (car list) contexts)))
          enghi--task-list-lists))

(defun enghi--task-list-fetch-tasks (state contexts)
  "Return the list STATE as (STATE . TASKS); see `enghi--task-list-fetch'."
  (let ((tasks (alist-get 'tasks (enghi--with-user-errors
                                   (enghi-request
                                    "GET" "/api/tasks" nil
                                    `((state . ,(if (equal state "next") "next_actions" state))
                                      (limit . 1000)))))))
    (when (equal state "inbox")
      (setq tasks (seq-sort-by (lambda (task) (alist-get 'created_at task))
                               #'string< tasks)))
    (cons state (mapcar (lambda (task) (cons (cons 'contexts contexts) task)) tasks))))

(defun enghi--task-list-side (task)
  "Return what to show to the right of TASK: what it waits on, or its project.
For a project, whether it has no next action, or its area."
  (or (pcase (alist-get 'state task)
        ("inbox" (enghi--triage-age (alist-get 'created_at task)))
        ("waiting" (enghi--task-field task 'waiting_for))
        ("scheduled" (enghi--task-field task 'scheduled_on)))
      (and (alist-get 'stalled task) (propertize "no next" 'face 'warning))
      (enghi--task-field task 'project_title)
      (enghi--task-field task 'area_name)
      ""))

(defun enghi--task-list-row (task current)
  "Return the row for TASK, highlighted when it is CURRENT."
  (let ((row (concat (if current "›" " ") " "
                     (if (alist-get 'working task) enghi--working-mark " ") " "
                     (truncate-string-to-width (enghi--task-title task) enghi-task-list-title-width
                                               nil ?\s "…")
                     "  "
                     (let ((side (copy-sequence
                                  (truncate-string-to-width
                                   (enghi--task-list-side task) enghi-task-list-side-width
                                   nil ?\s "…"))))
                       ;; Under a face of its own, such as that of "no next"
                       (add-face-text-property 0 (length side) 'shadow t side)
                       side))))
    (when current
      (add-face-text-property 0 (length row) 'highlight t row))
    row))

(defun enghi--task-list-window (count index height)
  "Return (START . END) of the rows to show among COUNT, with INDEX in them.
At most HEIGHT rows; INDEX stays near the middle while the list scrolls."
  (let ((start (max 0 (min (- index (/ (1- height) 2)) (- count height)))))
    (cons start (min count (+ start height)))))

(defun enghi--task-list-width ()
  "Return the width of a task row: the marks, the title, a gap, the right column."
  (+ 4 enghi-task-list-title-width 2 enghi-task-list-side-width))

(defun enghi--task-list-menu (lists state index last &optional fixed)
  "Return the menu for LISTS, showing the list STATE with INDEX chosen.
LAST is the message of the previous action, or nil. The menu is as wide
whatever the list. With FIXED it is also as tall: a line that is not there
is left blank, so a posframe showing it neither moves nor changes size."
  (let* ((tasks (cdr (assoc state lists)))
         (window (enghi--task-list-window (length tasks) index enghi-task-list-height))
         (tabs (mapconcat (lambda (list)
                            (let ((tab (format "%s %d" (cdr list)
                                               (length (cdr (assoc (car list) lists))))))
                              (if (equal (car list) state)
                                  (propertize tab 'face 'bold)
                                (propertize tab 'face 'shadow))))
                          enghi--task-list-lists
                          (propertize " · " 'face 'shadow)))
         (rows (if (null tasks)
                   (list (propertize "   (empty)" 'face 'shadow))
                 (mapcar (lambda (i) (enghi--task-list-row (nth i tasks) (= i index)))
                         (number-sequence (car window) (1- (cdr window))))))
         (above (when (> (car window) 0)
                  (propertize (format "   ↑ %d more" (car window)) 'face 'shadow)))
         (below (when (< (cdr window) (length tasks))
                  (propertize (format "   ↓ %d more" (- (length tasks) (cdr window)))
                              'face 'shadow)))
         ;; The keys of the tasks and of the projects: the menu takes the room
         ;; of the larger, so it keeps its size from one list to another
         (blocks (mapcar (lambda (s)
                           (let ((actions (enghi--task-list-actions s)))
                             (split-string (enghi--triage-keys (car actions) (cdr actions))
                                           "\n")))
                         '("inbox" "projects")))
         (block (if (equal state "projects") (cadr blocks) (car blocks)))
         (keys (string-join
                (append block
                        (and fixed (make-list (- (apply #'max (mapcar #'length blocks))
                                                 (length block))
                                              ""))
                        (list "" (concat " " (enghi--triage-key-row enghi--task-list-nav))))
                "\n"))
         ;; The rule sets the width, whichever is wider: the rows or the keys
         (width (apply #'max (enghi--task-list-width)
                       (mapcar #'string-width
                               (append (split-string (concat tabs "\n" keys) "\n")
                                       (apply #'append blocks))))))
    (string-join
     (delq nil (append (list (cond (last (truncate-string-to-width last width nil nil "…"))
                                   (fixed ""))
                             tabs
                             (or above (and fixed "")))
                       rows
                       (and fixed (make-list (- enghi-task-list-height (length rows)) ""))
                       (list (or below (and fixed ""))
                             (propertize (make-string (/ width (string-width "─")) ?─)
                                         'face 'shadow)
                             keys)))
     "\n")))

(defun enghi--task-list-cycle (state step)
  "Return the list STEP lists away from STATE, wrapping around."
  (let* ((states (mapcar #'car enghi--task-list-lists))
         (i (seq-position states state)))
    (nth (mod (+ i step) (length states)) states)))

;;;###autoload
(defun enghi-task-list ()
  "Show the GTD lists and act on their tasks with one key.
It opens on the Inbox, or on Next Actions when the Inbox is empty. `j' and
`k' choose a task, Tab and S-Tab go through the lists, `g' reloads them and
`q' ends. The action keys act on the chosen task: `n' Next, `p' make it a
project with the task as its next action, `l' Later, `w' Waiting, `s'
Scheduled, `m' Someday, `d' Done, `S' Skip, `x' Drop, `f' File as a page,
`t' Rename, `.' start working on it now, `o' open its URL, RET its page.
They ask their questions in the minibuffer, and \\[keyboard-quit] cancels
one.

The last list holds the active projects, \"no next\" by those with no next
action. Its keys act on the chosen project: `a' add a next action, `t'
Rename, `d' Done, `m' Someday, `x' Drop, `o' open its URL, RET its page.

It shows in the echo area, or in a posframe; see `enghi-triage-display'."
  (interactive)
  (let* ((contexts (enghi--triage-contexts))
         (lists (enghi--task-list-fetch contexts))
         (state (if (cdr (assoc "inbox" lists)) "inbox" "next"))
         (positions nil)
         last)
    (unwind-protect
        (catch 'quit
          (while t
            (let* ((tasks (cdr (assoc state lists)))
                   (actions (car (enghi--task-list-actions state)))
                   (index (min (or (alist-get state positions nil nil #'equal) 0)
                               (max 0 (1- (length tasks)))))
                   (key (enghi--triage-read-key
                         (enghi--task-list-menu lists state index last
                                                (enghi--triage-posframe-p))
                         (append (mapcar #'car actions) '(?j ?k ?\t backtab ?g ?q)))))
              (setq last nil)
              (pcase key
                (?q (throw 'quit nil))
                (?j (setq index (min (1+ index) (max 0 (1- (length tasks))))))
                (?k (setq index (max 0 (1- index))))
                (?\t (setq state (enghi--task-list-cycle state 1)))
                ('backtab (setq state (enghi--task-list-cycle state -1)))
                (?g (setq lists (enghi--task-list-fetch contexts)))
                (_ (when-let* ((task (nth index tasks)))
                     (let ((result (enghi--triage-run key task actions)))
                       (setq last (cdr result))
                       (when (car result)
                         (setq lists (enghi--task-list-fetch contexts)))))))
              (unless (memq key '(?\t backtab))
                (setf (alist-get state positions nil nil #'equal) index)))))
      (enghi--triage-hide))
    (let* ((inbox (length (cdr (assoc "inbox" lists))))
           (msg (string-join (delq nil (list last (if (= inbox 0) "Inbox 0"
                                                    (format "Inbox: %d left" inbox))))
                             "  ")))
      (message "%s" msg)
      msg)))

(provide 'enghi-triage)
;;; enghi-triage.el ends here
