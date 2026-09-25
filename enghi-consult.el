;;; enghi-consult.el --- Consult integration for enghi search -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1") (consult "1.0"))

;;; Commentary:

;; Async source that calls `/api/search' on every keystroke (DESIGN.md 8-21).
;;
;; **Search and ranking are handled entirely on the server.** Do not filter or
;; sort on the Emacs side. The server's design goal is zero perceived latency
;; when re-searching on every keystroke across 30,000 items. Massaging results
;; in Elisp would recreate the exact reason org-roam is slow.
;;
;; Therefore, filtering by completion styles is also disabled (controlled via
;; :require-match and category in `consult--read').

;;; Code:

(require 'enghi)
(require 'consult)
(require 'seq)
(require 'subr-x)

(defcustom enghi-consult-min-input 1
  "Query the server when input reaches at least this many characters.
The server can handle 2 or fewer characters via a dedicated path, so this can
be small."
  :type 'integer
  :group 'enghi)

(defface enghi-consult-kind
  '((t :inherit font-lock-type-face))
  "Face for search result kind badges."
  :group 'enghi)

(defface enghi-consult-snippet
  '((t :inherit font-lock-comment-face))
  "Face for search result snippets."
  :group 'enghi)

(defun enghi-consult--kind-label (kind)
  (pcase kind
    ("page" "Page")
    ("project" "Proj")
    ("task" "Task")
    ("area" "Area")
    (_ kind)))

(defun enghi-consult--format (result)
  "Format RESULT (alist) as a candidate string.
Store the original data in a text property."
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
                  (propertize "  (tag match)" 'face 'enghi-consult-snippet))
                (when (equal via "alias")
                  (propertize "  (alias match)" 'face 'enghi-consult-snippet)))))
    (propertize line 'enghi-result result)))

(defun enghi-consult--candidates (input)
  "Query the server with INPUT and return a list of candidates.
**Do not filter or sort here.** The server determines ranking with bm25."
  (when (>= (length (string-trim input)) enghi-consult-min-input)
    (condition-case nil
        (mapcar #'enghi-consult--format (enghi-search input nil 50))
      ;; Runs on every keystroke, so suppress errors to avoid breaking the
      ;; minibuffer
      (enghi-error nil))))

;;;###autoload
(defun enghi-consult-read-result (&optional prompt initial)
  "Search across enghi on every keystroke and return the chosen result.
PROMPT defaults to \"Search enghi: \". INITIAL is the initial input. The
result is an alist as returned by `/api/search', or nil."
  (when-let* ((selected
               (consult--read
                ;; consult's own minimum (`consult-async-min-input', 3 by
                ;; default) would hide short queries, which matter in Japanese
                (consult--dynamic-collection #'enghi-consult--candidates
                  :min-input enghi-consult-min-input)
                :prompt (or prompt "Search enghi: ")
                :initial initial
                :category 'enghi-result
                :require-match t
                :sort nil
                :lookup #'consult--lookup-member
                :history 'enghi-consult--history)))
    (get-text-property 0 'enghi-result selected)))

;;;###autoload
(defun enghi-consult-search (&optional initial)
  "Search across enghi on every keystroke.
INITIAL is the initial input."
  (interactive)
  (when-let* ((result (enghi-consult-read-result nil initial)))
    (enghi-visit-result result)))

(defvar enghi-consult--history nil
  "History for `enghi-consult-search'.")

;;;###autoload
(defun enghi-consult-search-browse ()
  "Search and display the selected item in an open browser tab."
  (interactive)
  (when-let* ((result (enghi-consult-read-result "Search enghi (browser): ")))
    ;; **POST /api/focus navigates the open tab** (DESIGN.md 4.3). This is
    ;; for keeping a browser open on a separate display.
    (enghi-focus (or (enghi--result-path result) "/"))))

;;;###autoload
(defun enghi-consult-insert-link ()
  "Search and insert a [[link]] to the selected page."
  (interactive)
  (let ((selected
         (consult--read
          (consult--dynamic-collection
           (lambda (input)
             (when (>= (length (string-trim input)) enghi-consult-min-input)
               (condition-case nil
                   (mapcar #'enghi-consult--format (enghi-search input "page" 50))
                 (enghi-error nil))))
           :min-input enghi-consult-min-input)
          :prompt "Link target: "
          :category 'enghi-result
          :require-match t
          :sort nil
          :lookup #'consult--lookup-member)))
    (when-let* ((result (and selected (get-text-property 0 'enghi-result selected))))
      (insert (format "[[%s]]" (alist-get 'title result))))))

(provide 'enghi-consult)
;;; enghi-consult.el ends here
