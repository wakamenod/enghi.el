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

  (ert-deftest enghi-test-consult-min-input-passed ()
    "Pass our minimum to consult, whose own default (3) would hide 2-char queries."
    (let (args (enghi-consult-min-input 1))
      (cl-letf (((symbol-function 'consult--dynamic-collection)
                 (lambda (&rest a) (setq args a) #'ignore))
                ((symbol-function 'consult--read) (lambda (&rest _) nil)))
        (enghi-consult-read-result)
        (should (equal (plist-get (cdr args) :min-input) 1)))))

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

(defvar enghi-tests--row nil
  "JSON the stubbed page returns for its selected row (nil for none).")

(defmacro enghi-tests--with-xwidget-stubs (path &rest body)
  "Run BODY with webkit stubbed out, showing enghi PATH.
Bind `scripts' to the JS sent without a callback, `forwarded' to whether it
went forward and `opened' to the URIs gone to. Scripts with a callback get
`enghi-tests--row'. Timers with no delay run at once; the others are left
out."
  (declare (indent 1))
  `(let (scripts forwarded opened)
     (cl-letf (((symbol-function 'xwidget-webkit-current-session) (lambda () 'session))
               ((symbol-function 'xwidget-webkit-execute-script)
                (lambda (session script &optional cb)
                  (should (eq session 'session))
                  (if cb (funcall cb enghi-tests--row) (push script scripts))))
               ((symbol-function 'xwidget-webkit-forward) (lambda () (setq forwarded t)))
               ((symbol-function 'xwidget-webkit-goto-uri)
                (lambda (_session uri) (push uri opened)))
               ((symbol-function 'run-at-time)
                (lambda (time _repeat fn &rest args)
                  (when (equal time 0) (apply fn args))
                  nil))
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
        captured reloaded)
    (cl-letf (((symbol-function 'enghi-capture)
               (lambda (title) (interactive (list "Buy milk")) (setq captured title)))
              ((symbol-function 'xwidget-webkit-reload) (lambda () (setq reloaded t))))
      (enghi-tests--with-xwidget-stubs "/gtd"
        (dolist (key '(?i ?n ?w ?s ?m ?p))
          (let ((last-command-event key)) (enghi-xwidget-key)))
        (should (equal (reverse opened)
                       (mapcar (lambda (p) (concat "http://127.0.0.1:7777" p))
                               '("/gtd/inbox" "/gtd/next" "/gtd/waiting"
                                 "/gtd/scheduled" "/gtd/someday" "/gtd/projects"))))
        (let ((last-command-event ?c)) (enghi-xwidget-key))
        (should (equal captured "Buy milk"))
        (should reloaded)
        ;; The page's own keys do nothing here
        (dolist (key '(?j ?k 13 ?d))
          (let ((last-command-event key)) (enghi-xwidget-key)))
        (should-not scripts)
        (should (= (length opened) 6))))))

(ert-deftest enghi-test-xwidget-dashboard-g ()
  "`g' opens the GTD top page from the dashboard and browses elsewhere."
  (should (eq (lookup-key enghi-xwidget-mode-map "g") #'enghi-xwidget-key))
  (let ((enghi-server-url "http://127.0.0.1:7777/"))
    (enghi-tests--with-xwidget-stubs "/"
      (let ((last-command-event ?g)) (enghi-xwidget-key))
      (should (equal opened '("http://127.0.0.1:7777/gtd")))
      (should-not scripts))
    (dolist (path '("/gtd" "/gtd/inbox" "/wiki/foo" nil))
      (let (browsed)
        (cl-letf (((symbol-function 'xwidget-webkit-browse-url)
                   (lambda (url &optional _new) (interactive (list "https://example.com"))
                     (setq browsed url))))
          (enghi-tests--with-xwidget-stubs path
            (let ((last-command-event ?g)) (enghi-xwidget-key))
            (should (equal browsed "https://example.com"))
            (should-not opened)
            (should-not scripts)))))))

(ert-deftest enghi-test-xwidget-dashboard-header ()
  "The dashboard header shows `g GTD'; other screens do not."
  (enghi-tests--with-xwidget-stubs "/"
    (should (string-match-p "g GTD" (substring-no-properties (enghi--xwidget-header)))))
  (enghi-tests--with-xwidget-stubs "/wiki/foo"
    (should-not (string-match-p "GTD" (substring-no-properties (enghi--xwidget-header))))))

;;;; Acting on the selected task from Emacs

(defun enghi-tests--row (&rest fields)
  "Return row JSON for a task with FIELDS (a plist) over some defaults."
  (let ((row (list :id "42" :state "inbox" :title "Write report"
                   :project_id "" :project_title "" :context_id ""
                   :waiting_for "" :scheduled_on "" :recurrence ""
                   :recurrence_ends_on "" :url "" :index 2 :contexts :json-false)))
    (while fields
      (setq row (plist-put row (pop fields) (pop fields))))
    (json-encode row)))

(defmacro enghi-tests--with-task-action (row &rest body)
  "Run BODY on the GTD Inbox with ROW selected and requests stubbed.
Bind `requests' to the requests made, as (METHOD PATH PAYLOAD), oldest
first. GETs answer with a few projects, contexts and tags."
  (declare (indent 1))
  `(let ((enghi-tests--row ,row)
         (requests nil))
     (cl-letf (((symbol-function 'enghi-request)
                (lambda (method path &optional payload _params)
                  (setq requests (append requests (list (list method path payload))))
                  (pcase path
                    ("/api/projects"
                     (if (equal method "POST")
                         `((id . 9) (title . ,(alist-get 'title payload)))
                       '((projects ((id . 7) (title . "Garden"))
                                   ((id . 8) (title . "House"))))))
                    ("/api/contexts" '((contexts ((id . 3) (name . "@home"))
                                                 ((id . 4) (name . "@old") (archived . t)))))
                    ("/api/tags" '((tags ((name . "notes") (count . 1)))))
                    ((pred (string-suffix-p "/file"))
                     '((page (slug . "write-report") (title . "Write report"))))
                    (_ nil)))))
       (enghi-tests--with-xwidget-stubs "/gtd/inbox"
         ,@body))))

(defun enghi-tests--press (key)
  "Press KEY (a character) in the stubbed view."
  (let ((last-command-event key)) (enghi-xwidget-key)))

(defun enghi-tests--writes (requests)
  "Return the non-GET requests in REQUESTS."
  (seq-remove (lambda (r) (equal (car r) "GET")) requests))

(ert-deftest enghi-test-task-next ()
  "`n' asks for a project and moves the task to Next."
  (enghi-tests--with-task-action (enghi-tests--row)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt cands &rest _)
                 (should (string-prefix-p "Project" prompt))
                 (should (assoc "(none)" cands))
                 "House")))
      (enghi-tests--press ?n))
    (should (equal (enghi-tests--writes requests)
                   '(("PATCH" "/api/tasks/42" ((state . "next") (project_id . 8))))))
    ;; The list reloads, then row 2 is selected again
    (should (string-match-p "location.reload" (car scripts)))
    (should (string-match-p "Math.min(2," (enghi--xwidget-select-row-script 2)))))

(ert-deftest enghi-test-task-next-none-and-context ()
  "`n' with \"(none)\" clears the project, and asks for a context if on."
  (enghi-tests--with-task-action
      (enghi-tests--row :project_id "7" :project_title "Garden" :contexts t)
    (let (defaults)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt cands _pred _req _init _hist default)
                   (push default defaults)
                   (if (string-prefix-p "Project" prompt)
                       "(none)"
                     (should-not (assoc "@old" cands))
                     "@home"))))
        (enghi-tests--press ?n))
      ;; The current project is offered first
      (should (equal (reverse defaults) '("Garden" "(none)"))))
    (should (equal (enghi-tests--writes requests)
                   '(("PATCH" "/api/tasks/42"
                      ((state . "next") (clear_project . t) (context_id . 3))))))))

(ert-deftest enghi-test-task-next-new-project ()
  "A project name not in the list creates the project, after confirming."
  (enghi-tests--with-task-action (enghi-tests--row)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _cands _pred require-match &rest _)
                 ;; Any name may be typed
                 (should-not require-match)
                 " Move house "))
              ((symbol-function 'y-or-n-p)
               (lambda (prompt) (should (equal prompt "Create project \"Move house\"? ")) t))
              ((symbol-function 'read-string) (lambda (&rest _) "Living in the new place ")))
      (enghi-tests--press ?n))
    (should (equal (enghi-tests--writes requests)
                   '(("POST" "/api/projects"
                      ((title . "Move house") (outcome . "Living in the new place")))
                     ("PATCH" "/api/tasks/42" ((state . "next") (project_id . 9)))))))
  ;; Declined: nothing is created or moved
  (enghi-tests--with-task-action (enghi-tests--row)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Move house"))
              ((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (enghi-tests--press ?l))
    (should-not (enghi-tests--writes requests))
    (should-not scripts)))

(ert-deftest enghi-test-task-later ()
  "`l' needs a project."
  (enghi-tests--with-task-action (enghi-tests--row)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt cands &rest _)
                 (should-not (assoc "(none)" cands))
                 "Garden")))
      (enghi-tests--press ?l))
    (should (equal (enghi-tests--writes requests)
                   '(("PATCH" "/api/tasks/42" ((state . "later") (project_id . 7))))))))

(ert-deftest enghi-test-task-waiting ()
  "`w' asks who, and refuses an empty answer."
  (enghi-tests--with-task-action (enghi-tests--row :waiting_for "Bob")
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt initial &rest _)
                 (should (equal initial "Bob"))
                 " Alice ")))
      (enghi-tests--press ?w))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (enghi-tests--press ?w))
    (should (equal (enghi-tests--writes requests)
                   '(("PATCH" "/api/tasks/42" ((state . "waiting") (waiting_for . "Alice"))))))))

(ert-deftest enghi-test-task-schedule ()
  "`s' asks for a date, a repeat rule and an end."
  ;; Loading org later would put the real `org-read-date' back over the stub
  (require 'org)
  (enghi-tests--with-task-action (enghi-tests--row :scheduled_on "2026-09-01")
    (let ((dates '("2026-09-25" "2026-12-31")) presets)
      (cl-letf (((symbol-function 'org-read-date)
                 (lambda (&rest _) (pop dates)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt cands &rest _)
                   (setq presets (mapcar #'car cands))
                   "weekly:fri"))
                ((symbol-function 'y-or-n-p) (lambda (_) t)))
        (enghi-tests--press ?s))
      (should (member "Does not repeat" presets))
      (should (member "monthly:25" presets))
      (should (member "yearly:09-25" presets)))
    ;; No repeat: no end asked, and both are cleared
    (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _) "2026-10-01"))
              ((symbol-function 'completing-read) (lambda (&rest _) "Does not repeat"))
              ((symbol-function 'y-or-n-p) (lambda (_) (error "Should not ask"))))
      (enghi-tests--press ?s))
    (should (equal (enghi-tests--writes requests)
                   '(("PATCH" "/api/tasks/42"
                      ((state . "scheduled") (scheduled_on . "2026-09-25")
                       (recurrence . "weekly:fri") (recurrence_ends_on . "2026-12-31")))
                     ("PATCH" "/api/tasks/42"
                      ((state . "scheduled") (scheduled_on . "2026-10-01")
                       (recurrence . "") (recurrence_ends_on . ""))))))))

(ert-deftest enghi-test-task-drop ()
  "`x' drops only after confirming."
  (enghi-tests--with-task-action (enghi-tests--row)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (enghi-tests--press ?x))
    (should-not requests)
    (should-not scripts)
    ;; In the minibuffer, not a dialog box: the last input is an xwidget event
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (not use-dialog-box))))
      (let ((use-dialog-box t))
        (enghi-tests--press ?x)))
    (should (equal requests '(("PATCH" "/api/tasks/42" ((state . "dropped"))))))))

(ert-deftest enghi-test-task-file ()
  "`f' files the task as a page and opens the page."
  (enghi-tests--with-task-action (enghi-tests--row)
    (let (opened-slug)
      (cl-letf (((symbol-function 'read-string) (lambda (_p initial &rest _) initial))
                ((symbol-function 'completing-read-multiple)
                 (lambda (_prompt cands &rest _)
                   (should (member "notes" cands))
                   '("notes" "new")))
                ((symbol-function 'enghi-open) (lambda (slug) (setq opened-slug slug))))
        (enghi-tests--press ?f))
      (should (equal opened-slug "write-report")))
    (should (equal (enghi-tests--writes requests)
                   '(("POST" "/api/tasks/42/file"
                      ((title . "Write report") (body . "") (tags . ["notes" "new"]))))))))

(ert-deftest enghi-test-task-rename-someday-done ()
  "`t' renames, `m' moves to Someday and `d' completes."
  (enghi-tests--with-task-action (enghi-tests--row)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Write the report")))
      (enghi-tests--press ?t))
    (enghi-tests--press ?m)
    (enghi-tests--press ?d)
    (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r))) requests)
                   '(("PATCH" "/api/tasks/42") ("PATCH" "/api/tasks/42")
                     ("POST" "/api/tasks/42/complete"))))
    (should (equal (nth 2 (nth 0 requests)) '((title . "Write the report"))))
    (should (equal (nth 2 (nth 1 requests)) '((state . "someday"))))
    ;; `{}', not `null'
    (should (equal (json-encode (nth 2 (nth 2 requests))) "{}"))))

(ert-deftest enghi-test-task-skip ()
  "`S' skips only a recurring task."
  (enghi-tests--with-task-action (enghi-tests--row)
    (enghi-tests--press ?S)
    (should-not requests))
  (enghi-tests--with-task-action (enghi-tests--row :recurrence "+1w")
    (enghi-tests--press ?S)
    (should (equal requests '(("POST" "/api/tasks/42/complete" ((skip . t))))))))

(ert-deftest enghi-test-task-details ()
  "RET opens the task's detail page without reloading."
  (let ((enghi-server-url "http://127.0.0.1:7777"))
    (enghi-tests--with-task-action (enghi-tests--row)
      (enghi-tests--press 13)
      (should (equal opened '("http://127.0.0.1:7777/gtd/clarify/42")))
      (should-not scripts))))

(ert-deftest enghi-test-task-open-url ()
  "`o' opens the task's URL in the browser without reloading, even when done."
  (should (eq (lookup-key enghi-xwidget-mode-map "o") #'enghi-xwidget-key))
  (dolist (state '("next" "done"))
    (let (browsed)
      (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url browsed))))
        (enghi-tests--with-task-action
            (enghi-tests--row :state state :url "https://example.com/a?b=1")
          (enghi-tests--press ?o)
          (should (equal browsed '("https://example.com/a?b=1")))
          (should-not requests)
          (should-not opened)
          (should-not scripts))))))

(ert-deftest enghi-test-task-open-url-none ()
  "`o' opens nothing when the task has no URL or a non-http(s) one."
  (dolist (url '("" "javascript:alert(1)"))
    (let (browsed)
      (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url browsed))))
        (enghi-tests--with-task-action (enghi-tests--row :url url)
          (enghi-tests--press ?o)
          (should-not browsed)
          (should-not requests)
          (should-not scripts))))))

(ert-deftest enghi-test-task-cancel ()
  "C-g in a prompt makes no request."
  (enghi-tests--with-task-action (enghi-tests--row)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
      (enghi-tests--press ?n))
    (should-not (enghi-tests--writes requests))
    (should-not scripts)))

(ert-deftest enghi-test-task-no-selection ()
  "Without a selected task row, the key goes to the page."
  (enghi-tests--with-task-action nil
    (dolist (key '(?n 13 ?f))
      (enghi-tests--press key))
    (should-not requests)
    (should-not opened)
    (should (equal (length scripts) 3))
    (should (string-match-p "key: \"n\"" (nth 2 scripts)))
    (should (string-match-p "key: \"Enter\"" (nth 1 scripts)))
    (should (string-match-p "key: \"f\"" (nth 0 scripts))))
  ;; j/k are still the page's
  (enghi-tests--with-task-action (enghi-tests--row)
    (dolist (key '(?j ?k))
      (enghi-tests--press key))
    (should-not requests)
    (should (equal (length scripts) 2))))

(ert-deftest enghi-test-task-next-live ()
  "`n' moves a captured task to Next in a project on the server."
  (let* ((task (enghi-capture (enghi-tests--unique "Task to move")))
         (project (enghi-request "POST" "/api/projects"
                                 `((title . ,(enghi-tests--unique "Move project")))))
         (enghi-tests--row
          (enghi-tests--row :id (number-to-string (alist-get 'id task))
                            :title (alist-get 'title task))))
    (enghi-tests--with-xwidget-stubs "/gtd/inbox"
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt cands &rest _)
                   (should (assoc (alist-get 'title project) cands))
                   (alist-get 'title project))))
        (enghi-tests--press ?n)))
    (let ((after (alist-get 'task (enghi-request "GET" (format "/api/tasks/%d" (alist-get 'id task))))))
      (should (equal (alist-get 'state after) "next"))
      (should (equal (alist-get 'project_id after) (alist-get 'id project))))))

(ert-deftest enghi-test-task-start-now ()
  "`.' moves a task to Next, asking for its project, then starts it."
  (should (eq (lookup-key enghi-xwidget-mode-map ".") #'enghi-xwidget-key))
  (enghi-tests--with-task-action (enghi-tests--row)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "House")))
      (enghi-tests--press ?.))
    (should (equal (enghi-tests--writes requests)
                   '(("PATCH" "/api/tasks/42" ((state . "next") (project_id . 8)))
                     ("POST" "/api/tasks/42/logs" ((kind . "start") (body . ""))))))
    (should (string-match-p "location.reload" (car scripts))))
  ;; Already in Next: no question and no move
  (enghi-tests--with-task-action (enghi-tests--row :state "next")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "Should not ask"))))
      (enghi-tests--press ?.))
    (should (equal (enghi-tests--writes requests)
                   '(("POST" "/api/tasks/42/logs" ((kind . "start") (body . "")))))))
  ;; A scheduled task whose date has come is a next action already: it keeps
  ;; its date. One in the future moves to Next.
  (dolist (case `((,(format-time-string "%F") . nil) ("2000-01-01" . nil) ("2999-01-01" . t)))
    (enghi-tests--with-task-action
        (enghi-tests--row :state "scheduled" :scheduled_on (car case))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "House")))
        (enghi-tests--press ?.))
      (should (equal (and (assoc "PATCH" (enghi-tests--writes requests)) t) (cdr case))))))

(ert-deftest enghi-test-xwidget-callbacks-held ()
  "Script callbacks are held until WebKit calls them (macOS does not)."
  (let ((enghi--xwidget-callbacks nil) pending got)
    (cl-letf (((symbol-function 'xwidget-webkit-execute-script)
               (lambda (_session _script cb) (push cb pending))))
      (enghi--xwidget-execute-script 'session "1" (lambda (v) (push v got)))
      (should (= (length enghi--xwidget-callbacks) 1))
      (funcall (car pending) "answer")
      (should (equal got '("answer")))
      (should-not enghi--xwidget-callbacks)
      ;; Unanswered ones do not pile up
      (dotimes (_ 40) (enghi--xwidget-execute-script 'session "1" #'ignore))
      (should (= (length enghi--xwidget-callbacks) 16)))))

;;;; Capture and search from any enghi screen

(ert-deftest enghi-test-xwidget-capture-everywhere ()
  "`c' captures from Emacs on every enghi screen, reloading GTD screens."
  (dolist (case '(("/gtd/inbox" . t) ("/gtd/project/3" . t) ("/wiki/foo" . nil) ("/" . nil)))
    (let (captured reloaded)
      (cl-letf (((symbol-function 'enghi-capture)
                 (lambda (title) (interactive (list "Buy milk")) (setq captured title)))
                ((symbol-function 'xwidget-webkit-reload) (lambda () (setq reloaded t))))
        (enghi-tests--with-xwidget-stubs (car case)
          (enghi-tests--press ?c)
          (should (equal captured "Buy milk"))
          (should (eq reloaded (cdr case)))
          (should-not scripts)))))
  ;; Another site's page keeps its own key
  (let (captured)
    (cl-letf (((symbol-function 'enghi-capture) (lambda (&rest _) (interactive) (setq captured t))))
      (enghi-tests--with-xwidget-stubs nil
        (enghi-tests--press ?c)
        (should-not captured)
        (should (string-match-p "key: \"c\"" (car scripts)))))))

(ert-deftest enghi-test-xwidget-search-everywhere ()
  "`/' searches from Emacs and shows the chosen result in this view."
  (let ((enghi-server-url "http://127.0.0.1:7777"))
    (dolist (path '("/gtd" "/gtd/inbox" "/wiki/foo" "/"))
      (cl-letf (((symbol-function 'enghi-read-search-result)
                 (lambda (&rest _) '((kind . "page") (slug . "design-notes")))))
        (enghi-tests--with-xwidget-stubs path
          (enghi-tests--press ?/)
          (should (equal opened '("http://127.0.0.1:7777/wiki/design-notes")))
          (should-not scripts))))
    ;; Nothing chosen: nothing happens
    (cl-letf (((symbol-function 'enghi-read-search-result) (lambda (&rest _) nil)))
      (enghi-tests--with-xwidget-stubs "/wiki/foo"
        (enghi-tests--press ?/)
        (should-not opened)
        (should-not scripts)))))

(ert-deftest enghi-test-result-path ()
  "Each kind of search result maps to the screen that shows it."
  (should (equal (enghi--result-path '((kind . "page") (slug . "a-b"))) "/wiki/a-b"))
  (should (equal (enghi--result-path '((kind . "project") (id . 3))) "/gtd/project/3"))
  (should (equal (enghi--result-path '((kind . "task") (id . 4))) "/gtd/clarify/4"))
  (should (equal (enghi--result-path '((kind . "area") (id . 5))) "/gtd/area/5"))
  (should-not (enghi--result-path '((kind . "other")))))

;;;; The dashboard.el section

(require 'enghi-dashboard)

(defun enghi-tests--date (days)
  "Return the local date DAYS from today, as YYYY-MM-DD."
  (format-time-string "%F" (time-add nil (* days 86400))))

(defconst enghi-tests--dashboard
  `((gtd (inbox_count . 3)
         (today ((id . 1) (title . "Due today") (deadline_on . ,(enghi-tests--date 0))
                 (deadline_days . 0))
                ((id . 2) (title . "Scheduled") (project_title . "House"))
                ((id . 3) (title . "Late") (deadline_on . ,(enghi-tests--date -2))
                 (deadline_days . -2)))
         (upcoming ((id . 4) (title . "Soon") (deadline_on . ,(enghi-tests--date 1))
                    (deadline_days . 1))
                   ((id . 5) (title . "Later on") (deadline_on . ,(enghi-tests--date 6))
                    (deadline_days . 6)))))
  "What /api/dashboard returns, cut down to what the section reads.")

(defmacro enghi-tests--with-dashboard (response &rest body)
  "Run BODY in a buffer holding the section rendered from RESPONSE.
RESPONSE is a form evaluated in place of the request; it may signal. Bind
`timeout' to `enghi-request-timeout' during the request, and `browsed' and
`refreshed' to what selecting a line did. dashboard.el's heading is stubbed,
so this runs without it."
  (declare (indent 1))
  `(let (timeout browsed refreshed)
     (cl-letf (((symbol-function 'enghi-request)
                (lambda (method path &rest _)
                  (should (equal (list method path) '("GET" "/api/dashboard")))
                  (setq timeout enghi-request-timeout)
                  ,response))
               ((symbol-function 'enghi-browse) (lambda (path) (setq browsed path)))
               ((symbol-function 'dashboard-refresh-buffer) (lambda () (setq refreshed t)))
               ((symbol-function 'dashboard-heading-icon) (lambda (_) ""))
               ((symbol-function 'dashboard-insert-heading)
                (lambda (heading &rest _) (insert heading))))
       (with-temp-buffer
         (enghi-dashboard-insert 5)
         ,@body))))

(defun enghi-tests--lines ()
  "Return the lines of the current buffer."
  (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n"))

(defun enghi-tests--select (text)
  "Select the line containing TEXT."
  (goto-char (point-min))
  (search-forward text)
  (widget-apply (widget-at (1- (point))) :action))

(ert-deftest enghi-test-dashboard-section ()
  "Inbox, then overdue first within Today, then upcoming, from one request."
  (enghi-tests--with-dashboard enghi-tests--dashboard
    (should (equal (enghi-tests--lines)
                   '("enghi:"
                     "    Inbox 3"
                     "    2 d. ago:   Late"
                     "    Today:      Due today"
                     "    Today:      Scheduled  (House)"
                     "    In 1 d.:    Soon"
                     "    In 6 d.:    Later on"
                     "    Open the dashboard")))
    (should (= timeout enghi-dashboard-timeout))
    ;; Inbox is emphasized when not zero, and overdue stands out
    (goto-char (point-min))
    (search-forward "Inbox 3")
    (should (eq (get-text-property (1- (point)) 'face) 'enghi-dashboard-inbox))
    (search-forward "2 d. ago")
    (should (eq (get-text-property (1- (point)) 'face) 'enghi-dashboard-overdue))
    ;; Selecting opens the matching screen
    (enghi-tests--select "Late")
    (should (equal browsed "/gtd/clarify/3"))
    (enghi-tests--select "Inbox")
    (should (equal browsed "/gtd/inbox"))
    (enghi-tests--select "Open the dashboard")
    (should (equal browsed "/"))
    (should-not refreshed)))

(ert-deftest enghi-test-dashboard-section-server-down ()
  "A server that does not answer is one line, and selecting it retries."
  (let ((enghi-server-url "http://127.0.0.1:7777"))
    (enghi-tests--with-dashboard (signal 'enghi-error '("Cannot connect"))
      (should (equal (enghi-tests--lines)
                     '("enghi:" "    enghi is not running (http://127.0.0.1:7777)")))
      (enghi-tests--select "not running")
      (should refreshed)
      (should-not browsed)))
  ;; For real, with nothing stubbed but dashboard.el: no error
  (let ((enghi-server-url "http://127.0.0.1:1"))
    (cl-letf (((symbol-function 'dashboard-heading-icon) (lambda (_) ""))
              ((symbol-function 'dashboard-insert-heading)
               (lambda (heading &rest _) (insert heading))))
      (with-temp-buffer
        (enghi-dashboard-insert 5)
        (should (string-match-p "enghi is not running" (buffer-string)))))))

(ert-deftest enghi-test-dashboard-section-old-server ()
  "A server without `upcoming' or `deadline_days' still works.
The upcoming group is left out, and overdue comes from `deadline_on'."
  (enghi-tests--with-dashboard
      `((gtd (inbox_count . 0)
             (today ((id . 1) (title . "Now"))
                    ((id . 2) (title . "Late") (deadline_on . ,(enghi-tests--date -3))))))
    (should (equal (enghi-tests--lines)
                   '("enghi:" "    Inbox 0" "    3 d. ago:   Late" "    Today:      Now"
                     "    Open the dashboard")))))

(ert-deftest enghi-test-dashboard-section-limits ()
  "Each group shows at most the list size, then how many more."
  (enghi-tests--with-dashboard
      `((gtd (inbox_count . 0)
             (today ,@(mapcar (lambda (i) `((id . ,i) (title . ,(format "Task %d" i))))
                              (number-sequence 1 7)))
             (upcoming)))
    (should (equal (seq-filter (lambda (l) (string-match-p "Task\\|more" l))
                               (enghi-tests--lines))
                   '("    Today:      Task 1" "    Today:      Task 2" "    Today:      Task 3"
                     "    Today:      Task 4" "    Today:      Task 5"
                     "                … 2 more")))
    (enghi-tests--select "more")
    (should (equal browsed "/")))
  (enghi-tests--with-dashboard '((gtd (inbox_count . 0) (today) (upcoming)))
    (should (member "    Nothing due" (enghi-tests--lines)))))

(defun enghi-tests--at (hour minute &optional days)
  "Return HOUR:MINUTE local time, DAYS from today, as a Lisp time."
  (let ((now (decode-time)))
    (encode-time (list 0 minute hour (+ (decoded-time-day now) (or days 0))
                       (decoded-time-month now) (decoded-time-year now) nil -1 nil))))

(defun enghi-tests--rfc3339 (hour minute &optional days)
  "Return HOUR:MINUTE local time, DAYS from today, as the server sends it."
  (format-time-string "%FT%T%:z" (enghi-tests--at hour minute days)))

(defmacro enghi-tests--at-noon (&rest body)
  "Run BODY with the clock stopped at noon today."
  (declare (indent 0))
  `(let ((noon (enghi-tests--at 12 0)))
     (cl-letf (((symbol-function 'current-time) (lambda () noon)))
       ,@body)))

(defun enghi-tests--event (id title start end &rest fields)
  "Return an event of today, START and END as (HOUR MINUTE), with FIELDS."
  `((id . ,id) (source . "test") (calendar . "Work") (title . ,title)
    (start . ,(apply #'enghi-tests--rfc3339 start))
    (end . ,(apply #'enghi-tests--rfc3339 end))
    (all_day . nil)
    ,@fields))

(defun enghi-tests--face-at (text)
  "Return the face of the first character of TEXT in the buffer."
  (goto-char (point-min))
  (search-forward text)
  (get-text-property (match-beginning 0) 'face))

(ert-deftest enghi-test-dashboard-section-day ()
  "Today's events, then the tasks being worked on, before what is due."
  (enghi-tests--at-noon
    (enghi-tests--with-dashboard
        `((events ,(enghi-tests--event 1 "Plan" '(15 0) '(16 0) '(task_id . 9))
                  ,(enghi-tests--event 2 "Standup" '(9 0) '(10 0))
                  ((id . 3) (calendar . "Home") (title . "Holiday")
                   (start . ,(enghi-tests--rfc3339 0 0)) (end . ,(enghi-tests--rfc3339 0 0 1))
                   (all_day . t))
                  ,(enghi-tests--event 4 "Review" '(11 30) '(12 30) '(location . "Room A")))
          (gtd (working ((id . 7) (title . "Write report") (project_title . "Docs")
                         (since . ,(enghi-tests--rfc3339 10 42)))
                        ((id . 8) (title . "Old thing") (since . ,(enghi-tests--rfc3339 9 0 -1)))
                        ((id . 6) (title . "No start")))
               ,@(alist-get 'gtd enghi-tests--dashboard)))
      (should (equal (enghi-tests--lines)
                     `("enghi:"
                       "    Inbox 3"
                       "    All day     Holiday  (Home)"
                       "    09:00–10:00 Standup  (Work)"
                       "    11:30–12:30 Review  (Work)  @Room A"
                       "    15:00–16:00 Plan  (Work)"
                       "    Working:    Write report  (Docs)  since 10:42 (1h 18m)"
                       ,(format "    Working:    Old thing  since %s 09:00 (1d 3h)"
                                (format-time-string "%-m/%-d" (enghi-tests--at 9 0 -1)))
                       "    Working:    No start"
                       "    2 d. ago:   Late"
                       "    Today:      Due today"
                       "    Today:      Scheduled  (House)"
                       "    In 1 d.:    Soon"
                       "    In 6 d.:    Later on"
                       "    Open the dashboard"
                       "    Open the day page")))
      ;; Ended dimmed, in progress marked, the rest as usual
      (should (eq (enghi-tests--face-at "Standup") 'enghi-dashboard-past-event))
      (should (eq (enghi-tests--face-at "11:30") 'enghi-dashboard-now))
      (should (eq (enghi-tests--face-at "15:00") 'enghi-dashboard-label))
      (should (eq (enghi-tests--face-at "Working:") 'enghi-dashboard-now))
      (should (eq (enghi-tests--face-at "since 10:42") 'enghi-dashboard-label))
      ;; Work started on an earlier day stands out
      (should (eq (enghi-tests--face-at "since 9") 'enghi-dashboard-stale-work))
      ;; An event opens its task, or else the day page
      (enghi-tests--select "Plan")
      (should (equal browsed "/gtd/clarify/9"))
      (enghi-tests--select "Review")
      (should (equal browsed "/gtd/day"))
      (enghi-tests--select "Write report")
      (should (equal browsed "/gtd/clarify/7"))
      (enghi-tests--select "day page")
      (should (equal browsed "/gtd/day")))))

(ert-deftest enghi-test-dashboard-section-day-empty ()
  "Empty `events' and `working' add no lines, only the day page link."
  (enghi-tests--with-dashboard '((events) (gtd (inbox_count . 0) (working) (today) (upcoming)))
    (should (equal (enghi-tests--lines)
                   '("enghi:" "    Inbox 0" "    Nothing due" "    Open the dashboard"
                     "    Open the day page")))))

(ert-deftest enghi-test-dashboard-section-time-zone ()
  "Event times are shown in local time whatever offset they carry."
  (let ((tz (getenv "TZ")))
    (unwind-protect
        (progn
          (setenv "TZ" "UTC0")
          (cl-letf (((symbol-function 'current-time)
                     (lambda () (parse-iso8601-time-string "2026-09-26T05:00:00Z"))))
            (enghi-tests--with-dashboard
                '((events ((title . "Tokyo") (all_day . nil)
                           (start . "2026-09-26T15:00:00+09:00")
                           (end . "2026-09-26T16:00:00+09:00")))
                  (gtd (inbox_count . 0) (working ((id . 1) (title . "Work")
                                                   (since . "2026-09-26T13:30:00+09:00")))))
              (should (member "    06:00–07:00 Tokyo" (enghi-tests--lines)))
              (should (member "    Working:    Work  since 04:30 (30m)" (enghi-tests--lines))))))
      (setenv "TZ" tz))))

(ert-deftest enghi-test-dashboard-section-day-limits ()
  "Events and working tasks show at most the list size, then how many more."
  (enghi-tests--at-noon
    (enghi-tests--with-dashboard
        `((events ,@(mapcar (lambda (i) (enghi-tests--event i (format "Event %d" i)
                                                            (list (+ 12 i) 0) (list (+ 13 i) 0)))
                            (number-sequence 1 7)))
          (gtd (inbox_count . 0)
               (working ,@(mapcar (lambda (i) `((id . ,i) (title . ,(format "Task %d" i))))
                                  (number-sequence 1 6)))))
      (should (equal (seq-filter (lambda (l) (string-match-p "Event\\|Task\\|more" l))
                                 (enghi-tests--lines))
                     '("    13:00–14:00 Event 1  (Work)" "    14:00–15:00 Event 2  (Work)"
                       "    15:00–16:00 Event 3  (Work)" "    16:00–17:00 Event 4  (Work)"
                       "    17:00–18:00 Event 5  (Work)"
                       "                … 2 more"
                       "    Working:    Task 1" "    Working:    Task 2" "    Working:    Task 3"
                       "    Working:    Task 4" "    Working:    Task 5"
                       "                … 1 more")))
      ;; More events are on the day page
      (enghi-tests--select "… 2 more")
      (should (equal browsed "/gtd/day")))))

(ert-deftest enghi-test-day ()
  "`enghi-day' opens today's day page, or with a prefix a chosen day's."
  ;; Loading org later would put the real `org-read-date' back over the stub
  (require 'org)
  (let (browsed)
    (cl-letf (((symbol-function 'enghi-browse) (lambda (path) (setq browsed path)))
              ((symbol-function 'org-read-date) (lambda (&rest _) "2026-10-01")))
      (call-interactively #'enghi-day)
      (should (equal browsed "/gtd/day"))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'enghi-day))
      (should (equal browsed "/gtd/day/2026-10-01"))))
  (should (eq (keymap-lookup enghi-command-map "D") #'enghi-day))
  ;; Without org: a date typed in, today by default
  (cl-letf (((symbol-function 'read-string) (lambda (_prompt _initial _hist default) default)))
    (should (equal (enghi--read-day-string) (format-time-string "%F"))))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) " 2026-09-25 ")))
    (should (equal (enghi--read-day-string) "2026-09-25")))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "tomorrow")))
    (should-error (enghi--read-day-string) :type 'user-error)))

(defmacro enghi-tests--with-gtd-list-read (choice &rest body)
  "Run `enghi-gtd-list' choosing CHOICE, then BODY.
BODY sees `browsed', the path opened, `cands', the candidates in display
order, and `annotate', the annotation function."
  (declare (indent 1))
  `(let (browsed cands annotate)
     (cl-letf (((symbol-function 'enghi-browse) (lambda (path) (setq browsed path)))
               ((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  (let ((sort (completion-metadata-get
                               (completion-metadata "" table nil)
                               'display-sort-function)))
                    (setq cands (funcall sort (all-completions "" table))))
                  (setq annotate (plist-get completion-extra-properties
                                            :annotation-function))
                  ,choice)))
       (call-interactively #'enghi-gtd-list))
     ,@body))

(ert-deftest enghi-test-gtd-list ()
  "`enghi-gtd-list' offers the GTD lists in order, with their counts."
  (enghi-request "POST" "/api/tasks" `((title . ,(enghi-tests--unique "Listed"))))
  (let ((inbox (alist-get 'inbox (enghi-request "GET" "/api/lists"))))
    (should (> inbox 0))
    (enghi-tests--with-gtd-list-read "Inbox"
      (should (equal browsed "/gtd/inbox"))
      (should (equal cands '("Inbox" "Next Actions" "Waiting For" "Scheduled"
                             "Someday / Maybe" "Projects" "Work Record" "Weekly Review")))
      (should (string-suffix-p (format " %d" inbox) (funcall annotate "Inbox")))
      (should (string-suffix-p " today" (funcall annotate "Work Record")))
      (should-not (funcall annotate "Weekly Review"))
      ;; The notes end in the same column
      (should (= (length (delete-dups
                          (mapcar (lambda (c) (string-width (concat c (funcall annotate c))))
                                  (butlast cands))))
                 1))))
  (enghi-tests--with-gtd-list-read "Weekly Review"
    (should (equal browsed "/gtd/review")))
  (should (eq (keymap-lookup enghi-command-map "i") #'enghi-gtd-list)))

(ert-deftest enghi-test-gtd-list-without-counts ()
  "Servers without /api/lists still get the lists, with no counts."
  (cl-letf (((symbol-function 'enghi-request)
             (lambda (_method path &rest _)
               (should (equal path "/api/lists"))
               (signal 'enghi-http-error '(404 "not_found")))))
    (enghi-tests--with-gtd-list-read "Next Actions"
      (should (equal browsed "/gtd/next"))
      (should (= (length cands) 8))
      (should-not (funcall annotate "Inbox"))
      (should (string-suffix-p " today" (funcall annotate "Work Record")))))
  ;; A server that does not answer is still an error
  (cl-letf (((symbol-function 'enghi-request)
             (lambda (&rest _) (signal 'enghi-error '("Cannot connect")))))
    (should-error (enghi-tests--with-gtd-list-read "Inbox") :type 'enghi-error)))

(ert-deftest enghi-test-dashboard-section-registered ()
  "Loading dashboard.el registers the `enghi' generator."
  (skip-unless (require 'dashboard nil t))
  (should (eq (alist-get 'enghi dashboard-item-generators) #'enghi-dashboard-insert)))

(ert-deftest enghi-test-dashboard-section-live ()
  "The section renders from the running server."
  (cl-letf (((symbol-function 'dashboard-heading-icon) (lambda (_) ""))
            ((symbol-function 'dashboard-insert-heading)
             (lambda (heading &rest _) (insert heading))))
    (with-temp-buffer
      (enghi-dashboard-insert 5)
      (should (string-match-p "^    Inbox [0-9]+$" (buffer-string)))
      (should-not (string-match-p "not running" (buffer-string))))))

;;;; The work log

(require 'enghi-log)

(defconst enghi-tests--open-tasks
  '(("next" ((id . 1) (title . "Write report") (state . "next"))
            ((id . 2) (title . "Fix bug") (state . "next") (working . t)
             (project_title . "enghi")))
    ("inbox" ((id . 3) (title . "Call Bob") (state . "inbox")))
    ("someday" ((id . 4) (title . "Write report") (state . "someday"))))
  "Open tasks per state, as /api/tasks?state= returns them.")

(defmacro enghi-tests--with-log-server (handler &rest body)
  "Run BODY with `enghi-request' answered by HANDLER.
HANDLER is called with METHOD, PATH and PAYLOAD for anything but the task
lists, which come from `enghi-tests--open-tasks'. Bind `requests' to the
other requests, as (METHOD PATH PAYLOAD), oldest first, and `browsed' to the
path given to `enghi-browse'. No xwidget is shown."
  (declare (indent 1))
  `(let ((requests nil) (browsed nil))
     (cl-letf (((symbol-function 'enghi-request)
                (lambda (method path &optional payload params)
                  (if (equal path "/api/tasks")
                      `((tasks ,@(cdr (assoc (alist-get 'state params)
                                             enghi-tests--open-tasks))))
                    (setq requests (append requests (list (list method path payload))))
                    (funcall ,handler method path payload))))
               ((symbol-function 'enghi-browse) (lambda (path) (setq browsed path)))
               ((symbol-function 'enghi--xwidget-path) (lambda () nil)))
       ,@body)))

(defun enghi-tests--answer (&rest cands)
  "Return a `completing-read' stub choosing the first of CANDS offered.
It also records what was offered and the default in `enghi-tests--offered'."
  (lambda (_prompt collection &rest args)
    (let ((all (all-completions "" collection)))
      (setq enghi-tests--offered (list all (nth 4 args)))
      (or (seq-find (lambda (c) (member c all)) cands)
          (error "None of %S offered in %S" cands all)))))

(defvar enghi-tests--offered nil
  "What the last stubbed `completing-read' offered: (CANDIDATES DEFAULT).")

(ert-deftest enghi-test-log-result-path ()
  "A work log search result opens its task's Clarify page at the entry."
  (should (equal (enghi--result-path '((kind . "log") (id . 9) (task_id . 4)))
                 "/gtd/clarify/4#log-9"))
  ;; The fragment reaches the browser
  (let ((enghi-server-url "http://127.0.0.1:7777") captured)
    (cl-letf (((symbol-function 'enghi--ensure-server) #'ignore))
      (let ((enghi-browse-function (lambda (url) (setq captured url))))
        (enghi-visit-result '((kind . "log") (id . 9) (task_id . 4)))))
    (should (equal captured "http://127.0.0.1:7777/gtd/clarify/4#log-9")))
  (when (require 'enghi-consult nil t)
    (should (equal (enghi-consult--kind-label "log") "Log"))))

(ert-deftest enghi-test-log-picker-order ()
  "Working tasks come first and marked, then the others by state.
The only working task is the default, and same titles stay apart."
  (enghi-tests--with-log-server #'ignore
    (cl-letf (((symbol-function 'completing-read) (enghi-tests--answer "  Call Bob")))
      (should (equal (alist-get 'id (enghi-read-task "Task: ")) 3)))
    (should (equal (car enghi-tests--offered)
                   '("▶ Fix bug  (enghi)" "  Write report" "  Call Bob" "  Write report  #4")))
    (should (equal (cadr enghi-tests--offered) "▶ Fix bug  (enghi)"))))

(ert-deftest enghi-test-log-picker-xwidget-default ()
  "The task on a Clarify page in xwidget is the default."
  (enghi-tests--with-log-server #'ignore
    (cl-letf (((symbol-function 'enghi--xwidget-path) (lambda () "/gtd/clarify/3"))
              ((symbol-function 'completing-read) (enghi-tests--answer "  Call Bob")))
      (enghi-read-task "Task: ")
      (should (equal (cadr enghi-tests--offered) "  Call Bob"))))
  ;; No working task and no Clarify page: no default
  (let ((enghi-tests--open-tasks '(("next" ((id . 1) (title . "A"))
                                            ((id . 2) (title . "B"))))))
    (enghi-tests--with-log-server #'ignore
      (cl-letf (((symbol-function 'enghi--xwidget-path) (lambda () "/gtd/next"))
                ((symbol-function 'completing-read) (enghi-tests--answer "  A")))
        (enghi-read-task "Task: ")
        (should-not (cadr enghi-tests--offered))))))

(ert-deftest enghi-test-log-post-note ()
  "C-c C-c posts the buffer as a note and closes it; C-u opens the entry."
  (enghi-tests--with-log-server
      (lambda (_m _p _payload) '((log (id . 11) (task_id . 2)) (created . t)))
    (let ((buf (enghi-task-log '((id . 2) (title . "Fix bug")))))
      (with-current-buffer buf
        (should (equal (buffer-name) "*enghi log: Fix bug*"))
        (should enghi-log-mode)
        (should (eq (key-binding (kbd "C-c C-c")) #'enghi-log-commit))
        (should (eq (key-binding (kbd "C-c C-l")) #'enghi-insert-link))
        (insert "Found the cause.\n")
        (enghi-log-commit '(4)))
      (should-not (buffer-live-p buf)))
    (should (equal requests '(("POST" "/api/tasks/2/logs"
                               ((kind . "note") (body . "Found the cause.\n"))))))
    (should (equal browsed "/gtd/clarify/2#log-11"))))

(ert-deftest enghi-test-log-empty-refused ()
  "An empty entry is refused without a request, and the buffer stays."
  (enghi-tests--with-log-server #'ignore
    (let ((buf (enghi-task-log '((id . 2) (title . "Fix bug")))))
      (unwind-protect
          (with-current-buffer buf
            (insert "  \n\n")
            (should-error (enghi-log-commit) :type 'user-error)
            (should (buffer-live-p buf)))
        (kill-buffer buf)))
    (should-not requests)))

(ert-deftest enghi-test-log-server-error-is-user-error ()
  "A refusal from the server is a `user-error' with its message."
  (enghi-tests--with-log-server
      (lambda (&rest _) (signal 'enghi-http-error '(400 "cannot start a task that is done")))
    (let ((err (should-error (enghi-task-start '((id . 2) (title . "Fix bug")))
                             :type 'user-error)))
      (should (equal (cadr err) "cannot start a task that is done")))))

(ert-deftest enghi-test-log-edit-conflict ()
  "A 409 on saving an edit keeps the text and shows both versions."
  (let (shown)
    (enghi-tests--with-log-server
        (lambda (method _path _payload)
          (if (equal method "GET")
              '((logs ((id . 5) (kind . "note") (body . "Old") (version . 1)
                       (created_at . "2026-09-26 01:02:03"))
                      ((id . 6) (kind . "start") (body . "")
                       (created_at . "2026-09-26 02:00:00"))))
            (signal 'enghi-version-conflict
                    (list "updated elsewhere" '((id . 5) (body . "Theirs") (version . 2))))))
      (cl-letf (((symbol-function 'enghi--show-conflict)
                 (lambda (current body) (setq shown (list current body))))
                ((symbol-function 'completing-read)
                 (enghi-tests--answer "  Fix bug  (enghi)" "▶ Fix bug  (enghi)")))
        (let* ((task (enghi-read-task "Task: "))
               (log (progn
                      (fset 'completing-read
                            (lambda (_p coll &rest _)
                              ;; Marks are not editable
                              (should (= (length (all-completions "" coll)) 1))
                              (car (all-completions "" coll))))
                      (enghi--read-log task "Entry: " t)))
               (buf (enghi-task-log-edit task log)))
          (unwind-protect
              (with-current-buffer buf
                (should (equal (buffer-name) "*enghi log: Fix bug #5*"))
                (should (equal (buffer-string) "Old"))
                (erase-buffer)
                (insert "Mine")
                (should-not (enghi-log-commit))
                ;; **The input must remain**, still at the version it was
                ;; fetched at
                (should (buffer-live-p buf))
                (should (equal (buffer-string) "Mine"))
                (should (= enghi-log-version 1)))
            (kill-buffer buf))))
      (should (equal (car (last requests))
                     '("PATCH" "/api/task-logs/5" ((body . "Mine") (version . 1))))))
    (should (equal shown '(((id . 5) (body . "Theirs") (version . 2)) "Mine")))))

(ert-deftest enghi-test-log-delete-while-editing ()
  "C-c C-d in an edit buffer deletes that entry after confirming."
  (enghi-tests--with-log-server (lambda (&rest _) '((ok . t)))
    (let ((buf (enghi-task-log-edit '((id . 2) (title . "Fix bug"))
                                    '((id . 5) (body . "Old") (version . 1)))))
      (with-current-buffer buf
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
          (enghi-task-log-delete))
        (should-not requests)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
          (enghi-task-log-delete)))
      (should-not (buffer-live-p buf))
      (should (equal requests '(("DELETE" "/api/task-logs/5" nil)))))))

(ert-deftest enghi-test-log-start-pause ()
  "Start and pause report the new state, and a no-op says so."
  (let (answer)
    (enghi-tests--with-log-server (lambda (&rest _) answer)
      (let ((task '((id . 2) (title . "Fix bug"))))
        (setq answer '((log (kind . "start")) (created . t) (working . t)))
        (should (equal (enghi-task-start task) "▶ Started: Fix bug"))
        (setq answer '((log (kind . "start")) (created . nil) (working . t)))
        (should (equal (enghi-task-start task) "Already working on Fix bug"))
        (setq answer '((log (kind . "note")) (created . t) (working . t)))
        (should (equal (enghi-task-start task "still on it")
                       "Already working on Fix bug; comment logged"))
        (setq answer '((log (kind . "pause")) (created . t) (working . nil)))
        (should (equal (enghi-task-pause task "lunch") "⏸ Paused: Fix bug"))
        (setq answer '((log . nil) (created . nil) (working . nil)))
        (should (equal (enghi-task-pause task) "Fix bug is not being worked on"))
        ;; Toggle follows the task's working flag
        (setq answer '((log (kind . "pause")) (created . t)))
        (enghi-task-toggle '((id . 2) (title . "Fix bug") (working . t))))
      (should (equal (mapcar #'caddr requests)
                     '(((kind . "start") (body . "")) ((kind . "start") (body . ""))
                       ((kind . "start") (body . "still on it"))
                       ((kind . "pause") (body . "lunch")) ((kind . "pause") (body . ""))
                       ((kind . "pause") (body . ""))))))))

(ert-deftest enghi-test-log-start-names-paused ()
  "A start names the tasks the server paused to make way for it."
  (enghi-tests--with-log-server
      (lambda (&rest _) '((log (kind . "start")) (created . t) (working . t)
                          (paused ((id . 5) (title . "Old task"))
                                  ((id . 6) (title . "Older task")))))
    (should (equal (enghi-task-start '((id . 2) (title . "Fix bug")))
                   "▶ Started: Fix bug (⏸ Paused: Old task, Older task)"))))

(ert-deftest enghi-test-log-picker-groups ()
  "The picker groups the tasks: the working ones, then each list."
  (enghi-tests--with-log-server #'ignore
    (let (group)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p coll &rest _)
                   (setq group (alist-get 'group-function
                                          (cdr (funcall coll "" nil 'metadata))))
                   "  Call Bob")))
        (enghi-read-task "Task: "))
      (should (equal (mapcar (lambda (c) (funcall group c nil))
                             '("▶ Fix bug  (enghi)" "  Write report" "  Call Bob"
                               "  Write report  #4"))
                     '("Working" "Next Actions" "Inbox" "Someday / Maybe")))
      (should (equal (funcall group "  Call Bob" t) "  Call Bob")))))

(ert-deftest enghi-test-log-keys ()
  "The work log commands are on the command map."
  (should (eq (lookup-key enghi-command-map "l") #'enghi-task-log))
  (should (eq (lookup-key enghi-command-map "L") #'enghi-task-log-edit))
  (should (eq (lookup-key enghi-command-map "r") #'enghi-code-link))
  (should (eq (lookup-key enghi-command-map "R") #'enghi-code-link-with-comment))
  (should (eq (lookup-key enghi-command-map "t") #'enghi-task-toggle)))

(ert-deftest enghi-test-command-map-autoload ()
  "The package's autoloads bind `enghi-command-map' as a keymap.
A leaf or use-package `:bind' then needs no autoload of its own."
  (skip-unless (fboundp 'loaddefs-generate))
  (let* ((dir (make-temp-file "enghi-autoloads" t))
         (file (expand-file-name "enghi-autoloads.el" dir)))
    (unwind-protect
        (progn
          (loaddefs-generate (file-name-directory (locate-library "enghi.el")) file)
          (with-temp-buffer
            (insert-file-contents file)
            (should (search-forward
                     "(autoload 'enghi-command-map \"enghi\" nil nil 'keymap)" nil t))))
      (delete-directory dir t))))

;;;;; Code links

(ert-deftest enghi-test-code-dedent ()
  "Common indentation goes, blank lines do not count, tabs stay tabs."
  (should (equal (enghi--dedent "    a\n\n      b\n    c") "a\n\n  b\nc"))
  (should (equal (enghi--dedent "\t\tx\n\ty") "\tx\ny"))
  (should (equal (enghi--dedent "a\n  b") "a\n  b")))

(ert-deftest enghi-test-code-lang ()
  "The code block language comes from the major mode."
  (should (equal (enghi--code-lang 'go-ts-mode) "go"))
  (should (equal (enghi--code-lang 'go-mode) "go"))
  (should (equal (enghi--code-lang 'emacs-lisp-mode) "elisp"))
  (should (equal (enghi--code-lang 'python-ts-mode) "python"))
  (should (equal (enghi--code-lang 'c++-mode) "cpp"))
  (should (equal (enghi--code-lang 'fundamental-mode) ""))
  (should (equal (enghi--code-lang 'text-mode) ""))
  (should (equal (enghi--code-lang 'weird) "")))

(defmacro enghi-tests--in-source (text &rest body)
  "Run BODY in a `go-mode'-like buffer visiting a file in a git repo holding TEXT."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "enghi-repo" t)))
          (file (expand-file-name "internal/web/server.go" root)))
     (unwind-protect
         (progn
           (make-directory (file-name-directory file) t)
           (make-directory (expand-file-name ".git" root))
           (with-temp-buffer
             (insert ,text)
             (setq buffer-file-name file)
             (setq major-mode 'go-ts-mode)
             (transient-mark-mode 1)
             (cl-letf (((symbol-function 'project-current)
                        (lambda (&rest _) (list 'transient root)))
                       ((symbol-function 'project-root) (lambda (p) (nth 1 p))))
               ,@body)
             (set-buffer-modified-p nil)
             (setq buffer-file-name nil)))
       (delete-directory root t))))

(defconst enghi-tests--go "package web\n\nfunc a() {\n\tif x {\n\t\treturn\n\t}\n}\n")

(ert-deftest enghi-test-code-link-region ()
  "A region links its lines and puts them, dedented, in a code block."
  (enghi-tests--in-source enghi-tests--go
    (let ((enghi-code-link-url-function (lambda () "https://github.com/u/r/blob/abc/x.go#L4-L6")))
      (goto-char (point-min))
      (forward-line 3)
      (push-mark (point) t t)
      ;; Ending at the start of line 7 does not take line 7
      (forward-line 3)
      (should (equal (enghi--code-link-entry)
                     (concat "[internal/web/server.go L4-6](https://github.com/u/r/blob/abc/x.go#L4-L6)\n\n"
                             "```go\nif x {\n\treturn\n}\n```"))))))

(ert-deftest enghi-test-code-link-point ()
  "Without a region, link the current line only; no URL means plain text."
  (enghi-tests--in-source enghi-tests--go
    (deactivate-mark)
    (goto-char (point-min))
    (forward-line 2)
    (let ((enghi-code-link-url-function (lambda () "https://h/x.go#L3")))
      (should (equal (enghi--code-link-entry) "[internal/web/server.go L3](https://h/x.go#L3)")))
    (let ((enghi-code-link-url-function #'ignore))
      (should (equal (enghi--code-link-entry) "internal/web/server.go L3")))))

(ert-deftest enghi-test-code-link-browse-at-remote ()
  "browse-at-remote gives the URL, with the line even without a region."
  (skip-unless (require 'browse-at-remote nil t))
  (let (line-option)
    (cl-letf (((symbol-function 'browse-at-remote-get-url)
               (lambda ()
                 (setq line-option browse-at-remote-add-line-number-if-no-region-selected)
                 "https://github.com/u/r/blob/abc/x.go#L3")))
      (should (equal (enghi--browse-at-remote-url) "https://github.com/u/r/blob/abc/x.go#L3"))
      (should (eq line-option t)))
    ;; A file with no known remote: no URL rather than an error
    (cl-letf (((symbol-function 'browse-at-remote-get-url)
               (lambda () (error "Sorry, I'm not sure what to do with this"))))
      (should-not (enghi--browse-at-remote-url)))))

(ert-deftest enghi-test-code-link-without-browse-at-remote ()
  "Without browse-at-remote installed, there is no URL, and no error."
  (let ((featurep (symbol-function 'featurep))
        (require (symbol-function 'require)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (f &rest r) (unless (eq f 'browse-at-remote) (apply featurep f r))))
              ((symbol-function 'require)
               (lambda (f &rest r) (unless (eq f 'browse-at-remote) (apply require f r))))
              ((symbol-function 'browse-at-remote-get-url)
               (lambda () (error "Should not be called"))))
      (should-not (enghi--browse-at-remote-url)))))

(ert-deftest enghi-test-code-link-posts ()
  "`enghi-code-link' posts the entry to the chosen task."
  (enghi-tests--in-source enghi-tests--go
    (let ((enghi-code-link-url-function #'ignore))
      (goto-char (point-min))
      (enghi-tests--with-log-server (lambda (&rest _) '((created . t)))
        (cl-letf (((symbol-function 'completing-read) (enghi-tests--answer "▶ Fix bug  (enghi)")))
          (enghi-code-link))
        ;; The working task is the default
        (should (equal (cadr enghi-tests--offered) "▶ Fix bug  (enghi)"))
        (should (equal requests '(("POST" "/api/tasks/2/logs"
                                   ((kind . "note") (body . "internal/web/server.go L1"))))))))))

(ert-deftest enghi-test-code-link-with-comment ()
  "With a comment, the entry opens in the log buffer, after any unsent text."
  (enghi-tests--in-source enghi-tests--go
    (let ((enghi-code-link-url-function #'ignore))
      (goto-char (point-min))
      (enghi-tests--with-log-server #'ignore
        (cl-letf (((symbol-function 'completing-read) (enghi-tests--answer "▶ Fix bug  (enghi)")))
          (let ((source (current-buffer))
                (buf (enghi-code-link-with-comment)))
            (unwind-protect
                (progn
                  (with-current-buffer buf
                    (should (equal (buffer-string) "internal/web/server.go L1\n\n"))
                    (should (buffer-modified-p)))
                  (with-current-buffer source
                    (forward-line 2)
                    (enghi-code-link '(4)))
                  (with-current-buffer buf
                    (should (equal (buffer-string)
                                   "internal/web/server.go L1\n\ninternal/web/server.go L3\n\n"))))
              (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf))))
        (should-not requests)))))

;;;;; Against the running server

(ert-deftest enghi-test-log-live ()
  "Start, log, edit (with a conflict), search, pause and delete on the server."
  (let* ((title (enghi-tests--unique "Log target"))
         (task (enghi-capture title))
         (id (alist-get 'id task))
         (word (enghi-tests--unique "zyxlogword")))
    (should (string-match-p "Started" (enghi-task-start task)))
    (should (string-match-p "Already" (enghi-task-start task)))
    ;; The picker sees it as working
    (cl-letf (((symbol-function 'enghi--xwidget-path) (lambda () nil))
              ((symbol-function 'completing-read)
               (lambda (_p coll &rest _)
                 (seq-find (lambda (c) (string-match-p (regexp-quote title) c))
                           (all-completions "" coll)))))
      (should (alist-get 'working (enghi-read-task "Task: "))))
    (let ((buf (enghi-task-log task)))
      (with-current-buffer buf
        (insert "Note about " word)
        (enghi-log-commit)))
    (let* ((logs (alist-get 'logs (enghi-request "GET" (format "/api/tasks/%d/logs" id))))
           (note (seq-find (lambda (l) (equal (alist-get 'kind l) "note")) logs)))
      (should (equal (alist-get 'body note) (concat "Note about " word)))
      ;; Search finds it and opens the entry
      (let ((hit (seq-find (lambda (r) (equal (alist-get 'kind r) "log"))
                           (enghi-search word "log"))))
        (should (equal (enghi--result-path hit)
                       (format "/gtd/clarify/%d#log-%d" id (alist-get 'id note)))))
      ;; Edited elsewhere while open here: the save is refused
      (let ((buf (enghi-task-log-edit task note)))
        (unwind-protect
            (with-current-buffer buf
              (enghi-request "PATCH" (format "/api/task-logs/%d" (alist-get 'id note))
                             `((body . "Edited elsewhere") (version . 1)))
              (erase-buffer)
              (insert "Edited here")
              (cl-letf (((symbol-function 'enghi--show-conflict) #'ignore))
                (should-not (enghi-log-commit)))
              (should (equal (buffer-string) "Edited here"))
              (setq enghi-log-version 2)
              (enghi-log-commit))
          (when (buffer-live-p buf) (kill-buffer buf))))
      (should (equal (alist-get 'body (seq-find (lambda (l) (equal (alist-get 'id l) (alist-get 'id note)))
                                                 (enghi--task-logs task)))
                     "Edited here"))
      (should (string-match-p "Paused" (enghi-task-pause task "done for today")))
      (should (string-match-p "not being worked on" (enghi-task-pause task)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
                ((symbol-function 'enghi-read-task) (lambda (_) task))
                ((symbol-function 'completing-read)
                 (lambda (_p coll &rest _)
                   (seq-find (lambda (c) (string-match-p "Edited here" c))
                             (all-completions "" coll)))))
        (enghi-task-log-delete))
      (should-not (seq-find (lambda (l) (equal (alist-get 'id l) (alist-get 'id note)))
                            (enghi--task-logs task))))))

;;;; Sorting from Emacs

(require 'enghi-triage)

(defvar enghi-tests--contexts nil
  "Whether the stubbed server has contexts on.")

(defvar enghi-tests--lists
  '(("inbox"
     ((id . 2) (title . "Second") (state . "inbox") (created_at . "2026-10-02 00:00:00"))
     ((id . 1) (title . "First") (state . "inbox") (created_at . "2026-10-01 00:00:00"))
     ((id . 3) (title . "Third") (state . "inbox") (created_at . "2026-10-03 00:00:00")))
    ("next"
     ((id . 5) (title . "Fix bug") (state . "next") (working . t) (project_title . "enghi")))
    ("waiting"
     ((id . 6) (title . "Reply") (state . "waiting") (waiting_for . "Bob"))))
  "Tasks per state on the stubbed server. The Inbox is not oldest first.")

(defmacro enghi-tests--with-triage (keys &rest body)
  "Run BODY with the server stubbed and KEYS read by `read-key', in order.
Bind `requests' to the requests made but the lists and settings, as (METHOD
PATH PAYLOAD), oldest first, `prompts' to what was shown, newest first, and
`browsed' to the path given to `enghi-browse'."
  (declare (indent 1))
  `(let ((requests nil) (prompts nil) (browsed nil) (keys ,keys))
     (cl-letf (((symbol-function 'enghi-request)
                (lambda (method path &optional payload params)
                  (pcase path
                    ("/api/settings" `((contexts . ,enghi-tests--contexts)))
                    ("/api/tasks"
                     (let ((state (alist-get 'state params)))
                       ;; The Next list asks for the Next Actions list
                       `((tasks ,@(cdr (assoc (if (equal state "next_actions") "next" state)
                                              enghi-tests--lists))))))
                    (_
                     (setq requests (append requests (list (list method path payload))))
                     (pcase path
                       ("/api/projects" '((projects ((id . 7) (title . "Garden")))))
                       ("/api/contexts" '((contexts ((id . 3) (name . "@home")))))
                       ((rx "/api/tasks/" (let id (+ digit)) eos)
                        `((task (id . ,(string-to-number id)) (title . "Renamed")
                                (state . "inbox"))))
                       ((rx "/logs" eos) '((log (kind . "start")) (created . t)))
                       (_ nil))))))
               ((symbol-function 'read-key)
                (lambda (prompt &rest _)
                  (push (if prompt (substring-no-properties prompt) "") prompts)
                  (or (pop keys) (error "No more keys"))))
               ((symbol-function 'enghi-browse) (lambda (path) (setq browsed path))))
       ,@body)))

(defun enghi-tests--writes-only (requests)
  "Return the requests in REQUESTS that write."
  (seq-remove (lambda (r) (equal (car r) "GET")) requests))

(ert-deftest enghi-test-task-list ()
  "The lists open on the Inbox, oldest first; j/k choose, Tab changes list."
  (let (msg)
    (enghi-tests--with-triage (list ?j ?m ?\t ?. ?q)
      (setq msg (enghi-task-list))
      (should (equal (enghi-tests--writes-only requests)
                     '(("PATCH" "/api/tasks/2" ((state . "someday")))
                       ("POST" "/api/tasks/5/logs" ((kind . "start") (body . ""))))))
      (setq prompts (reverse prompts))
      (should (string-prefix-p
               "Inbox 3 · Next 1 · Waiting 1 · Scheduled 0 · Later 0 · Someday 0\n›   First"
               (nth 0 prompts)))
      (should (string-match-p "^    Second  " (nth 0 prompts)))
      (should (string-match-p "\n\nn Next .* f File\nt Rename .* RET Details\nj/k Move  Tab List  g Refresh  q Quit\\'"
                              (nth 0 prompts)))
      (should (string-match-p "^›   Second" (nth 1 prompts)))
      ;; The result shows on top, and the cursor stays where it was
      (should (string-match-p "\\`→ Someday: Second\nInbox 3 .*\n.*\n›   Second" (nth 2 prompts)))
      ;; Next: the working task is marked, with its project
      (should (string-match-p "^› ▶ Fix bug +enghi" (nth 3 prompts)))
      (should (string-prefix-p "▶ Started: Fix bug\n" (nth 4 prompts))))
    (should (equal msg "Inbox: 3 left"))))

(ert-deftest enghi-test-task-list-empty ()
  "With the Inbox empty, the lists open on Next; an empty list ignores actions."
  (let ((enghi-tests--lists (cons '("inbox") (cdr enghi-tests--lists))))
    (enghi-tests--with-triage (list 'backtab ?d ?j ?q)
      (should (equal (enghi-task-list) "Inbox 0"))
      (should-not (enghi-tests--writes-only requests))
      (setq prompts (reverse prompts))
      (should (string-match-p "^› ▶ Fix bug" (nth 0 prompts)))
      (should (string-match-p "\n   (empty)\n" (nth 1 prompts))))))

(ert-deftest enghi-test-task-list-scrolls ()
  "A long list shows a window of rows around the chosen one."
  (should (equal (enghi--task-list-window 40 0 15) '(0 . 15)))
  (should (equal (enghi--task-list-window 40 20 15) '(13 . 28)))
  (should (equal (enghi--task-list-window 40 39 15) '(25 . 40)))
  (should (equal (enghi--task-list-window 5 3 15) '(0 . 5)))
  (let* ((tasks (mapcar (lambda (i) `((id . ,i) (title . ,(format "Task %d" i)) (state . "next")))
                        (number-sequence 0 39)))
         (menu (substring-no-properties
                (enghi--task-list-menu `(("next" ,@tasks)) "next" 20 nil))))
    (should (string-match-p "\n   ↑ 13 more\n   +Task 13 " menu))
    (should (string-match-p "\n›   Task 20 " menu))
    (should (string-match-p "Task 27 .*\n   ↓ 12 more\n" menu))))

(ert-deftest enghi-test-triage-read-key ()
  "C-n/down and C-p/up move, S-Tab goes back, C-g quits, other keys wait."
  (dolist (case '((down . ?j) (?\C-n . ?j) (up . ?k) (?\C-p . ?k) (tab . ?\t)
                  (S-tab . backtab) (backtab . backtab) (return . ?\r) (?\C-g . ?q)))
    (let ((keys (list ?z (car case))))
      (cl-letf (((symbol-function 'read-key) (lambda (&rest _) (pop keys))))
        (should (eq (enghi--triage-read-key "" '(?j ?k ?\t backtab ?\r ?q)) (cdr case)))))))

(ert-deftest enghi-test-triage-posframe ()
  "With `posframe', the lists show in a posframe that hides for questions."
  (let ((enghi-triage-display 'posframe) events)
    (cl-letf (((symbol-function 'enghi--triage-posframe-p) (lambda () t))
              ((symbol-function 'posframe-show)
               (lambda (buffer &rest _)
                 (push (list 'show (with-current-buffer buffer
                                     (substring-no-properties (buffer-string))))
                       events)))
              ((symbol-function 'posframe-hide) (lambda (_) (push '(hide) events))))
      (enghi-tests--with-triage (list ?n ?q)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (push '(ask) events) "Garden")))
          (enghi-task-list))
        ;; No prompt in the echo area: the posframe has the lists
        (should (equal prompts '("" "")))))
    (setq events (reverse events))
    (should (string-match-p "\\`Inbox 3 .*\n›   First" (cadr (nth 0 events))))
    (should (equal (mapcar #'car events) '(show hide ask show hide)))
    (should (string-prefix-p "→ Next: First (Garden)\n" (cadr (nth 3 events))))))

(ert-deftest enghi-test-triage-keys ()
  "The task lists are on the command map."
  (should (eq (lookup-key enghi-command-map "p") #'enghi-task-list)))

(ert-deftest enghi-test-triage-live ()
  "`.' moves a task to Next and starts it, and the server pauses the other."
  (let* ((a (enghi-capture (enghi-tests--unique "Working first")))
         (b (enghi-capture (enghi-tests--unique "Switch to")))
         (project (enghi-request "POST" "/api/projects"
                                 `((title . ,(enghi-tests--unique "Triage project")))))
         (get (lambda (task)
                (alist-get 'task (enghi-request "GET" (format "/api/tasks/%d"
                                                              (alist-get 'id task)))))))
    (enghi-task-start a)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (alist-get 'title project))))
      (should (string-match-p (regexp-quote (format "Paused: %s" (alist-get 'title a)))
                              (enghi--task-start-now b))))
    (should-not (alist-get 'working (funcall get a)))
    (should (alist-get 'working (funcall get b)))
    (should (equal (alist-get 'state (funcall get b)) "next"))
    (should (equal (alist-get 'project_id (funcall get b)) (alist-get 'id project)))))

;;;; Files

(defconst enghi-tests--png
  (unibyte-string #x89 #x50 #x4e #x47 #x0d #x0a #x1a #x0a
                  #x00 #x00 #x00 #x0d #x49 #x48 #x44 #x52
                  #x00 #x00 #x00 #x01 #x00 #x00 #x00 #x01
                  #x08 #x06 #x00 #x00 #x00 #x1f #x15 #xc4 #x89
                  #x00 #x00 #x00 #x0d #x49 #x44 #x41 #x54
                  #x78 #x9c #x63 #x60 #x60 #x60 #xf8 #x0f #x00 #x01 #x04 #x01 #x00
                  #x5f #xe5 #xc3 #x4b
                  #x00 #x00 #x00 #x00 #x49 #x45 #x4e #x44 #xae #x42 #x60 #x82)
  "A 1x1 PNG. Its bytes include ones above 127, so it breaks if sent multibyte.")

(ert-deftest enghi-test-insert-file ()
  "Upload a PNG from a file and insert its Markdown at point."
  (let ((file (make-temp-file "enghi-test" nil ".png")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region enghi-tests--png nil file nil 'silent))
          (with-temp-buffer
            (insert "before ")
            (enghi-insert-file file)
            ;; Files are stored by content, so the alt text is the name the
            ;; first upload gave
            (should (string-match "\\`before !\\[[^]]+\\](\\(/files/[^)]+\\))\\'"
                                  (buffer-string)))
            ;; The server stored the bytes unchanged
            (let ((url-request-method "GET")
                  (buf (url-retrieve-synchronously
                        (enghi--url (match-string 1 (buffer-string))) t t 10)))
              (unwind-protect
                  (with-current-buffer buf
                    (goto-char (point-min))
                    (re-search-forward "\n\r?\n")
                    (should (equal (buffer-substring (point) (point-max))
                                   enghi-tests--png)))
                (kill-buffer buf)))))
      (delete-file file))))

(ert-deftest enghi-test-insert-file-unsupported ()
  "Refuse an unsupported file type before sending it."
  (let ((file (make-temp-file "enghi-test" nil ".svg" "<svg/>")))
    (unwind-protect
        (cl-letf (((symbol-function 'enghi-upload)
                   (lambda (&rest _) (error "Should not be sent"))))
          (with-temp-buffer
            (should-error (enghi-insert-file file) :type 'user-error)
            (should (equal (buffer-string) ""))))
      (delete-file file))))

(ert-deftest enghi-test-yank-media-image ()
  "The `yank-media' handler uploads the image and inserts its Markdown."
  (with-temp-buffer
    (enghi-page-mode 1)
    (when (fboundp 'yank-media-handler)
      (should (eq (alist-get "image/.*" yank-media--registered-handlers nil nil #'equal)
                  #'enghi--yank-media-image)))
    (enghi--yank-media-image 'image/png enghi-tests--png)
    (should (string-match-p "\\`!\\[[^]]*\\](/files/[^)]+)\\'" (buffer-string)))
    (should-error (enghi--yank-media-image 'image/svg+xml "<svg/>")
                  :type 'user-error)))
