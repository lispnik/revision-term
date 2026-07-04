;;;; run-shell.lisp --- the smallest standalone revision-term program.
;;;;
;;;; Runs your $SHELL full-screen inside a revision terminal window.  Run it with
;;;;
;;;;     sbcl --script examples/run-shell.lisp
;;;;
;;;; (from the project root, so ../setup.lisp can find the sibling checkouts).
;;;; Ctrl-\ closes the window; Shift-PageUp/PageDown scroll the scrollback.

(let* ((here (or *load-pathname* *default-pathname-defaults*))
       (root (make-pathname :directory (butlast (pathname-directory here))
                            :name nil :type nil :defaults here)))
  (load (merge-pathnames "setup.lisp" root)))
(asdf:load-system :revision-term)

;; Run the user's shell.  Pass any command instead, e.g.
;;   (revision-term:run-terminal :command '("/usr/bin/vi"))
;;   (revision-term:run-terminal :command '("/bin/sh" "-c" "top"))
(revision-term:run-terminal)
