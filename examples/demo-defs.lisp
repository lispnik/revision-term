;;;; demo-defs.lisp --- the self-driving desktop showcase (scene + run-demo).
;;;; Loaded into a saved core by examples/record-demo.py, and by examples/demo.lisp.

(in-package #:revision-term)

;;; --- helpers over the desktop -----------------------------------------------

(defun demo-open-terminal (dt command title)
  "Open COMMAND as a managed terminal window on desktop DT; return its view."
  (multiple-value-bind (win tv open) (make-terminal :command command :title title :status nil)
    (revision::dt-add dt win tv open nil (revision::dt-cascade-rect dt))
    (revision::dt-refocus dt) (invalidate dt)
    tv))

(defun demo-open-repl (dt)
  "Open a native revision Lisp REPL window; return it."
  (multiple-value-bind (win focus open) (revision::make-repl :cl-user)
    (revision::dt-add dt win focus open nil (revision::dt-cascade-rect dt))
    (revision::dt-refocus dt) (invalidate dt)
    win))

(defun demo-type (tv string)
  "Type STRING then Enter into terminal TV (on the UI thread)."
  (run-on-ui (lambda () (terminal-send-string tv string) (terminal-send-key tv :enter 0))))

;;; --- the scripted scene -----------------------------------------------------

;; Shell commands (the \\033 reach the shell's printf as ESC).
(defparameter *cmd-banner*
  "printf '\\033[1;38;2;120;200;255mrevision-term\\033[0m \\033[2m— a terminal, in a window\\033[0m\\n'")
(defparameter *cmd-gradient*
  "for i in $(seq 0 46); do printf \"\\033[48;2;$((i*5));$((90+i*2));$((235-i*4))m \"; done; printf \"\\033[0m\\n\"")
(defparameter *cmd-styles*
  "printf '\\033[1mbold\\033[0m \\033[3mitalic\\033[0m \\033[4munderline\\033[0m \\033[9mstrike\\033[0m \\033[7mreverse\\033[0m\\n'")
(defparameter *cmd-cube*
  "for i in $(seq 16 231); do printf \"\\033[48;5;${i}m \"; [ $(( (i-15) % 36 )) -eq 0 ] && printf \"\\033[0m\\n\"; done; printf \"\\033[0m\\n\"")
(defparameter *cmd-seq* "seq 1 60")

(defparameter *cmd-clock*
  "while :; do printf \"\\r\\033[38;2;120;230;150m %s \\033[0m running…\" \"$(date +%H:%M:%S)\"; sleep 1; done")

(defun demo-autopilot (dt)
  "Drive the scene on a background thread; each step posts to the UI thread."
  (sb-thread:make-thread
   (lambda ()
     (let (term repl)
       (flet ((wait (s) (sleep s))
              (ui (fn) (run-on-ui fn)))
         (wait 1.2)
         ;; 1. a terminal window opens; show off true-colour + styles up front,
         ;;    while it is the only window (fully visible).
         (ui (lambda () (setf term (demo-open-terminal dt '("/bin/sh") " sh — terminal "))))
         (wait 1.4)
         (demo-type term *cmd-banner*)   (wait 1.1)
         (demo-type term *cmd-gradient*) (wait 1.1)   ; 24-bit colour, in a window
         (demo-type term *cmd-cube*)     (wait 1.3)   ; 256-colour cube
         (demo-type term *cmd-styles*)   (wait 1.6)   ; bold/italic/underline/reverse/…
         ;; 2. a native revision Lisp REPL opens beside it; tile them side by side.
         (ui (lambda () (setf repl (demo-open-repl dt))))
         (wait 0.9)
         (ui (lambda () (revision::dt-tile dt) (revision::dt-refocus dt)))
         (wait 1.2)
         (ui (lambda () (repl-submit-string repl "(loop for i below 8 collect (expt 2 i))")))
         (wait 2.0)
         ;; 3. scroll the terminal's scrollback back through the colourful history.
         (ui (lambda () (terminal-scroll-by term 12)))  (wait 1.7)
         (ui (lambda () (terminal-scroll-by term -20))) (wait 1.1)
         ;; 4. a second terminal runs a live clock; tile all three.
         (ui (lambda () (demo-open-terminal dt (list "/bin/sh" "-c" *cmd-clock*) " sh — clock ")))
         (wait 0.9)
         (ui (lambda () (revision::dt-tile dt) (revision::dt-refocus dt)))
         (wait 6.0))))                   ; hold the final scene (the recorder caps duration)
   :name "demo-autopilot"))

;;; --- a desktop loop (like RUN-DESKTOP, but seeded + autopiloted) -------------

(defun run-demo ()
  (revision:with-screen (s)
    (let ((dt (make-instance 'revision::desktop)))
      (setf (revision::dt-menubar dt)
            (make-instance 'revision:menu-bar :menus (revision::%desktop-menus dt))
            (revision::dt-statusbar dt)
            (make-instance 'revision:status-bar :provider (lambda () (revision::dt-status-items dt))))
      (revision::layout dt (revision::rect 0 0 (revision:screen-width s) (revision:screen-height s)))
      (setf (revision:context-root revision:*context*) dt revision:*desktop* dt
            revision:*ui-thread* sb-thread:*current-thread*
            revision::*app-done* nil (revision:context-dirty revision:*context*) t)
      (demo-autopilot dt)
      (unwind-protect
           (loop until revision::*app-done* do
             (revision:drain-ui-callbacks)
             (when (revision:context-dirty revision:*context*)
               (revision:hide-cursor s)
               (revision::draw dt) (revision:flush-screen s)
               (setf (revision:context-dirty revision:*context*) nil))
             (revision::pump-input s 0.05)
             (let ((tev (revision::screen-next-event s)))
               (when tev (let ((ev (revision::translate tev)))
                           (when ev (revision::handle-event dt ev))))))
        (dolist (win (revision::dt-windows dt))
          (when (revision::window-cleanup win) (ignore-errors (funcall (revision::window-cleanup win)))))))))

