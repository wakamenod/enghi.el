;;; enghi-dashboard.el --- enghi section for dashboard.el -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; A section for the dashboard.el startup screen, in place of its agenda:
;; the Inbox count, today's calendar events (the ones that have ended dimmed,
;; the one in progress marked), the tasks being worked on and since when, what
;; is due today (overdue deadlines marked) and the deadlines of the coming
;; days.
;;
;; Loading this file registers the generator under the key `enghi'. Show it
;; by adding it to `dashboard-items':
;;
;;   (require 'enghi-dashboard)
;;   (add-to-list 'dashboard-items '(enghi . 5) t)
;;
;; The number caps the lines shown in each group.
;;
;; **The data comes from one request to `/api/dashboard'**, with a short
;; timeout. The dashboard is built at startup, so a server that is down or slow
;; must never raise an error or hold up Emacs: the section then shows one line
;; saying so, and selecting it tries again.
;;
;; dashboard.el is not required by enghi.el; this file is the only part that
;; knows about it.

;;; Code:

(require 'enghi)
(require 'parse-time)
(require 'seq)
(require 'subr-x)
(require 'wid-edit)

;; From dashboard.el, loaded by the time the generator runs.
(defvar dashboard-item-generators)
(defvar dashboard-item-shortcuts)
(declare-function dashboard-insert-heading "dashboard-widgets" (heading &optional shortcut icon))
(declare-function dashboard-insert-shortcut "dashboard-widgets" (shortcut-id shortcut-char section-name))
(declare-function dashboard-get-shortcut "dashboard-widgets" (item))
(declare-function dashboard-heading-icon "dashboard-widgets" (section))
(declare-function dashboard-refresh-buffer "dashboard" ())

(defcustom enghi-dashboard-timeout 2
  "Seconds to wait for the server while building the dashboard.
Kept short because the dashboard is built at startup."
  :type 'integer
  :group 'enghi)

(defcustom enghi-dashboard-heading "enghi:"
  "Heading of the enghi section."
  :type 'string
  :group 'enghi)

(defface enghi-dashboard-inbox
  '((t :inherit (warning bold)))
  "Face for the Inbox count when it is not zero."
  :group 'enghi)

(defface enghi-dashboard-overdue
  '((t :inherit error))
  "Face for the label of a task whose deadline has passed."
  :group 'enghi)

(defface enghi-dashboard-label
  '((t :inherit shadow))
  "Face for the label in front of other tasks."
  :group 'enghi)

(defface enghi-dashboard-past-event
  '((t :inherit shadow))
  "Face for a calendar event that has ended."
  :group 'enghi)

(defface enghi-dashboard-now
  '((t :inherit (success bold)))
  "Face for the label of the event in progress and of the tasks being worked on."
  :group 'enghi)

(defface enghi-dashboard-stale-work
  '((t :inherit warning))
  "Face for the start of work begun on an earlier day, likely left running."
  :group 'enghi)

;;;; ---------------------------------------------------------------- Data

(defun enghi-dashboard--fetch ()
  "Return the dashboard data, or nil if the server does not answer."
  (condition-case nil
      (let ((enghi-request-timeout enghi-dashboard-timeout))
        (enghi-dashboard))
    ;; Anything at all: the startup screen must still come up
    (error nil)))

(defun enghi-dashboard--days-left (task)
  "Return the days until TASK's deadline, negative when past, or nil.
Servers older than `deadline_days' leave it out; then count from
`deadline_on' against the local date."
  (or (alist-get 'deadline_days task)
      (when-let* ((due (enghi--date-time (alist-get 'deadline_on task)))
                  (today (enghi--date-time (format-time-string "%F"))))
        ;; round, not truncate: a DST change makes a day 23 or 25 hours
        (round (float-time (time-subtract due today)) 86400))))

(defun enghi-dashboard--label (task)
  "Return the label in front of TASK, in the style of org-agenda."
  (let ((days (enghi-dashboard--days-left task)))
    (cond ((and days (< days 0))
           (propertize (format "%d d. ago:" (- days)) 'face 'enghi-dashboard-overdue))
          ((and days (> days 0))
           (propertize (format "In %d d.:" days) 'face 'enghi-dashboard-label))
          (t (propertize "Today:" 'face 'enghi-dashboard-label)))))

(defun enghi-dashboard--task-line (task &optional label)
  "Return the line for TASK as (TEXT . PATH), behind LABEL or its deadline."
  (cons (concat (enghi-dashboard--pad (or label (enghi-dashboard--label task)))
                (alist-get 'title task)
                (if-let* ((project (alist-get 'project_title task)))
                    (propertize (format "  (%s)" project) 'face 'enghi-dashboard-label)
                  ""))
        (format "/gtd/clarify/%s" (alist-get 'id task))))

(defun enghi-dashboard--pad (label)
  "Return LABEL padded to the label column, keeping a space after it."
  (string-pad label (max 12 (1+ (string-width label)))))

(defun enghi-dashboard--group (items list-size &optional line-function more-path)
  "Return the lines for ITEMS, at most LIST-SIZE and then a line for the rest.
LINE-FUNCTION turns an item into (TEXT . PATH), by default a task line.
Selecting the line for the rest opens MORE-PATH, by default the dashboard."
  (let ((shown (if list-size (seq-take items list-size) items))
        (rest (- (length items) (if list-size (min list-size (length items)) (length items)))))
    (append (mapcar (or line-function #'enghi-dashboard--task-line) shown)
            (when (> rest 0)
              (list (cons (propertize (format "%s… %d more" (make-string 12 ?\s) rest)
                                      'face 'enghi-dashboard-label)
                          (or more-path "/")))))))

;;;; Events and work

(defun enghi-dashboard--time (string)
  "Return the RFC 3339 STRING as a Lisp time, or nil if it is not one."
  (when (stringp string)
    (ignore-errors (parse-iso8601-time-string string))))

(defun enghi-dashboard--sort-events (events)
  "Return EVENTS with the all-day ones first, then the others by start."
  (let ((all-day (seq-filter (lambda (ev) (alist-get 'all_day ev)) events)))
    (append all-day
            (seq-sort-by (lambda (ev) (or (enghi-dashboard--time (alist-get 'start ev)) 0))
                         #'time-less-p
                         (seq-difference events all-day)))))

(defun enghi-dashboard--event-line (event now)
  "Return the line for EVENT as (TEXT . PATH), with NOW the current time.
An event that has ended is dimmed and the one in progress is marked.
Selecting it opens the task made from it, or else today's day page."
  (let* ((start (enghi-dashboard--time (alist-get 'start event)))
         (end (enghi-dashboard--time (alist-get 'end event)))
         (all-day (or (alist-get 'all_day event) (null start)))
         (past (and (not all-day) end (not (time-less-p now end))))
         (current (and (not all-day) (not past) (not (time-less-p now start))))
         (label (cond (all-day "All day")
                      (end (format "%s–%s"
                                   (format-time-string "%H:%M" start)
                                   (format-time-string "%H:%M" end)))
                      (t (format-time-string "%H:%M" start))))
         (details (concat
                   (when-let* ((calendar (alist-get 'calendar event))
                               ((not (string-empty-p calendar))))
                     (format "  (%s)" calendar))
                   (when-let* ((location (alist-get 'location event))
                               ((not (string-empty-p location))))
                     (format "  @%s" location))))
         (text (concat (propertize (enghi-dashboard--pad label)
                                   'face (if current 'enghi-dashboard-now 'enghi-dashboard-label))
                       (alist-get 'title event)
                       (propertize details 'face 'enghi-dashboard-label))))
    (cons (if past (propertize text 'face 'enghi-dashboard-past-event) text)
          (if-let* ((task (alist-get 'task_id event)))
              (format "/gtd/clarify/%s" task)
            "/gtd/day"))))

(defun enghi-dashboard--elapsed (seconds)
  "Return SECONDS as a short duration: 5m, 2h 5m or 1d 2h."
  (let* ((minutes (/ (max 0 (truncate seconds)) 60))
         (hours (/ minutes 60))
         (days (/ hours 24)))
    (cond ((> days 0) (format "%dd %dh" days (% hours 24)))
          ((> hours 0) (format "%dh %dm" hours (% minutes 60)))
          (t (format "%dm" minutes)))))

(defun enghi-dashboard--since (task now)
  "Return when work on TASK started and how long ago, as of NOW, or \"\".
The date is added when it started on an earlier day, which stands out: work
left running is what this is there to catch. Servers before `since' send no
start, and then this is empty."
  (if-let* ((since (enghi-dashboard--time (alist-get 'since task))))
      (let ((earlier (not (equal (format-time-string "%F" since)
                                 (format-time-string "%F" now)))))
        (propertize (format "  since %s (%s)"
                            (format-time-string (if earlier "%-m/%-d %H:%M" "%H:%M") since)
                            (enghi-dashboard--elapsed (float-time (time-subtract now since))))
                    'face (if earlier 'enghi-dashboard-stale-work 'enghi-dashboard-label)))
    ""))

(defun enghi-dashboard--working-line (task now)
  "Return the line for TASK being worked on as (TEXT . PATH), as of NOW."
  (let ((line (enghi-dashboard--task-line
               task (propertize "Working:" 'face 'enghi-dashboard-now))))
    (cons (concat (car line) (enghi-dashboard--since task now))
          (cdr line))))

(defun enghi-dashboard--lines (data list-size)
  "Return the section lines for dashboard DATA, as (TEXT . PATH).
PATH is what selecting the line opens. With DATA nil the server did not
answer, and the one line has PATH nil, meaning try again. Today's events
come first, then the tasks being worked on, then what is due with overdue
tasks first. A group the server does not send is skipped."
  (if (null data)
      (list (cons (format "enghi is not running (%s)" enghi-server-url) nil))
    (let* ((now (current-time))
           (gtd (alist-get 'gtd data))
           (inbox (or (alist-get 'inbox_count gtd) 0))
           (events (enghi-dashboard--sort-events (alist-get 'events data)))
           (working (alist-get 'working gtd))
           (today (alist-get 'today gtd))
           (overdue (seq-filter (lambda (tk) (let ((d (enghi-dashboard--days-left tk)))
                                               (and d (< d 0))))
                                today))
           (upcoming (alist-get 'upcoming gtd)))
      (append
       (list (cons (if (> inbox 0)
                       (propertize (format "Inbox %d" inbox) 'face 'enghi-dashboard-inbox)
                     "Inbox 0")
                   "/gtd/inbox"))
       (enghi-dashboard--group events list-size
                               (lambda (ev) (enghi-dashboard--event-line ev now))
                               "/gtd/day")
       (enghi-dashboard--group working list-size
                               (lambda (tk) (enghi-dashboard--working-line tk now)))
       (enghi-dashboard--group (append overdue (seq-difference today overdue)) list-size)
       (enghi-dashboard--group upcoming list-size)
       (unless (or today upcoming)
         (list (cons (propertize "Nothing due" 'face 'enghi-dashboard-label) "/gtd/next")))
       (list (cons "Open the dashboard" "/"))
       ;; Servers that send events also have the day page
       (when (assq 'events data)
         (list (cons "Open the day page" "/gtd/day")))))))

;;;; ---------------------------------------------------------------- Section

(defun enghi-dashboard--visit (path)
  "Open PATH on the server, or with PATH nil, rebuild the dashboard."
  (if path
      (condition-case err
          (enghi-browse path)
        (error (message "%s" (error-message-string err))))
    (dashboard-refresh-buffer)))

(defun enghi-dashboard-insert (list-size)
  "Insert the enghi section, with at most LIST-SIZE tasks in each group.
This is the generator registered in `dashboard-item-generators'."
  (dashboard-insert-heading enghi-dashboard-heading nil (dashboard-heading-icon 'enghi))
  (dolist (line (enghi-dashboard--lines (enghi-dashboard--fetch) list-size))
    (insert "\n" (make-string (or standard-indent tab-width 4) ?\s))
    (let ((path (cdr line)))
      ;; The same item widget as `dashboard-insert-section-list'
      (widget-create 'item
                     :tag (car line)
                     :action (lambda (&rest _) (enghi-dashboard--visit path))
                     :button-face 'dashboard-items-face
                     :mouse-face 'highlight
                     :button-prefix ""
                     :button-suffix ""
                     :format "%[%t%]"))))

(with-eval-after-load 'dashboard
  (add-to-list 'dashboard-item-generators '(enghi . enghi-dashboard-insert)))

(provide 'enghi-dashboard)
;;; enghi-dashboard.el ends here
