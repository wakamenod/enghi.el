;;; work-log.el --- Writing a task's work log from Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of the work-log branch, in the user's own configuration,
;; against a throwaway server the recorder started:
;;
;;   1. C-c n t starts a task; the picker then offers it first, marked ▶.
;;   2. C-c n l writes an entry in a Markdown buffer and C-c C-c sends it.
;;   3. C-c n r logs a link to the code in the region (a browse-at-remote
;;      permalink, the code below it); C-c n R adds a comment first.
;;   4. The task's Clarify page shows it all; with that page on screen, it
;;      is the picker's default.
;;   5. Search finds log entries (Log) and opens them at the entry.
;;   6. Editing an entry changed elsewhere shows both in ediff.
;;   7. C-c n t pauses it, and pausing again says it changed nothing.
;;
;; The code read is the enghi server's own source, opened read-only.
;;
;; Played by demo/scenes/work-log.sh through demo/record.sh.

;;; Code:

(require 'enghi)
(require 'enghi-log)

(defvar demo-source
  (expand-file-name "~/Projects/SideProjects/enghi/internal/gtd/task_log.go")
  "The file the code links point into.  Only read.")

(setq demo-log-file "/tmp/enghi-demo-work-log-log.txt")

(defvar demo-tasks nil "Titles of the tasks this scene made, to their ids.")

(defun demo-task-id (title)
  "Return the id of the task called TITLE."
  (cdr (assoc title demo-tasks)))

(defun demo-seed ()
  "Make a project and a few Next actions on the throwaway server."
  (let ((project (alist-get 'id (enghi-request "POST" "/api/projects"
                                               '((title . "enghi 0.3"))))))
    (setq demo-tasks nil)
    (dolist (title '("ログ検索の2文字クエリを直す" "リリースノートを書く" "PR #42 をレビュー"))
      (let ((id (alist-get 'id (enghi-request "POST" "/api/tasks" `((title . ,title))))))
        (enghi-request "PATCH" (format "/api/tasks/%s" id)
                       `((state . "next") (project_id . ,project)))
        (push (cons title id) demo-tasks)))
    (enghi-request "POST" "/api/tasks" '((title . "牛乳を買う")))))

(defun demo-scene-build ()
  "Seed the server and lay the screen out.  Called by demo.el."
  (setq ediff-window-setup-function #'ediff-setup-windows-plain
        ediff-split-window-function #'split-window-horizontally)
  (setq enghi-browse-function #'enghi-browse-in-xwidget)
  (demo-seed)
  (delete-other-windows)
  (find-file demo-source)
  (read-only-mode 1)
  (goto-char (point-min))
  (let ((right (split-window-right)))
    (with-selected-window right
      (enghi-browse "/gtd/next")))
  (demo-left)
  (demo-say (format "enghi.el from %s   server %s"
                    (abbreviate-file-name (locate-library "enghi")) enghi-server-url)))

;;;; Windows

(defun demo-left ()
  "Select the window of the source file."
  (when-let* ((window (get-buffer-window (get-file-buffer demo-source))))
    (select-window window))
  nil)

(defun demo-right ()
  "Select the window that is not the source file's."
  (demo-left)
  (select-window (next-window))
  nil)

(defun demo-browse-right (path)
  "Show PATH of the server in the right window."
  (demo-right)
  (enghi-browse path)
  (demo-left)
  nil)

(defun demo-reload-right ()
  "Reload the web view, which does not follow changes made through the API."
  (when-let* ((session (xwidget-webkit-current-session)))
    (xwidget-webkit-execute-script session "location.reload()"))
  nil)

(defun demo-scroll-right-to-bottom ()
  "Scroll the web view to the end of the page."
  (when-let* ((session (xwidget-webkit-current-session)))
    (xwidget-webkit-execute-script
     session "window.scrollTo(0, document.body.scrollHeight)"))
  nil)

;;;; The source

(defun demo-select-lines (first last)
  "Select lines FIRST to LAST of the source, in its window."
  (demo-left)
  (goto-char (point-min))
  (forward-line (1- first))
  (recenter 5)
  (push-mark (point) t t)
  (forward-line (1+ (- last first)))
  (setq deactivate-mark nil)
  nil)

;;;; Somebody else

(defun demo-edit-elsewhere ()
  "Edit the entry open in this log buffer, as the browser would."
  (when-let* ((buffer (seq-find (lambda (b) (buffer-local-value 'enghi-log-id b))
                                (buffer-list))))
    (with-current-buffer buffer
      (enghi-request "PATCH" (format "/api/task-logs/%s" enghi-log-id)
                     `((body . ,(concat (buffer-string) "\n(ブラウザから追記)"))
                       (version . ,enghi-log-version)))))
  (demo-say "…その間にブラウザ側で同じエントリーが編集された")
  nil)

(defun demo-pause-again ()
  "Pause the task that was just paused, which changes nothing."
  (let ((title "ログ検索の2文字クエリを直す"))
    (enghi-task-pause `((id . ,(demo-task-id title)) (title . ,title)))))

(defun demo-close-ediff ()
  "Leave ediff and its buffers, and put the screen back."
  (dolist (buffer (buffer-list))
    (when (string-match-p "\\`\\*\\(Ediff\\|enghi conflict\\|enghi log\\)" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)))
  (delete-other-windows)
  (switch-to-buffer (get-file-buffer demo-source))
  (let ((right (split-window-right)))
    (with-selected-window right
      (switch-to-buffer (seq-find (lambda (b) (eq (buffer-local-value 'major-mode b)
                                                  'xwidget-webkit-mode))
                                  (buffer-list)))))
  (demo-left)
  nil)

(provide 'work-log)
;;; work-log.el ends here
