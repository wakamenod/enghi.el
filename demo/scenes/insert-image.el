;;; insert-image.el --- Inserting images and PDFs from Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of the insert-image branch, in the user's own configuration,
;; against a throwaway server the recorder started:
;;
;;   1. C-c C-i in a page buffer uploads an image and inserts ![...](...).
;;   2. Saved, the page shows the image in the browser (xwidget, right).
;;   3. A PDF goes in as a plain link.
;;   4. An unsupported file (SVG) is refused before anything is sent.
;;   5. M-x yank-media pastes a screenshot from the clipboard.
;;   6. The same works in a task's work log buffer.
;;
;; The pictures are drawn here from SVG with rsvg-convert, into
;; /tmp/enghi-demo-insert-image/.  Step 5 puts one on the clipboard with
;; osascript, which replaces what the clipboard held.
;;
;; Played by demo/scenes/insert-image.sh through demo/record.sh.

;;; Code:

(require 'enghi)
(require 'enghi-log)

(defvar demo-root "/tmp/enghi-demo-insert-image/" "Where the pictures are drawn.")

(setq demo-log-file "/tmp/enghi-demo-insert-image-log.txt")

(defvar demo-page-slug nil "The slug of the page this scene edits.")
(defvar demo-task nil "The task whose log this scene writes.")

(defconst demo-diagram-svg "<svg xmlns='http://www.w3.org/2000/svg' width='640' height='260'>
<rect width='640' height='260' fill='#f6f8fa'/>
<g font-family='Helvetica' font-size='22' text-anchor='middle'>
<rect x='30' y='90' width='150' height='80' rx='10' fill='#7c5cff'/>
<text x='105' y='137' fill='white'>Emacs</text>
<rect x='245' y='90' width='150' height='80' rx='10' fill='#2da44e'/>
<text x='320' y='137' fill='white'>/api/files</text>
<rect x='460' y='90' width='150' height='80' rx='10' fill='#d4a72c'/>
<text x='535' y='137' fill='white'>files.db</text>
<path d='M180 130 H240 M395 130 H455' stroke='#333' stroke-width='4'/>
<text x='320' y='50' fill='#333' font-size='26'>Upload flow</text>
</g></svg>")

(defconst demo-screenshot-svg "<svg xmlns='http://www.w3.org/2000/svg' width='560' height='220'>
<rect width='560' height='220' fill='#1e1e2e'/>
<rect width='560' height='34' fill='#313244'/>
<circle cx='20' cy='17' r='7' fill='#f38ba8'/><circle cx='42' cy='17' r='7' fill='#f9e2af'/><circle cx='64' cy='17' r='7' fill='#a6e3a1'/>
<g font-family='Menlo' font-size='18' fill='#cdd6f4'>
<text x='24' y='80'>$ make test</text>
<text x='24' y='115' fill='#a6e3a1'>Ran 71 tests, 71 results as expected</text>
<text x='24' y='150'>$ git push -u origin insert-image</text>
<text x='24' y='185' fill='#89b4fa'>(screenshot)</text>
</g></svg>")

(defun demo-draw (svg file &optional format)
  "Draw SVG into FILE under `demo-root', as FORMAT (png by default)."
  (let ((source (expand-file-name "source.svg" demo-root)))
    (with-temp-file source (insert svg))
    (call-process "rsvg-convert" nil nil nil "-f" (or format "png")
                  "-o" (expand-file-name file demo-root) source)
    (delete-file source)))

(defun demo-assets ()
  "Draw the files the scene uploads."
  (delete-directory demo-root t)
  (make-directory demo-root t)
  (demo-draw demo-diagram-svg "upload-flow.png")
  (demo-draw demo-diagram-svg "design-notes.pdf" "pdf")
  (demo-draw demo-screenshot-svg "screenshot.png")
  (with-temp-file (expand-file-name "logo.svg" demo-root)
    (insert demo-diagram-svg)))

(defun demo-seed ()
  "Make the page and the task this scene writes in."
  (setq demo-page-slug
        (alist-get 'slug (enghi-request "POST" "/api/pages"
                                        '((title . "画像アップロードの設計")
                                          (body . "# 画像アップロードの設計\n\nEmacs から画像を貼る流れ。\n")))))
  (let ((id (alist-get 'id (enghi-request "POST" "/api/tasks"
                                          '((title . "画像挿入のデモを撮る"))))))
    (enghi-request "PATCH" (format "/api/tasks/%s" id) '((state . "next")))
    (setq demo-task `((id . ,id) (title . "画像挿入のデモを撮る")))))

(defun demo-scene-build ()
  "Seed the server and lay the screen out.  Called by demo.el."
  (setq enghi-browse-function #'enghi-browse-in-xwidget)
  ;; A command run from a timer was not started by a key, so `read-file-name'
  ;; would open the macOS file panel: a window of its own, not recorded, that
  ;; nothing here can type into
  (setq use-file-dialog nil)
  (demo-assets)
  (demo-seed)
  (delete-other-windows)
  (let ((buffer (enghi-open demo-page-slug)))
    (delete-other-windows)
    (switch-to-buffer buffer)
    (setq default-directory demo-root)
    (goto-char (point-max)))
  (let ((right (split-window-right)))
    (with-selected-window right
      (enghi-browse (format "/wiki/%s" demo-page-slug))))
  (demo-left)
  (demo-say (format "enghi.el from %s   server %s"
                    (abbreviate-file-name (locate-library "enghi")) enghi-server-url)))

;;;; Windows

(defun demo-left ()
  "Select the left window."
  (select-window (frame-first-window))
  nil)

(defun demo-reload-right ()
  "Reload the web view, which does not follow changes made through the API."
  (when-let* ((session (xwidget-webkit-current-session)))
    (xwidget-webkit-execute-script session "location.reload()"))
  nil)

(defun demo-browse-right (path)
  "Show PATH of the server in the right window."
  (select-window (next-window (frame-first-window)))
  (enghi-browse path)
  (demo-left)
  nil)

(defun demo-scroll-right-to-bottom ()
  "Scroll the web view to the end of the page."
  (when-let* ((session (xwidget-webkit-current-session)))
    (xwidget-webkit-execute-script
     session "window.scrollTo(0, document.body.scrollHeight)"))
  nil)

(defun demo-say-refusal ()
  "Say again the refusal `enghi-insert-file' left in *Messages*.
The echo area is soon taken by whatever the configuration says next."
  (with-current-buffer "*Messages*"
    (goto-char (point-max))
    (when (re-search-backward "Unsupported file type: .*" nil t)
      (demo-say (concat "→ " (match-string 0))))))

;;;; The clipboard

(defun demo-copy-screenshot ()
  "Put the screenshot on the clipboard, as a screenshot tool would."
  (call-process "osascript" nil nil nil "-e"
                (format "set the clipboard to (read (POSIX file %S) as «class PNGf»)"
                        (expand-file-name "screenshot.png" demo-root)))
  (message "clipboard: %S" (gui-get-selection 'CLIPBOARD 'TARGETS))
  nil)

;;;; The work log

(defun demo-open-log ()
  "Open a new entry of the task's work log on the left."
  (demo-left)
  (let ((buffer (enghi--log-buffer demo-task)))
    (switch-to-buffer buffer)
    (setq default-directory demo-root))
  nil)

(defun demo-report ()
  "Say what the server now holds, for the log."
  (message "page body: %S" (alist-get 'body (enghi-page demo-page-slug)))
  (message "task logs: %S"
           (mapcar (lambda (l) (alist-get 'body l))
                   (alist-get 'logs (enghi-request
                                     "GET" (format "/api/tasks/%s/logs"
                                                   (alist-get 'id demo-task)))))))

(provide 'insert-image)
;;; insert-image.el ends here
