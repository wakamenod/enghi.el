;;; enghi-agenda.el --- enghi の GTD 一覧バッファ -*- lexical-binding: t; -*-

;;; Commentary:

;; org-agenda 風の一覧バッファ。状態変更はキーを PATCH にマップする
;; (DESIGN.md 8-25)。
;;
;; 本文の編集はここでは行わない。Inbox の項目を「行動か資料か」決めるのが主な用途。

;;; Code:

(require 'enghi)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defcustom enghi-agenda-sections
  '((inbox        . "Inbox")
    (next_actions . "Next Actions")
    (waiting      . "Waiting For")
    (scheduled    . "日付付き"))
  "agenda に出す節。car はサーバの state、cdr は見出し."
  :type '(alist :key-type symbol :value-type string)
  :group 'enghi)

(defvar enghi-agenda-buffer-name "*enghi agenda*"
  "agenda バッファの名前.")

(defvar-local enghi-agenda--lines nil
  "行番号からタスク (alist) への対応表.")

(defvar enghi-agenda-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g")   #'enghi-agenda-refresh)
    (define-key map (kbd "n")   #'enghi-agenda-set-next)
    (define-key map (kbd "w")   #'enghi-agenda-set-waiting)
    (define-key map (kbd "s")   #'enghi-agenda-set-scheduled)
    (define-key map (kbd "l")   #'enghi-agenda-set-later)
    (define-key map (kbd "m")   #'enghi-agenda-set-someday)
    (define-key map (kbd "d")   #'enghi-agenda-complete)
    (define-key map (kbd "x")   #'enghi-agenda-drop)
    (define-key map (kbd "k")   #'enghi-agenda-skip)
    (define-key map (kbd "f")   #'enghi-agenda-file-as-page)
    (define-key map (kbd "t")   #'enghi-agenda-set-title)
    (define-key map (kbd "c")   #'enghi-agenda-capture)
    (define-key map (kbd "p")   #'enghi-agenda-set-project)
    (define-key map (kbd "C")   #'enghi-agenda-set-context)
    (define-key map (kbd "RET") #'enghi-agenda-browse)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "TAB") #'forward-button)
    map)
  "`enghi-agenda-mode' のキーマップ.")

(define-derived-mode enghi-agenda-mode special-mode "enghi-agenda"
  "enghi の GTD 一覧."
  (setq truncate-lines t)
  (buffer-disable-undo))

(defun enghi-agenda--tasks (state)
  "STATE のタスクを取る。state は `next_actions' も指定できる."
  (alist-get 'tasks (enghi-request "GET" "/api/tasks" nil
                                   `((state . ,state) (limit . 200)))))

(defun enghi-agenda--format (task)
  "TASK を1行にする."
  (let ((title (alist-get 'title task))
        (project (alist-get 'project_title task))
        (context (alist-get 'context_name task))
        (deadline (alist-get 'deadline_on task))
        (scheduled (alist-get 'scheduled_on task))
        (recurrence (alist-get 'recurrence task))
        (waiting-for (alist-get 'waiting_for task))
        (waiting-days (alist-get 'waiting_days task)))
    (concat
     "  " title
     (when (and project (not (string-empty-p project)))
       (propertize (format "  «%s»" project) 'face 'font-lock-type-face))
     (when (and context (not (string-empty-p context)))
       (propertize (format "  %s" context) 'face 'font-lock-keyword-face))
     (when (and deadline (not (string-empty-p deadline)))
       (propertize (format "  締切 %s" deadline) 'face 'font-lock-warning-face))
     (when (and scheduled (not (string-empty-p scheduled)))
       (propertize (format "  予定 %s" scheduled) 'face 'font-lock-comment-face))
     (when (and recurrence (not (string-empty-p recurrence)))
       (propertize (format "  ↻%s" recurrence) 'face 'font-lock-comment-face))
     (when (and waiting-for (not (string-empty-p waiting-for)))
       (propertize (format "  ←%s (%s日)" waiting-for (or waiting-days 0))
                   'face 'font-lock-comment-face)))))

;;;###autoload
(defun enghi-agenda ()
  "GTD の一覧を出す."
  (interactive)
  (let ((buf (get-buffer-create enghi-agenda-buffer-name)))
    (with-current-buffer buf
      (enghi-agenda-mode)
      (enghi-agenda--render))
    (pop-to-buffer buf)
    buf))

(defun enghi-agenda--render ()
  "バッファを描き直す."
  (let ((inhibit-read-only t)
        (line 1)
        (map (make-hash-table :test #'eql))
        (pos (point)))
    (erase-buffer)
    ;; 停滞プロジェクトを先頭に出す。**これがシステムの価値の半分を担う**(DESIGN.md 2.4)
    (let ((stalled (alist-get 'projects (enghi-request "GET" "/api/projects/stalled"))))
      (when stalled
        (insert (propertize "停滞プロジェクト — Next Action が1つも無いもの\n"
                            'face 'font-lock-warning-face))
        (cl-incf line)
        (dolist (p stalled)
          (insert (format "  %s\n" (alist-get 'title p)))
          (cl-incf line))
        (insert "\n")
        (cl-incf line)))

    (dolist (section enghi-agenda-sections)
      (let ((tasks (enghi-agenda--tasks (car section))))
        (insert (propertize (format "%s (%d)\n" (cdr section) (length tasks))
                            'face 'font-lock-function-name-face))
        (cl-incf line)
        (if tasks
            (dolist (task tasks)
              (insert (enghi-agenda--format task) "\n")
              (puthash line task map)
              (cl-incf line))
          (insert (propertize "  —\n" 'face 'font-lock-comment-face))
          (cl-incf line))
        (insert "\n")
        (cl-incf line)))

    (insert (propertize
             (concat "n 次の行動  w 他者待ち  s 日付を付ける  l 後続  m いつか\n"
                     "d 完了  k 今回は飛ばす  x 破棄  f 資料にする(記事化)\n"
                     "t 題名  p プロジェクト  C コンテキスト  c 追加  g 更新  RET ブラウザ\n")
             'face 'font-lock-comment-face))
    (setq enghi-agenda--lines map)
    (goto-char (min pos (point-max)))))

(defun enghi-agenda-refresh ()
  "一覧を取り直す."
  (interactive)
  (enghi-agenda--render)
  (message "更新した"))

(defun enghi-agenda--task-at-point ()
  "カーソル行のタスクを返す。無ければエラー."
  (or (gethash (line-number-at-pos) enghi-agenda--lines)
      (user-error "この行にタスクは無い")))

(defun enghi-agenda--patch (payload)
  "カーソル行のタスクを PAYLOAD で更新し、一覧を描き直す."
  (let ((task (enghi-agenda--task-at-point)))
    (enghi-request "PATCH" (format "/api/tasks/%s" (alist-get 'id task)) payload)
    (enghi-agenda--render)
    (message "%s" (alist-get 'title task))))

(defun enghi-agenda-set-next ()
  "次の行動にする."
  (interactive)
  (enghi-agenda--patch '((state . "next"))))

(defun enghi-agenda-set-later ()
  "後続の行動にする(Next リストには出さない)."
  (interactive)
  (enghi-agenda--patch '((state . "later"))))

(defun enghi-agenda-set-someday ()
  "いつかやる/たぶんやる にする."
  (interactive)
  (enghi-agenda--patch '((state . "someday"))))

(defun enghi-agenda-set-waiting (who)
  "他者待ちにする。WHO は相手."
  (interactive "s待っている相手: ")
  (enghi-agenda--patch `((state . "waiting") (waiting_for . ,who))))

(defun enghi-agenda-set-scheduled (date)
  "DATE に予定する(tickler)。その日まで通常リストに出ない."
  (interactive "s予定日 (YYYY-MM-DD): ")
  (enghi-agenda--patch `((state . "scheduled") (scheduled_on . ,date))))

(defun enghi-agenda-set-title (title)
  "題名を TITLE に変える(行動は動詞で始めると決めやすい)."
  (interactive
   (list (read-string "題名: " (alist-get 'title (enghi-agenda--task-at-point)))))
  (enghi-agenda--patch `((title . ,title))))

(defun enghi-agenda-complete ()
  "完了にする。定期タスクなら次の1件が生成される."
  (interactive)
  (let* ((task (enghi-agenda--task-at-point))
         (res (enghi-request "POST" (format "/api/tasks/%s/complete" (alist-get 'id task))
                             '((skip . :json-false)))))
    (enghi-agenda--render)
    (if-let* ((next (alist-get 'next res)))
        (message "完了。次は %s" (alist-get 'scheduled_on next))
      (message "完了: %s" (alist-get 'title task)))))

(defun enghi-agenda-skip ()
  "今回は飛ばす。定期タスクなら次の1件が生成される."
  (interactive)
  (let* ((task (enghi-agenda--task-at-point))
         (res (enghi-request "POST" (format "/api/tasks/%s/complete" (alist-get 'id task))
                             '((skip . t)))))
    (enghi-agenda--render)
    (if-let* ((next (alist-get 'next res)))
        (message "飛ばした。次は %s" (alist-get 'scheduled_on next))
      (message "飛ばした: %s" (alist-get 'title task)))))

(defun enghi-agenda-drop ()
  "破棄する."
  (interactive)
  (when (yes-or-no-p "この項目を破棄する? ")
    (enghi-agenda--patch '((state . "dropped")))))

(defun enghi-agenda-file-as-page (title)
  "行動ではなく参照資料だった場合に、Wiki ページにする.
元のタスクは filed になる。完了でも破棄でもない."
  (interactive
   (list (read-string "記事タイトル: " (alist-get 'title (enghi-agenda--task-at-point)))))
  (let* ((task (enghi-agenda--task-at-point))
         (res (enghi-request "POST" (format "/api/tasks/%s/file" (alist-get 'id task))
                             `((title . ,title)
                               (body . ,(or (alist-get 'note task) ""))
                               (tags . [])))))
    (enghi-agenda--render)
    (message "記事にした: %s" (alist-get 'title (alist-get 'page res)))
    (enghi-open (alist-get 'slug (alist-get 'page res)))))

(defun enghi-agenda-set-project ()
  "プロジェクトに紐づける."
  (interactive)
  (let* ((projects (alist-get 'projects
                              (enghi-request "GET" "/api/projects" nil '((status . "active")))))
         (cands (mapcar (lambda (p) (cons (alist-get 'title p) (alist-get 'id p))) projects)))
    (unless cands (user-error "アクティブなプロジェクトが無い"))
    (let ((id (cdr (assoc (completing-read "プロジェクト: " cands nil t) cands))))
      (enghi-agenda--patch `((project_id . ,id))))))

(defun enghi-agenda-set-context ()
  "コンテキストを付ける."
  (interactive)
  (let* ((contexts (alist-get 'contexts (enghi-request "GET" "/api/contexts")))
         (cands (mapcar (lambda (c) (cons (alist-get 'name c) (alist-get 'id c))) contexts)))
    (unless cands (user-error "コンテキストが無い"))
    (let ((id (cdr (assoc (completing-read "コンテキスト: " cands nil t) cands))))
      (enghi-agenda--patch `((context_id . ,id))))))

(defun enghi-agenda-capture (title)
  "その場で Inbox に追加する."
  (interactive "sInbox へ: ")
  (enghi-capture title)
  (enghi-agenda--render))

(defun enghi-agenda-browse ()
  "カーソル行のタスクをブラウザで開く."
  (interactive)
  (let ((task (enghi-agenda--task-at-point)))
    (enghi-browse (format "/gtd/clarify/%s" (alist-get 'id task)))))

(provide 'enghi-agenda)
;;; enghi-agenda.el ends here
