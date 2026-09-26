;;; demo.el --- The Emacs side of a recorded demonstration  -*- lexical-binding: t; -*-

;;; Commentary:

;; What `demo/record.sh' loads into the Emacs it records: the user's own
;; configuration, this checkout's enghi.el in front of whatever that
;; configuration points at, pointed at the throwaway server the recorder
;; started, and the handful of things a scene needs to be driven from
;; outside.
;;
;; Adapted from emacs-claude-code's demo/, whose README explains the
;; recording side (a window recorded through ScreenCaptureKit, keys run
;; through the keymap of the buffer they belong to rather than fed to a
;; keyboard this Emacs does not have).
;;
;; A scene is two files under demo/scenes: NAME.el, loaded here, which
;; says what to build and defines the steps; and NAME.sh, read by the
;; recorder, which is the order they are played in and how long each is
;; held.

;;; Code:

(require 'seq)
(require 'subr-x)

(defvar demo-scene-file nil "The NAME.el of the scene.  Set by the recorder.")
(defvar demo-checkout nil "The checkout whose enghi.el is demonstrated.")
(defvar demo-server-name "enghi-demo" "The server the recorder steps this Emacs through.")
(defvar demo-ready-file "/tmp/enghi-demo-ready.txt" "Written once the scene is built.")
(defvar demo-frame-title "enghi demo" "The title of the recorded frame.")
(defvar demo-enghi-url "http://127.0.0.1:7798" "The throwaway enghi server.")
(defvar demo-frame-position '(40 . 140) "Where the frame is held, in pixels.")
(defvar demo-frame-size '(1700 . 950) "How big the frame is held, in pixels.")

;;;; The configuration this is played in

(defun demo-load-configuration ()
  "Load the user's configuration, then this checkout's enghi.el."
  (setq package-user-dir (expand-file-name "~/.emacs.d/elpa"))
  (load (expand-file-name "~/.emacs.d/early-init.el") t t)
  (package-initialize)
  (load (expand-file-name "~/.emacs.d/init.el") t t)
  ;; The init loads enghi.el from the main checkout, possibly already.
  ;; Load this checkout's files over it, and never talk to the user's
  ;; own server.
  (add-to-list 'load-path demo-checkout)
  ;; `defvar' leaves a variable that is already bound alone, so the keymaps
  ;; of the checkout loaded first would stay: unbind them all first.
  (mapatoms (lambda (symbol)
              (when (and (boundp symbol)
                         (string-prefix-p "enghi-" (symbol-name symbol)))
                (makunbound symbol))))
  (dolist (file '("enghi" "enghi-log" "enghi-consult"))
    (load (expand-file-name file demo-checkout) nil t))
  (setq enghi-server-url demo-enghi-url)
  ;; The init binds this too, but not in a way a -Q Emacs loading it by
  ;; hand ends up with
  (global-set-key (kbd "C-c n") enghi-command-map)
  ;; A child frame is a window of its own to macOS, and only this frame's
  ;; window is recorded: keep the completions in the minibuffer.
  (when (fboundp 'vertico-posframe-mode) (vertico-posframe-mode -1))
  ;; Nor grow the minibuffer: shrinking the windows above it has Emacs 32
  ;; scroll their contents with `ns_scroll_run', which crashed the demo
  ;; Emacs in three runs out of four (2026-09-26).  The candidates go in
  ;; the other window instead, which changes no window's size.
  (when (require 'vertico-buffer nil t)
    (setq vertico-buffer-display-action
          '(display-buffer-use-some-window (inhibit-same-window . t)))
    (vertico-buffer-mode 1)))

;;;; Saying what is going on

(defun demo-save-log (file)
  "Write what this Emacs has said into FILE."
  (with-current-buffer "*Messages*"
    (write-region (point-min) (point-max) file nil 'quietly))
  nil)

(defvar demo-log-file nil
  "Where `demo-say' keeps what this Emacs has said so far, if anywhere.
Kept at every caption: when Emacs dies halfway, the log says how far it got.")

(defun demo-say (text)
  "Put TEXT in the echo area, where the camera can read it."
  (let ((message-log-max 1000))
    (message "%s" (propertize text 'face '(:weight bold :foreground "orange"))))
  (when demo-log-file (demo-save-log demo-log-file))
  nil)

;;;; The frame the video is taken of

(defun demo-main-frame ()
  "Return the frame the demonstration is played in."
  (seq-find (lambda (frame) (equal (frame-parameter frame 'name) demo-frame-title))
            (frame-list)))

(defun demo-frame ()
  "Give the frame the size the recording is taken at."
  (when-let* ((frame (demo-main-frame)))
    (set-frame-size frame (car demo-frame-size) (cdr demo-frame-size) t)
    (set-frame-position frame (car demo-frame-position) (cdr demo-frame-position))
    (when-let* ((window (get-buffer-window "*Warnings*" t)))
      (delete-window window)))
  nil)

(defvar demo-pin-timer nil)

(defun demo-pin ()
  "Hold the frame at the size the recording is taken at."
  (when-let* ((frame (demo-main-frame)))
    (unless (equal (frame-position frame) demo-frame-position)
      (demo-frame))))

;;;; Playing a step
;;
;; Emacs does not answer the server while a minibuffer is open, so a step
;; that opens one cannot be sent after it.  `demo-play' takes the whole
;; step at once and plays it on timers, which do run inside the
;; minibuffer: each item schedules the next before it runs, so an item
;; that opens a minibuffer does not hold the rest up.

(defvar demo-type-delay 0.07 "Seconds between typed characters.")

(defun demo--expand (steps)
  "Turn the strings of STEPS into one item per character."
  (seq-mapcat (lambda (step)
                (if (stringp step)
                    (seq-mapcat (lambda (c) (list (list :char (if (eq c ?\n) 'return c))
                                                   demo-type-delay))
                                step)
                  (list step)))
              steps))

(defun demo--run-key (key prefix)
  "Run what KEY is bound to in the selected window, with PREFIX.
A timer runs with whatever buffer was current, not necessarily the one in
the selected window: a command before it may have popped another."
  (set-buffer (window-buffer (selected-window)))
  (let ((command (key-binding (kbd key))))
    (let ((current-prefix-arg prefix)
          (this-command command)
          (last-command-event (aref (kbd key) (1- (length (kbd key))))))
      (call-interactively command))))

(defun demo--step (steps)
  "Play the first of STEPS and schedule the rest."
  (when steps
    (let* ((item (car steps))
           (rest (cdr steps))
           (pause (if (numberp (car rest)) (car rest) 0.3)))
      (when (numberp (car rest)) (setq rest (cdr rest)))
      (if (numberp item)
          (run-at-time item nil #'demo--step rest)
        (run-at-time pause nil #'demo--step rest)
        (condition-case err
            (pcase item
              (`(:char ,c) (setq unread-command-events
                                 (append unread-command-events (list c))))
              (`(:key ,k) (setq unread-command-events
                                (append unread-command-events
                                        (listify-key-sequence (kbd k)))))
              (`(:run ,k) (demo--run-key k nil))
              (`(:run ,k ,prefix) (demo--run-key k prefix))
              (`(:say ,text) (demo-say text))
              (`(:eval ,form) (eval form t)))
          (quit nil)
          (error (message "demo step %S: %s" item (error-message-string err))))))))

(defun demo-play (steps)
  "Play STEPS, a list, on timers.
A string is typed, (:key K) presses K, (:run K [PREFIX]) runs what K is
bound to in the selected window, (:say TEXT) is a caption, (:eval FORM)
evaluates FORM, and a number after an item is how long to wait after it."
  (run-at-time 0.2 nil #'demo--step (demo--expand steps))
  nil)

;;;; Setting up

(declare-function demo-scene-build "the scene")

(defun demo-setup ()
  "Lay the frame out and build the scene, once there is a frame to lay out."
  (if (not (and (display-graphic-p) (frame-visible-p (selected-frame))))
      (run-at-time 0.5 nil #'demo-setup)
    ;; The init leaves the title empty, and the recorder finds the window
    ;; by its title
    (set-frame-parameter nil 'name demo-frame-title)
    (set-frame-parameter nil 'title demo-frame-title)
    (demo-frame)
    (demo-scene-build)
    (unless demo-pin-timer
      (setq demo-pin-timer (run-at-time 1 0.5 #'demo-pin)))
    (with-temp-file demo-ready-file
      (insert (format "%s\n%s\n" (locate-library "enghi") enghi-server-url)))))

(demo-load-configuration)

(setq native-comp-async-report-warnings-errors 'silent
      warning-minimum-level :error
      inhibit-startup-screen t
      frame-title-format demo-frame-title
      minibuffer-message-timeout 10)

(setq server-name demo-server-name)
(require 'server)
(server-start)

(load demo-scene-file nil t)

(run-at-time 1 nil #'demo-setup)

(provide 'demo)
;;; demo.el ends here
