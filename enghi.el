;;; enghi.el --- ローカル Wiki + GTD (enghi) のクライアント -*- lexical-binding: t; -*-

;; Author: jun
;; Package-Requires: ((emacs "28.1"))
;; Keywords: outlines, hypermedia, convenience

;;; Commentary:

;; 常駐している enghi サーバ (http://127.0.0.1:7777) を Emacs から使う。
;;
;; 設計は docs/DESIGN.md の第3段階に対応する。要点:
;;
;;   * 検索とインデックスはサーバ側にある。Emacs 側では一切持たない。
;;     org-roam が遅い原因(Elisp での結果変換、外部プロセスとの IPC、
;;     保存のたびの全体再クロール)を構造的に避けるための配置である。
;;   * 記事の編集はネイティブな Emacs バッファで行う。
;;   * 保存は楽観ロック付きの PUT。409 は2種類あり、それぞれ対応が違う。
;;   * 認証は無い。サーバが Host / Origin / Content-Type で守っている
;;     (DESIGN.md 4.4 に判断の記録がある)。トークンの設定項目は無い。

;;; Code:

(require 'url)
(require 'url-http)
(require 'json)
(require 'seq)
(require 'subr-x)

;; url-http がバッファローカルに設定する。参照するために宣言しておく。
(defvar url-http-response-status)

;; 別ファイルで定義する。循環 require を避けるため宣言だけしておく。
(declare-function markdown-mode "markdown-mode" ())
(declare-function enghi-agenda "enghi-agenda" ())
(declare-function enghi-consult-search "enghi-consult" ())

(defgroup enghi nil
  "ローカル Wiki + GTD (enghi) のクライアント."
  :group 'applications
  :prefix "enghi-")

(defcustom enghi-server-url "http://127.0.0.1:7777"
  "enghi サーバの URL.
ループバック以外を指すとサーバ側の Host 検査で 403 になる."
  :type 'string)

(defcustom enghi-request-timeout 10
  "同期リクエストのタイムアウト(秒)."
  :type 'integer)

;; 表示関数は差し替え可能にする(DESIGN.md 8-26)。
;; **既定は `browse-url'(外部ブラウザ)。**
;; `xwidget-webkit-browse-url' も選べる。編集はネイティブな Emacs バッファで行うため、
;; xwidget の既知の弱点(編集可能テキストエリア、キー入力の取り合い)は踏まない。
(defvar enghi-browse-function #'browse-url
  "enghi の画面をブラウザで開く関数.")

;;;; ---------------------------------------------------------------- HTTP

(define-error 'enghi-error "enghi のリクエストが失敗した")
(define-error 'enghi-http-error "enghi が HTTP エラーを返した" 'enghi-error)

;; 409 は2つの異なる意味を持ち、クライアントはまったく違う対応をしなければならない
;; (DESIGN.md 4.2)。混ぜないこと。
(define-error 'enghi-version-conflict
  "版が競合している(他の経路で更新された)" 'enghi-error)
(define-error 'enghi-title-conflict
  "同名(大小を区別しない)のページが既に存在する" 'enghi-error)

(defun enghi--url (path)
  "PATH を絶対 URL にする."
  (concat (string-remove-suffix "/" enghi-server-url) path))

(defun enghi--encode-query (params)
  "PARAMS (alist) をクエリ文字列にする。値が nil のものは落とす."
  (let ((parts (delq nil
                     (mapcar (lambda (kv)
                               (when (and (cdr kv) (not (equal (cdr kv) "")))
                                 (concat (url-hexify-string (format "%s" (car kv)))
                                         "="
                                         (url-hexify-string (format "%s" (cdr kv))))))
                             params))))
    (if parts (concat "?" (string-join parts "&")) "")))

(defun enghi--parse-json (text)
  "TEXT を JSON として読み、alist で返す。空や壊れている場合は nil."
  (when (and text (not (string-empty-p (string-trim text))))
    (condition-case nil
        (json-parse-string text
                           :object-type 'alist :array-type 'list
                           :null-object nil :false-object nil)
      (error nil))))

(defun enghi--response (buffer)
  "url の応答 BUFFER を (STATUS . DATA) に変換する."
  (unwind-protect
      (with-current-buffer buffer
        (let ((status (or url-http-response-status 0)))
          (goto-char (point-min))
          ;; ヘッダと本文の境界まで進む
          (if (re-search-forward "\n\r?\n" nil t)
              (let ((raw (buffer-substring-no-properties (point) (point-max))))
                ;; **url のバッファは unibyte なので `decode-coding-region\' では
                ;; multibyte にならず、日本語が化けたまま JSON に渡る**(実測確認済み)。
                ;; 文字列として復号すること。既に multibyte なら url 側が復号済み。
                (cons status
                      (enghi--parse-json
                       (if (multibyte-string-p raw) raw (decode-coding-string raw 'utf-8)))))
            (cons status nil))))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(defun enghi--signal-for (status data)
  "STATUS と DATA から適切なエラーを送出する."
  (let ((code (alist-get 'error data))
        (msg (or (alist-get 'message data) "")))
    (cond
     ;; **version_conflict — 楽観ロックの版不一致。**
     ;; 現行データとの差分を提示してマージさせる。入力は捨てない。
     ((equal code "version_conflict")
      (signal 'enghi-version-conflict (list msg (alist-get 'current data))))
     ;; **title_conflict — 新タイトルが他ページの正式名/別名と衝突。**
     ;; 別のタイトルを入力させる。本文は保持したまま。
     ((equal code "title_conflict")
      (signal 'enghi-title-conflict (list msg (alist-get 'conflicting_page data))))
     (t
      (signal 'enghi-http-error (list status (if (string-empty-p msg) code msg)))))))

(defun enghi-request (method path &optional payload params)
  "enghi へ同期リクエストを投げ、JSON を alist で返す.
METHOD は \"GET\" などの文字列。PAYLOAD は alist で、非 nil なら JSON で送る.
PARAMS はクエリ文字列の alist."
  (let* ((url-request-method method)
         (url-request-extra-headers
          (when payload
            ;; **書き込み系は application/json のみ受け付けられる**(DESIGN.md 4.4)。
            '(("Content-Type" . "application/json"))))
         (url-request-data
          (when payload
            ;; url-request-data は unibyte でなければならない
            (encode-coding-string (json-encode payload) 'utf-8)))
         (url (enghi--url (concat path (enghi--encode-query params))))
         (buffer (url-retrieve-synchronously url t t enghi-request-timeout)))
    (unless buffer
      (signal 'enghi-error
              (list (format "enghi サーバに接続できない: %s。`enghi serve' が動いているか確認すること"
                            enghi-server-url))))
    (pcase-let ((`(,status . ,data) (enghi--response buffer)))
      (if (and (>= status 200) (< status 300))
          data
        (enghi--signal-for status data)))))

(defun enghi-request-async (method path callback &optional payload params)
  "enghi へ非同期リクエストを投げ、成功時に CALLBACK を JSON で呼ぶ.
失敗時は CALLBACK を nil で呼ぶ(打鍵ごとの検索でエラーを出さないため)."
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

;;;; ---------------------------------------------------------------- 取得

(defun enghi-search (query &optional kind limit)
  "QUERY で横断検索し、結果のリストを返す.
KIND は \"page\" などで絞り込む。LIMIT の既定はサーバ側の 50."
  (alist-get 'results
             (enghi-request "GET" "/api/search"
                            nil `((q . ,query) (kind . ,kind) (limit . ,limit)))))

(defun enghi-page (slug)
  "SLUG のページを返す."
  (enghi-request "GET" (format "/api/pages/%s" (url-hexify-string slug))))

(defun enghi-pages (&optional limit sort)
  "ページ一覧を返す."
  (alist-get 'pages
             (enghi-request "GET" "/api/pages" nil
                            `((limit . ,(or limit 500)) (sort . ,sort)))))

(defun enghi-dashboard ()
  "ダッシュボードの集計を1発で返す."
  (enghi-request "GET" "/api/dashboard"))

(defun enghi-status ()
  "サーバの状態を返す(接続確認用)."
  (enghi-request "GET" "/api/status"))

;;;; ---------------------------------------------------------------- focus

(defun enghi-focus (path)
  "開いているブラウザタブを PATH へ遷移させる(DESIGN.md 4.3).
Emacs で検索・選択 → 別ディスプレイのブラウザが追従する、という使い方のためのもの."
  (interactive "sパス: ")
  (let ((res (enghi-request "POST" "/api/focus" `((path . ,path)))))
    (when (called-interactively-p 'interactive)
      (let ((n (or (alist-get 'clients res) 0)))
        (if (> n 0)
            (message "%s へ飛ばした(%d クライアント)" path n)
          (message "%s へ飛ばしたが、接続しているブラウザが無い" path))))
    res))

(defun enghi-browse (path)
  "PATH を `enghi-browse-function' で開く."
  (funcall enghi-browse-function (enghi--url path)))

;;;; ---------------------------------------------------------------- ページの編集

(defvar-local enghi-page-slug nil "このバッファが編集しているページの slug.")
(defvar-local enghi-page-version nil "取得時点の version(楽観ロック用).")
(defvar-local enghi-page-title nil "このバッファのページタイトル.")
(defvar-local enghi-page-tags nil "このバッファのページのタグ(文字列のリスト).")

(defvar enghi-page-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'enghi-save)
    (define-key map (kbd "C-c C-k") #'enghi-revert-page)
    (define-key map (kbd "C-c C-o") #'enghi-browse-this-page)
    (define-key map (kbd "C-c C-t") #'enghi-set-tags)
    (define-key map (kbd "C-c C-r") #'enghi-rename-page)
    (define-key map (kbd "C-c C-l") #'enghi-insert-link)
    map)
  "`enghi-page-mode' のキーマップ.")

;;;###autoload
(define-minor-mode enghi-page-mode
  "enghi のページを編集するためのマイナーモード.
`markdown-mode' の上に重ねて使う."
  :lighter " enghi"
  :keymap enghi-page-mode-map)

(defun enghi--markdown-mode ()
  "`markdown-mode' があれば有効にする.
`fboundp' だけで判定すると、package.el の autoload がまだ設定されていない場面
(素の `emacs -Q' に load-path を足しただけ、など)で取りこぼす."
  (when (or (fboundp 'markdown-mode) (require 'markdown-mode nil t))
    (markdown-mode)))

(defun enghi--page-buffer-name (title)
  (format "*enghi: %s*" title))

(defun enghi--fill-page-buffer (page)
  "PAGE (alist) の内容でカレントバッファを満たす."
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
              "  C-c C-c 保存")))

;;;###autoload
(defun enghi-open (slug)
  "SLUG のページを Emacs バッファで開く."
  (interactive (list (enghi--read-page-slug "開く記事: ")))
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
  "記事を選んで開く."
  (interactive)
  (enghi-open (enghi--read-page-slug "記事: ")))

;;;###autoload
(defun enghi-open-in-browser ()
  "記事を選んでブラウザで開く(`enghi-browse-function')."
  (interactive)
  (enghi-browse (format "/wiki/%s" (enghi--read-page-slug "ブラウザで開く記事: "))))

;;;###autoload
(defun enghi-focus-page ()
  "記事を選んで、開いているブラウザタブをそこへ飛ばす."
  (interactive)
  (enghi-focus (format "/wiki/%s" (enghi--read-page-slug "ブラウザを飛ばす先: "))))

(defun enghi--read-page-slug (prompt)
  "PROMPT で記事を選ばせ、slug を返す."
  (let* ((pages (enghi-pages 500))
         (cands (mapcar (lambda (p)
                          (cons (format "%s%s"
                                        (alist-get 'title p)
                                        (if-let* ((tags (alist-get 'tags p)))
                                            (format "  [%s]" (string-join tags ", "))
                                          ""))
                                (alist-get 'slug p)))
                        pages)))
    (unless cands (user-error "記事がまだ1件もない"))
    (cdr (assoc (completing-read prompt cands nil t) cands))))

(defun enghi-browse-this-page ()
  "このバッファのページをブラウザで開く."
  (interactive)
  (unless enghi-page-slug (user-error "enghi のページバッファではない"))
  (enghi-browse (format "/wiki/%s" enghi-page-slug)))

(defun enghi-revert-page ()
  "サーバの内容でバッファを取り直す."
  (interactive)
  (unless enghi-page-slug (user-error "enghi のページバッファではない"))
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "変更を捨ててサーバの内容に戻す? "))
    (enghi--fill-page-buffer (enghi-page enghi-page-slug))
    (message "サーバの内容に戻した")))

(defun enghi-set-tags (tags)
  "このページのタグを TAGS にする(カンマ区切りで入力)."
  (interactive
   (list (read-string "タグ(カンマ区切り): " (string-join (or enghi-page-tags '()) ", "))))
  (unless enghi-page-slug (user-error "enghi のページバッファではない"))
  (setq enghi-page-tags
        (seq-remove #'string-empty-p
                    (mapcar #'string-trim (split-string tags "[,、]" t))))
  ;; **タグだけの変更でも version は上がる**ので、保存まで通す(DESIGN.md 4.2)。
  (enghi-save))

(defun enghi-rename-page (new-title)
  "このページのタイトルを NEW-TITLE に変える."
  (interactive (list (read-string "新しいタイトル: " enghi-page-title)))
  (unless enghi-page-slug (user-error "enghi のページバッファではない"))
  (setq enghi-page-title new-title)
  (enghi-save))

(defun enghi-insert-link (slug)
  "記事を選んで [[タイトル]] を挿入する."
  (interactive (list (enghi--read-page-slug "リンク先: ")))
  (let ((page (enghi-page slug)))
    (insert (format "[[%s]]" (alist-get 'title page)))))

(defun enghi-save ()
  "このバッファの内容をサーバへ保存する(楽観ロック付き PUT).
409 が返った場合は種類に応じて対応を変える(DESIGN.md 4.2)."
  (interactive)
  (unless enghi-page-slug (user-error "enghi のページバッファではない"))
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
                      "  C-c C-c 保存"))
          (message "保存した (v%s)" enghi-page-version))

      ;; **入力は捨てない。**現行データとの差分を出してマージさせる。
      (enghi-version-conflict
       (enghi--show-conflict (nth 2 err) body)
       (message "版が競合している。差分を確認してマージすること"))

      ;; **本文は保持したまま、別のタイトルを入力させる。**
      (enghi-title-conflict
       (let ((other (nth 2 err)))
         (message "同名のページが既にある: %s (/wiki/%s)"
                  (alist-get 'title other) (alist-get 'slug other))
         (setq enghi-page-title
               (read-string "別のタイトル: " enghi-page-title))
         (enghi-save))))))

(defun enghi--show-conflict (current body)
  "CURRENT (サーバの現行ページ) と BODY (手元の内容) の差分を出す."
  (let ((server-buf (get-buffer-create "*enghi conflict: サーバ*"))
        (local-buf (get-buffer-create "*enghi conflict: 手元*")))
    (with-current-buffer server-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or (alist-get 'body current) ""))
        (enghi--markdown-mode)
        (setq header-line-format
              (format "サーバ側 v%s — こちらが現行" (alist-get 'version current)))))
    (with-current-buffer local-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert body)
        (enghi--markdown-mode)
        (setq header-line-format "手元の編集内容 — 捨てないこと")))
    (ediff-buffers local-buf server-buf)))

;;;; ---------------------------------------------------------------- capture

;;;###autoload
(defun enghi-capture (title)
  "TITLE を GTD の Inbox に1行入れる。どこからでも使える."
  (interactive "sInbox へ: ")
  (when (string-empty-p (string-trim title))
    (user-error "空では入れられない"))
  (let ((task (enghi-request "POST" "/api/tasks" `((title . ,title)))))
    (message "Inbox に入れた: %s" (alist-get 'title task))
    task))

;;;###autoload
(defun enghi-capture-region (start end)
  "選択範囲を Inbox に入れる。1行目をタイトル、残りをメモにする."
  (interactive "r")
  (let* ((text (string-trim (buffer-substring-no-properties start end)))
         (lines (split-string text "\n"))
         (title (car lines))
         (note (string-join (cdr lines) "\n")))
    (enghi-request "POST" "/api/tasks" `((title . ,title) (note . ,note)))
    (message "Inbox に入れた: %s" title)))

;;;###autoload
(defun enghi-file-region-as-page (start end title)
  "選択範囲を Wiki ページにする."
  (interactive "r\nsタイトル: ")
  (let ((page (enghi-request "POST" "/api/pages"
                             `((title . ,title)
                               (body . ,(buffer-substring-no-properties start end))
                               (tags . [])))))
    (message "記事にした: %s" (alist-get 'title page))
    (enghi-open (alist-get 'slug page))))


;;;; ---------------------------------------------------------------- 入り口

(defvar enghi-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "f") #'enghi-find-page)
    (define-key map (kbd "s") #'enghi-search-command)
    (define-key map (kbd "c") #'enghi-capture)
    (define-key map (kbd "a") #'enghi-agenda)
    (define-key map (kbd "b") #'enghi-open-in-browser)
    (define-key map (kbd "o") #'enghi-focus-page)
    (define-key map (kbd "d") #'enghi-browse-dashboard)
    (define-key map (kbd "n") #'enghi-new-page)
    map)
  "enghi のコマンドをまとめたキーマップ.
設定例:
  (global-set-key (kbd \"C-c n\") enghi-command-map)")

;;;###autoload
(defun enghi-search-command ()
  "検索する。consult があればそちらを使う."
  (interactive)
  (if (require 'enghi-consult nil t)
      (call-interactively #'enghi-consult-search)
    ;; consult が無い環境でも動くようにしておく
    (let* ((query (read-string "enghi 検索: "))
           (results (enghi-search query))
           (cands (mapcar (lambda (r)
                            (cons (format "[%s] %s" (alist-get 'kind r) (alist-get 'title r)) r))
                          results)))
      (unless cands (user-error "見つからなかった"))
      (let ((chosen (cdr (assoc (completing-read "結果: " cands nil t) cands))))
        (if (equal (alist-get 'kind chosen) "page")
            (enghi-open (alist-get 'slug chosen))
          (enghi-browse "/"))))))

;;;###autoload
(defun enghi-new-page (title)
  "TITLE で新しい記事を作って開く."
  (interactive "s新しい記事のタイトル: ")
  (condition-case err
      (let ((page (enghi-request "POST" "/api/pages"
                                 `((title . ,title) (body . "") (tags . [])))))
        (enghi-open (alist-get 'slug page)))
    (enghi-title-conflict
     (let ((other (nth 2 err)))
       (message "同名のページが既にある: %s" (alist-get 'title other))
       (enghi-open (alist-get 'slug other))))))

;;;###autoload
(defun enghi-browse-dashboard ()
  "ダッシュボードをブラウザで開く."
  (interactive)
  (enghi-browse "/"))

;;;###autoload
(defun enghi-setup ()
  "推奨の設定を入れる。init.el から呼ぶ.
  (require \='enghi)
  (enghi-setup)"
  (interactive)
  (autoload 'enghi-agenda "enghi-agenda" nil t)
  (autoload 'enghi-consult-search "enghi-consult" nil t)
  (global-set-key (kbd "C-c n") enghi-command-map)
  (message "enghi: C-c n で使える (f 記事 / s 検索 / c capture / a agenda)"))

(provide 'enghi)
;;; enghi.el ends here
