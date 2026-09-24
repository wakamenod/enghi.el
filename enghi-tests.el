;;; enghi-tests.el --- Tests for enghi.el -*- lexical-binding: t; -*-

;;; Commentary: Run against a running server. emacs -Q --batch -L elisp -l
;;; elisp/enghi-tests.el -f ert-run-tests-batch-and-exit Specify the server
;;; URL with the ENGHI_TEST_URL environment variable.

;;; Code:

(require 'ert)
(require 'enghi)

(setq enghi-server-url (or (getenv "ENGHI_TEST_URL") "http://127.0.0.1:7799"))

(defun enghi-tests--unique (prefix)
  (format "%s-%s" prefix (random 100000)))

(ert-deftest enghi-test-status ()
  "Connect to the server."
  (let ((st (enghi-status)))
    (should (alist-get 'ok st))))

(ert-deftest enghi-test-page-round-trip ()
  "Ensure create → fetch → edit → save passes."
  (let* ((title (enghi-tests--unique "Test article"))
         (page (enghi-request "POST" "/api/pages"
                              `((title . ,title) (body . "Initial body") (tags . ["Test"]))))
         (slug (alist-get 'slug page)))
    (should (equal (alist-get 'title page) title))
    (let ((buf (enghi-open slug)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal enghi-page-slug slug))
            (should (equal (buffer-string) "Initial body"))
            (should (= enghi-page-version 1))
            ;; Edit and save
            (goto-char (point-max))
            (insert "\n\nAppended.")
            (enghi-save)
            (should (= enghi-page-version 2))
            (should-not (buffer-modified-p))
            ;; Reflected on the server
            (should (string-match-p "Appended."
                                    (alist-get 'body (enghi-page slug)))))
        (kill-buffer buf)))))

(ert-deftest enghi-test-version-conflict-keeps-input ()
  "Do not discard local input when versions conflict."
  (let* ((title (enghi-tests--unique "Conflict test"))
         (page (enghi-request "POST" "/api/pages"
                              `((title . ,title) (body . "Original body"))))
         (slug (alist-get 'slug page))
         (buf (enghi-open slug)))
    (unwind-protect
        (with-current-buffer buf
          ;; Update the server via another route (the Emacs buffer remains
          ;; stale)
          (enghi-request "PUT" (format "/api/pages/%s" (url-hexify-string slug))
                         `((title . ,title) (body . "Rewritten via another route") (version . 1)))
          (erase-buffer)
          (insert "Content written on the Emacs side")
          ;; Suppress only the diff display to test without opening ediff
          (cl-letf (((symbol-function 'enghi--show-conflict) (lambda (&rest _) nil)))
            (enghi-save))
          ;; **The input must remain.** Losing this is the worst kind of
          ;; breakage.
          (should (equal (buffer-string) "Content written on the Emacs side"))
          (should (= enghi-page-version 1)))
      (kill-buffer buf))))

(ert-deftest enghi-test-title-conflict-signals ()
  "Signal title conflict as a different error from version conflict."
  (let* ((a (enghi-tests--unique "Conflict A"))
         (b (enghi-tests--unique "Conflict B")))
    (enghi-request "POST" "/api/pages" `((title . ,a) (body . "")))
    (let* ((pb (enghi-request "POST" "/api/pages" `((title . ,b) (body . ""))))
           (slug (alist-get 'slug pb))
           (err (should-error
                 (enghi-request "PUT" (format "/api/pages/%s" (url-hexify-string slug))
                                `((title . ,a) (body . "") (version . 1)))
                 :type 'enghi-title-conflict)))
      ;; Get the conflicting page (cannot trace it without knowing which page
      ;; it conflicted with)
      (should (equal (alist-get 'title (nth 2 err)) a)))))

(ert-deftest enghi-test-search ()
  "Search on the server and return results."
  (let ((title (enghi-tests--unique "Search target")))
    (enghi-request "POST" "/api/pages"
                   `((title . ,title) (body . "Body written about office relocation")))
    (let ((results (enghi-search "Office relocation")))
      (should results)
      (should (seq-find (lambda (r) (equal (alist-get 'kind r) "page")) results)))
    ;; 2-character query (mainstay for Japanese)
    (should (enghi-search "Relocation"))
    ;; Does not return 500 even for strings that could cause FTS5 syntax
    ;; errors
    (should (listp (enghi-search "C++")))
    (should (listp (enghi-search "a\"b")))))

(ert-deftest enghi-test-capture ()
  "Ensure a single line can be put into the Inbox from anywhere."
  (let* ((title (enghi-tests--unique "Captured item"))
         (task (enghi-capture title)))
    (should (equal (alist-get 'state task) "inbox"))
    (should (equal (alist-get 'title task) title))))

(ert-deftest enghi-test-focus ()
  "Ensure focus is accepted by the server (connected clients can be 0)."
  (let ((res (enghi-focus "/wiki/test")))
    (should (alist-get 'ok res))))

(ert-deftest enghi-test-error-when-server-down ()
  "Signal a clear error when the server is not running."
  (let ((enghi-server-url "http://127.0.0.1:1"))
    (should-error (enghi-status) :type 'enghi-error)))

(provide 'enghi-tests)
;;; enghi-tests.el ends here

;;;; consult integration (only in environments with consult)

(when (require 'consult nil t)
  (require 'enghi-consult)

  (ert-deftest enghi-test-consult-candidates ()
    "Return candidates for per-keystroke queries."
    (let ((title (enghi-tests--unique "consult target")))
      (enghi-request "POST" "/api/pages"
                     `((title . ,title) (body . "About office relocation")))
      (let ((cands (enghi-consult--candidates "Office relocation")))
        (should cands)
        ;; Original data is attached as a text property (used to open it)
        (should (get-text-property 0 'enghi-result (car cands))))))

  (ert-deftest enghi-test-consult-no-client-side-filtering ()
    "Use the order and count returned by the server as is.
Filtering on the Elisp side makes the bm25 ranking and section 3 design
meaningless."
    (let ((title (enghi-tests--unique "Order test")))
      (enghi-request "POST" "/api/pages" `((title . ,title) (body . "Common word body")))
      (let ((server (enghi-search "Common word" nil 50))
            (cands (enghi-consult--candidates "Common word")))
        (should (= (length server) (length cands)))
        (should (equal (mapcar (lambda (r) (alist-get 'title r)) server)
                       (mapcar (lambda (c) (alist-get 'title (get-text-property 0 'enghi-result c)))
                               cands))))))

  (ert-deftest enghi-test-consult-short-input-skipped ()
    "Do not query the server on input that is too short."
    (let ((enghi-consult-min-input 3))
      (should-not (enghi-consult--candidates "a"))
      (should-not (enghi-consult--candidates "")))))

;;;; URLs passed to the browser

(ert-deftest enghi-test-browse-url-is-encoded ()
  "Ensure URLs containing Japanese are passed percent-encoded.
Passing them raw makes the result depend on how the display function encodes
them."
  (let (captured)
    (let ((enghi-browse-function (lambda (url) (setq captured url))))
      (enghi-browse "/wiki/日本語のタイトル"))
    (should (string-match-p "%E6%97%A5%E6%9C%AC%E8%AA%9E" captured))
    (should-not (string-match-p "日本語" captured))
    ;; Leave as is if ASCII only
    (let ((enghi-browse-function (lambda (url) (setq captured url))))
      (enghi-browse "/wiki/design-notes"))
    (should (string-suffix-p "/wiki/design-notes" captured))))

(ert-deftest enghi-test-browse-reports-dead-server ()
  "Signal a clear error before passing to the browser when the server is down."
  (let ((enghi-server-url "http://127.0.0.1:1")
        (opened nil))
    (let ((enghi-browse-function (lambda (_url) (setq opened t))))
      (should-error (enghi-browse "/wiki/foo") :type 'error))
    (should-not opened)))

;;;; Keys sent to the webkit page

(defmacro enghi-tests--with-xwidget-stubs (path &rest body)
  "Run BODY with webkit stubbed out, showing enghi PATH.
Bind `scripts' to the JS sent and `forwarded' to whether it went forward."
  (declare (indent 1))
  `(let (scripts forwarded)
     (cl-letf (((symbol-function 'xwidget-webkit-current-session) (lambda () 'session))
               ((symbol-function 'xwidget-webkit-execute-script)
                (lambda (session script &optional _cb)
                  (should (eq session 'session))
                  (push script scripts)))
               ((symbol-function 'xwidget-webkit-forward) (lambda () (setq forwarded t)))
               ((symbol-function 'enghi--xwidget-path) (lambda () ,path)))
       ,@body)))

(ert-deftest enghi-test-xwidget-key-script ()
  "Ensure keys become a keydown with a properly escaped key."
  (should (equal (enghi--xwidget-key-name ?j) "j"))
  (should (equal (enghi--xwidget-key-name ?/) "/"))
  (should (equal (enghi--xwidget-key-name 13) "Enter"))
  (should (equal (enghi--xwidget-key-name 'return) "Enter"))
  (should (equal (enghi--xwidget-key-script "j")
                 "document.dispatchEvent(new KeyboardEvent('keydown', {key: \"j\", bubbles: true}));"))
  (should (string-match-p "{key: \"\\\\\"\"" (enghi--xwidget-key-script "\"")))
  (should (string-match-p "{key: \"\\\\\\\\\"" (enghi--xwidget-key-script "\\"))))

(ert-deftest enghi-test-xwidget-send-key ()
  "Ensure the invoking key is sent to the page."
  (enghi-tests--with-xwidget-stubs "/"
    (let ((last-command-event ?k)) (enghi-xwidget-send-key))
    (let ((last-command-event 13)) (enghi-xwidget-send-key))
    (should (string-match-p "key: \"k\"" (nth 1 scripts)))
    (should (string-match-p "key: \"Enter\"" (nth 0 scripts)))))

(ert-deftest enghi-test-xwidget-f-dispatch ()
  "Ensure `f' files in the GTD lists and goes forward elsewhere."
  (should (eq (lookup-key enghi-xwidget-mode-map "f") #'enghi-xwidget-key))
  (let ((last-command-event ?f))
    (enghi-tests--with-xwidget-stubs "/gtd/inbox"
      (enghi-xwidget-key)
      (should (string-match-p "key: \"f\"" (car scripts)))
      (should-not forwarded))
    (dolist (path '("/" "/wiki/foo" "/gtd" nil))
      (enghi-tests--with-xwidget-stubs path
        (enghi-xwidget-key)
        (should-not scripts)
        (should forwarded)))))

(ert-deftest enghi-test-xwidget-gtd-top ()
  "Ensure the GTD top page opens lists and captures from Emacs."
  (let ((enghi-server-url "http://127.0.0.1:7777/")
        opened captured)
    (cl-letf (((symbol-function 'xwidget-webkit-goto-uri)
               (lambda (_session uri) (push uri opened)))
              ((symbol-function 'enghi-capture)
               (lambda (title) (interactive (list "Buy milk")) (setq captured title))))
      (enghi-tests--with-xwidget-stubs "/gtd"
        (dolist (key '(?i ?n ?w ?s ?m ?p))
          (let ((last-command-event key)) (enghi-xwidget-key)))
        (should (equal (reverse opened)
                       (mapcar (lambda (p) (concat "http://127.0.0.1:7777" p))
                               '("/gtd/inbox" "/gtd/next" "/gtd/waiting"
                                 "/gtd/scheduled" "/gtd/someday" "/gtd/projects"))))
        (let ((last-command-event ?c)) (enghi-xwidget-key))
        (should (equal captured "Buy milk"))
        ;; The page's own keys do nothing here
        (dolist (key '(?j ?k 13 ?d ?/))
          (let ((last-command-event key)) (enghi-xwidget-key)))
        (should-not scripts)
        (should (= (length opened) 6))))))
