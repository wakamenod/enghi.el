;;; enghi-tidy.el --- Tidy captured Inbox items with Claude -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; `enghi-capture' puts a line in the Inbox at once. When the Claude Code CLI
;; is installed, this file then tidies the item in the background: `claude
;; -p' turns the line into a short title, a note with the rest and the URL in
;; it, and the task is updated with them. The line as typed stays at the end
;; of the note.
;;
;; **Capturing never waits for Claude.** An answer takes 15 to 30 seconds, and
;; capturing must stay instant. Nothing is lost when Claude is missing, fails
;; or takes too long: the item stays as captured. The update carries the
;; version the capture returned, so an item changed in the meantime (sorted
;; or renamed) is left alone.
;;
;; `claude' runs with no tools, MCP servers, settings or saved session, in the
;; temporary directory, so it reads no project's CLAUDE.md. `--bare' would
;; skip the login too, so it is not used.

;;; Code:

(require 'enghi)
(require 'subr-x)

(defcustom enghi-capture-tidy t
  "Whether `enghi-capture' tidies the item with Claude afterwards.
It does when this is non-nil and `enghi-claude-program' is found."
  :type 'boolean
  :group 'enghi)

(defcustom enghi-claude-program "claude"
  "The Claude Code CLI, run as `claude -p'."
  :type 'string
  :group 'enghi)

(defcustom enghi-capture-tidy-model "haiku"
  "Model that tidies captured items."
  :type 'string
  :group 'enghi)

(defcustom enghi-capture-tidy-timeout 120
  "Seconds to wait for Claude before leaving the item as captured."
  :type 'integer
  :group 'enghi)

(defconst enghi--tidy-prompt
  "You tidy one item just captured into a GTD inbox: what the user typed in a hurry.
Keep its language; do not translate.
title: one short line saying what the item is about, with typos fixed. Keep the
user's words where you can. Do not turn it into an action or add what is not
there. No trailing period.
note: the details that do not fit in the title (dates, conditions, names), as
short plain text, or \"\" when there are none.
url: a URL that appears in the input, or \"\".
Never invent anything that is not in the input."
  "System prompt for tidying a captured item.")

(defconst enghi--tidy-schema
  (json-encode
   '((type . "object")
     (properties . ((title . ((type . "string")))
                    (note . ((type . "string")))
                    (url . ((type . "string")))))
     (required . ["title" "note" "url"])
     (additionalProperties . :json-false)))
  "JSON Schema of the tidied item.")

(defun enghi--tidy-available-p ()
  "Return non-nil if captured items are tidied."
  (and enghi-capture-tidy (executable-find enghi-claude-program)))

(defun enghi--tidy-command ()
  "Return the command line of `claude -p' that tidies an item from stdin."
  (list enghi-claude-program "-p"
        "--model" enghi-capture-tidy-model
        "--tools" ""
        "--strict-mcp-config"
        "--setting-sources" ""
        "--no-session-persistence"
        "--output-format" "json"
        "--system-prompt" enghi--tidy-prompt
        "--json-schema" enghi--tidy-schema))

(defun enghi--tidy-answer (output)
  "Return the tidied item in OUTPUT of `claude -p', as an alist, or nil."
  (when-let* ((json (enghi--parse-json output)))
    (unless (alist-get 'is_error json)
      (alist-get 'structured_output json))))

(defun enghi--tidy-fields (task original answer)
  "Return the fields that update TASK from Claude's ANSWER, or nil for none.
ORIGINAL is the line as captured, which goes at the end of the note. A URL
is set only if TASK has none."
  (let ((title (string-trim (or (alist-get 'title answer) "")))
        (note (string-trim (or (alist-get 'note answer) "")))
        (url (string-trim (or (alist-get 'url answer) ""))))
    (unless (or (string-empty-p title)
                (and (equal title original) (string-empty-p note) (string-empty-p url)))
      `((title . ,title)
        (note . ,(string-join (delq nil (list (unless (string-empty-p note) note)
                                              (format "Captured as: %s" original)))
                              "\n\n"))
        ,@(when (and (string-match-p "\\`https?://" url)
                     (not (enghi--task-field task 'url)))
            `((url . ,url)))
        (version . ,(alist-get 'version task))))))

(defun enghi--tidy-apply (task original output)
  "Update TASK, captured as ORIGINAL, from OUTPUT of `claude -p'.
Return the message, which is also shown."
  (let* ((answer (enghi--tidy-answer output))
         (fields (and answer (enghi--tidy-fields task original answer)))
         (msg (cond ((null answer) (format "Could not tidy: %s" original))
                    ((null fields) nil)
                    (t (condition-case err
                           (progn
                             (enghi-request "PATCH" (format "/api/tasks/%s" (alist-get 'id task))
                                            fields)
                             (format "Tidied: %s → %s" original (alist-get 'title fields)))
                         (enghi-version-conflict
                          (format "Left as captured, as it changed meanwhile: %s" original))
                         (enghi-error
                          (format "Could not tidy %s: %s" original
                                  (error-message-string err))))))))
    (when msg (message "%s" msg))
    msg))

(defun enghi-tidy-task (task original)
  "Tidy TASK, captured from the line ORIGINAL, with `claude -p' in the background.
Return the process."
  (let* ((default-directory temporary-file-directory)
         (buffer (generate-new-buffer " *enghi-tidy*"))
         timer
         (proc (make-process
                :name "enghi-tidy"
                :buffer buffer
                :command (enghi--tidy-command)
                :connection-type 'pipe
                :noquery t
                :stderr (get-buffer-create " *enghi-tidy-stderr*")
                :sentinel
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (when timer (cancel-timer timer))
                    (unwind-protect
                        (enghi--tidy-apply task original
                                           (with-current-buffer buffer (buffer-string)))
                      (kill-buffer buffer)))))))
    (setq timer (run-at-time enghi-capture-tidy-timeout nil
                             (lambda () (when (process-live-p proc) (delete-process proc)))))
    (process-send-string proc original)
    (process-send-eof proc)
    proc))

(provide 'enghi-tidy)
;;; enghi-tidy.el ends here
