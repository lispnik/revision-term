;;;; app.lisp --- window builder + entry points.
;;;;
;;;; MAKE-TERMINAL follows the same contract as the framework's MAKE-REPL:
;;;; it returns (values WINDOW FOCUS OPEN), where OPEN (run after layout) starts
;;;; the child process and returns a cleanup thunk.  So a terminal can be hosted
;;;; full-screen with RUN-TERMINAL, or dropped into a desktop by any app that
;;;; wants an embedded shell.

(in-package #:revision-term)

(defclass terminal-window (window) ()
  (:metaclass reactive-class))

(defun make-terminal (&key command (title " Terminal ") on-exit
                           (status " Ctrl-\\ close · Shift-PgUp/PgDn scroll back "))
  "Build a terminal window running COMMAND (a list of strings; COMMAND[0] must
be an absolute path -- defaults to $SHELL).  Returns (values WINDOW FOCUS OPEN),
where OPEN starts the child and returns a cleanup thunk that stops it."
  (let* ((win (make-instance 'terminal-window :title title :keymap *global-keys*))
         (tv  (make-instance 'terminal-view :name 'terminal :keymap *terminal-keys*
                             :command command :on-exit on-exit))
         (body (make-instance 'stack)))
    (add-laid body tv :fill)
    (when status
      (add-laid body (make-instance 'static-text :role :status :text status) 1))
    (add-subview win body)
    (values win tv
            (lambda (s)
              (declare (ignore s))
              (terminal-start tv)
              (lambda () (terminal-shutdown tv))))))

(defun run-terminal (&key command)
  "Run a terminal full-screen until the child exits or Ctrl-\\ is pressed."
  (multiple-value-bind (win focus open) (make-terminal :command command)
    (run-view win :focus focus :open open)))
