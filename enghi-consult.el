;;; enghi-consult.el --- enghi の検索を consult に載せる -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1") (consult "1.0"))

;;; Commentary:

;; 打鍵ごとに `/api/search' を叩く非同期ソース(DESIGN.md 8-21)。
;;
;; **検索とランキングはサーバ側で完結している。**Emacs 側でフィルタや
;; 並べ替えをしないこと。3 万件規模で打鍵ごとに再検索して体感ゼロ遅延、
;; というのがサーバ側の設計目標であり、Elisp で結果を捏ねると
;; org-roam が遅い原因そのものを再現することになる。
;;
;; そのため completion スタイルによる絞り込みも無効にする
;; (`consult--read' の :require-match と category で制御)。

;;; Code:

(require 'enghi)
(require 'consult)
(require 'seq)
(require 'subr-x)

(defcustom enghi-consult-min-input 1
  "この文字数以上でサーバに問い合わせる.
サーバ側は 2 文字以下も専用の経路で引けるので、小さくてよい."
  :type 'integer
  :group 'enghi)

(defface enghi-consult-kind
  '((t :inherit font-lock-type-face))
  "検索結果の種別バッジの face."
  :group 'enghi)

(defface enghi-consult-snippet
  '((t :inherit font-lock-comment-face))
  "検索結果のスニペットの face."
  :group 'enghi)

(defun enghi-consult--kind-label (kind)
  (pcase kind
    ("page" "記事")
    ("project" "Proj")
    ("task" "Task")
    ("area" "Area")
    (_ kind)))

(defun enghi-consult--format (result)
  "RESULT (alist) を候補の文字列にする。元データは text property で持たせる."
  (let* ((kind (alist-get 'kind result))
         (title (or (alist-get 'title result) ""))
         (snippet (or (alist-get 'snippet result) ""))
         (via (alist-get 'via result))
         (line (concat
                (propertize (format "%-4s " (enghi-consult--kind-label kind))
                            'face 'enghi-consult-kind)
                title
                (unless (string-empty-p snippet)
                  (propertize (format "  %s" (string-replace "\n" " " snippet))
                              'face 'enghi-consult-snippet))
                (when (equal via "tag")
                  (propertize "  (タグ一致)" 'face 'enghi-consult-snippet))
                (when (equal via "alias")
                  (propertize "  (別名一致)" 'face 'enghi-consult-snippet)))))
    (propertize line 'enghi-result result)))

(defun enghi-consult--candidates (input)
  "INPUT でサーバに問い合わせ、候補のリストを返す.
**ここで絞り込みや並べ替えをしないこと。**順位は bm25 でサーバが決めている."
  (when (>= (length (string-trim input)) enghi-consult-min-input)
    (condition-case nil
        (mapcar #'enghi-consult--format (enghi-search input nil 50))
      ;; 打鍵ごとに走るので、エラーはミニバッファを壊さないよう握りつぶす
      (enghi-error nil))))

(defun enghi-consult--visit (candidate &optional browse)
  "CANDIDATE を開く。BROWSE が非 nil ならブラウザへ飛ばす."
  (when-let* ((result (get-text-property 0 'enghi-result candidate))
              (kind (alist-get 'kind result)))
    (pcase kind
      ("page"
       (if browse
           (enghi-browse (format "/wiki/%s" (alist-get 'slug result)))
         (enghi-open (alist-get 'slug result))))
      ("project" (enghi-browse (format "/gtd/project/%s" (alist-get 'id result))))
      ("task" (enghi-browse (format "/gtd/clarify/%s" (alist-get 'id result))))
      ("area" (enghi-browse (format "/gtd/area/%s" (alist-get 'id result))))
      (_ (message "開けない種別: %s" kind)))))

;;;###autoload
(defun enghi-consult-search (&optional initial)
  "打鍵ごとに enghi を横断検索する。INITIAL は初期入力."
  (interactive)
  (let ((selected
         (consult--read
          (consult--dynamic-collection #'enghi-consult--candidates)
          :prompt "enghi 検索: "
          :initial initial
          :category 'enghi-result
          :require-match t
          :sort nil
          :lookup #'consult--lookup-member
          :history 'enghi-consult--history)))
    (when selected (enghi-consult--visit selected))))

(defvar enghi-consult--history nil
  "`enghi-consult-search' の履歴.")

;;;###autoload
(defun enghi-consult-search-browse ()
  "検索して、選んだものを開いているブラウザタブに表示させる."
  (interactive)
  (let ((selected
         (consult--read
          (consult--dynamic-collection #'enghi-consult--candidates)
          :prompt "enghi 検索(ブラウザへ): "
          :category 'enghi-result
          :require-match t
          :sort nil
          :lookup #'consult--lookup-member
          :history 'enghi-consult--history)))
    (when-let* ((result (and selected (get-text-property 0 'enghi-result selected))))
      ;; **POST /api/focus は開いているタブを遷移させる**(DESIGN.md 4.3)。
      ;; 別ディスプレイにブラウザを開きっぱなしにしておく使い方のためのもの。
      (enghi-focus
       (pcase (alist-get 'kind result)
         ("page" (format "/wiki/%s" (alist-get 'slug result)))
         ("project" (format "/gtd/project/%s" (alist-get 'id result)))
         ("task" (format "/gtd/clarify/%s" (alist-get 'id result)))
         ("area" (format "/gtd/area/%s" (alist-get 'id result)))
         (_ "/"))))))

;;;###autoload
(defun enghi-consult-insert-link ()
  "検索して選んだ記事への [[リンク]] を挿入する."
  (interactive)
  (let ((selected
         (consult--read
          (consult--dynamic-collection
           (lambda (input)
             (when (>= (length (string-trim input)) enghi-consult-min-input)
               (condition-case nil
                   (mapcar #'enghi-consult--format (enghi-search input "page" 50))
                 (enghi-error nil)))))
          :prompt "リンク先: "
          :category 'enghi-result
          :require-match t
          :sort nil
          :lookup #'consult--lookup-member)))
    (when-let* ((result (and selected (get-text-property 0 'enghi-result selected))))
      (insert (format "[[%s]]" (alist-get 'title result))))))

(provide 'enghi-consult)
;;; enghi-consult.el ends here
