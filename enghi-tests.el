;;; enghi-tests.el --- enghi.el のテスト -*- lexical-binding: t; -*-

;;; Commentary:
;; 実際に動いているサーバに対して実行する。
;;   emacs -Q --batch -L elisp -l elisp/enghi-tests.el -f ert-run-tests-batch-and-exit
;; サーバの URL は環境変数 ENGHI_TEST_URL で指定する。

;;; Code:

(require 'ert)
(require 'enghi)
(require 'enghi-agenda)

(setq enghi-server-url (or (getenv "ENGHI_TEST_URL") "http://127.0.0.1:7799"))

(defun enghi-tests--unique (prefix)
  (format "%s-%s" prefix (random 100000)))

(ert-deftest enghi-test-status ()
  "サーバに繋がること."
  (let ((st (enghi-status)))
    (should (alist-get 'ok st))))

(ert-deftest enghi-test-page-round-trip ()
  "作成 → 取得 → 編集 → 保存 が通ること."
  (let* ((title (enghi-tests--unique "テスト記事"))
         (page (enghi-request "POST" "/api/pages"
                              `((title . ,title) (body . "最初の本文") (tags . ["テスト"]))))
         (slug (alist-get 'slug page)))
    (should (equal (alist-get 'title page) title))
    (let ((buf (enghi-open slug)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal enghi-page-slug slug))
            (should (equal (buffer-string) "最初の本文"))
            (should (= enghi-page-version 1))
            ;; 編集して保存
            (goto-char (point-max))
            (insert "\n\n追記した。")
            (enghi-save)
            (should (= enghi-page-version 2))
            (should-not (buffer-modified-p))
            ;; サーバ側に反映されている
            (should (string-match-p "追記した。"
                                    (alist-get 'body (enghi-page slug)))))
        (kill-buffer buf)))))

(ert-deftest enghi-test-version-conflict-keeps-input ()
  "版が競合したとき、手元の入力を捨てないこと."
  (let* ((title (enghi-tests--unique "競合テスト"))
         (page (enghi-request "POST" "/api/pages"
                              `((title . ,title) (body . "元の本文"))))
         (slug (alist-get 'slug page))
         (buf (enghi-open slug)))
    (unwind-protect
        (with-current-buffer buf
          ;; 別経路でサーバ側を更新する(Emacs のバッファは古いままになる)
          (enghi-request "PUT" (format "/api/pages/%s" (url-hexify-string slug))
                         `((title . ,title) (body . "別経路で書き換えた") (version . 1)))
          (erase-buffer)
          (insert "Emacs 側で書いた内容")
          ;; ediff を出さずに検査したいので差分表示だけ潰す
          (cl-letf (((symbol-function 'enghi--show-conflict) (lambda (&rest _) nil)))
            (enghi-save))
          ;; **入力が残っていること。**これが消えるのが最悪の壊れ方。
          (should (equal (buffer-string) "Emacs 側で書いた内容"))
          (should (= enghi-page-version 1)))
      (kill-buffer buf))))

(ert-deftest enghi-test-title-conflict-signals ()
  "タイトル衝突は version 競合とは別のエラーとして上がること."
  (let* ((a (enghi-tests--unique "衝突A"))
         (b (enghi-tests--unique "衝突B")))
    (enghi-request "POST" "/api/pages" `((title . ,a) (body . "")))
    (let* ((pb (enghi-request "POST" "/api/pages" `((title . ,b) (body . ""))))
           (slug (alist-get 'slug pb))
           (err (should-error
                 (enghi-request "PUT" (format "/api/pages/%s" (url-hexify-string slug))
                                `((title . ,a) (body . "") (version . 1)))
                 :type 'enghi-title-conflict)))
      ;; 衝突相手のページが取れること(どのページと衝突したか分からないと辿れない)
      (should (equal (alist-get 'title (nth 2 err)) a)))))

(ert-deftest enghi-test-search ()
  "検索がサーバ側で行われ、結果が返ること."
  (let ((title (enghi-tests--unique "検索対象")))
    (enghi-request "POST" "/api/pages"
                   `((title . ,title) (body . "オフィスの移転について書いた本文")))
    (let ((results (enghi-search "オフィスの移転")))
      (should results)
      (should (seq-find (lambda (r) (equal (alist-get 'kind r) "page")) results)))
    ;; 2 文字クエリ(日本語の主力)
    (should (enghi-search "移転"))
    ;; FTS5 の構文エラーになりうる文字列でも 500 にならない
    (should (listp (enghi-search "C++")))
    (should (listp (enghi-search "a\"b")))))

(ert-deftest enghi-test-capture ()
  "どこからでも1行を Inbox に入れられること."
  (let* ((title (enghi-tests--unique "捕まえた項目"))
         (task (enghi-capture title)))
    (should (equal (alist-get 'state task) "inbox"))
    (should (equal (alist-get 'title task) title))))

(ert-deftest enghi-test-focus ()
  "focus がサーバに受け付けられること(接続クライアントは 0 でよい)."
  (let ((res (enghi-focus "/wiki/test")))
    (should (alist-get 'ok res))))

(ert-deftest enghi-test-agenda-renders ()
  "agenda バッファが作られ、状態変更が PATCH にマップされること."
  (let* ((title (enghi-tests--unique "agenda 用"))
         (task (enghi-capture title)))
    (enghi-agenda)
    (unwind-protect
        (with-current-buffer enghi-agenda-buffer-name
          (should (string-match-p (regexp-quote title) (buffer-string)))
          ;; 該当行へ移動して n(next にする)
          (goto-char (point-min))
          (should (search-forward title nil t))
          (beginning-of-line)
          (enghi-agenda-set-next)
          (should (equal (alist-get 'state (enghi-request
                                            "GET" (format "/api/tasks/%s"
                                                          (alist-get 'id task))))
                         nil))
          ;; API はタスクを task キーで返す
          (let ((got (enghi-request "GET" (format "/api/tasks/%s" (alist-get 'id task)))))
            (should (equal (alist-get 'state (alist-get 'task got)) "next"))))
      (kill-buffer enghi-agenda-buffer-name))))

(ert-deftest enghi-test-error-when-server-down ()
  "サーバが居ないときは分かるエラーになること."
  (let ((enghi-server-url "http://127.0.0.1:1"))
    (should-error (enghi-status) :type 'enghi-error)))

(provide 'enghi-tests)
;;; enghi-tests.el ends here

;;;; consult 連携(consult が入っている環境でのみ)

(when (require 'consult nil t)
  (require 'enghi-consult)

  (ert-deftest enghi-test-consult-candidates ()
    "打鍵ごとの問い合わせが候補を返すこと."
    (let ((title (enghi-tests--unique "consult 対象")))
      (enghi-request "POST" "/api/pages"
                     `((title . ,title) (body . "オフィスの移転について")))
      (let ((cands (enghi-consult--candidates "オフィスの移転")))
        (should cands)
        ;; 元データが text property で載っていること(開くのに使う)
        (should (get-text-property 0 'enghi-result (car cands))))))

  (ert-deftest enghi-test-consult-no-client-side-filtering ()
    "サーバが返した順序と件数をそのまま使うこと.
Elisp 側で絞り込むと、bm25 の順位と 3 節の設計が無意味になる."
    (let ((title (enghi-tests--unique "順序テスト")))
      (enghi-request "POST" "/api/pages" `((title . ,title) (body . "共通語 の本文")))
      (let ((server (enghi-search "共通語" nil 50))
            (cands (enghi-consult--candidates "共通語")))
        (should (= (length server) (length cands)))
        (should (equal (mapcar (lambda (r) (alist-get 'title r)) server)
                       (mapcar (lambda (c) (alist-get 'title (get-text-property 0 'enghi-result c)))
                               cands))))))

  (ert-deftest enghi-test-consult-short-input-skipped ()
    "短すぎる入力ではサーバに問い合わせないこと."
    (let ((enghi-consult-min-input 3))
      (should-not (enghi-consult--candidates "あ"))
      (should-not (enghi-consult--candidates "")))))
