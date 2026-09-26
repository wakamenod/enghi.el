;;; enghi-dashboard.el --- enghi section for dashboard.el -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; A section for the dashboard.el startup screen, in place of its agenda:
;; the Inbox count, what is due today (overdue deadlines marked) and the
;; deadlines of the coming days.
;;
;; Loading this file registers the generator under the key `enghi'. Show it
;; by adding it to `dashboard-items':
;;
;;   (require 'enghi-dashboard)
;;   (add-to-list 'dashboard-items '(enghi . 5) t)
;;
;; The number caps the tasks shown in each group.
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

(defun enghi-dashboard--task-line (task)
  "Return the line for TASK as (TEXT . PATH)."
  (cons (concat (string-pad (enghi-dashboard--label task) 12)
                (alist-get 'title task)
                (if-let* ((project (alist-get 'project_title task)))
                    (propertize (format "  (%s)" project) 'face 'enghi-dashboard-label)
                  ""))
        (format "/gtd/clarify/%s" (alist-get 'id task))))

(defun enghi-dashboard--group (tasks list-size)
  "Return the lines for TASKS, at most LIST-SIZE and then a line for the rest."
  (let ((shown (if list-size (seq-take tasks list-size) tasks))
        (rest (- (length tasks) (if list-size (min list-size (length tasks)) (length tasks)))))
    (append (mapcar #'enghi-dashboard--task-line shown)
            (when (> rest 0)
              (list (cons (propertize (format "%s… %d more" (make-string 12 ?\s) rest)
                                      'face 'enghi-dashboard-label)
                          "/"))))))

(defun enghi-dashboard--lines (data list-size)
  "Return the section lines for dashboard DATA, as (TEXT . PATH).
PATH is what selecting the line opens. With DATA nil the server did not
answer, and the one line has PATH nil, meaning try again. Overdue tasks come
first. The upcoming group is skipped when the server does not send it."
  (if (null data)
      (list (cons (format "enghi is not running (%s)" enghi-server-url) nil))
    (let* ((gtd (alist-get 'gtd data))
           (inbox (or (alist-get 'inbox_count gtd) 0))
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
       (enghi-dashboard--group (append overdue (seq-difference today overdue)) list-size)
       (enghi-dashboard--group upcoming list-size)
       (unless (or today upcoming)
         (list (cons (propertize "Nothing due" 'face 'enghi-dashboard-label) "/gtd/next")))
       (list (cons "Open the dashboard" "/"))))))

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
