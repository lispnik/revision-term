;;;; package.lisp --- the REVISION-TERM package.
;;;;
;;;; A reusable terminal-emulator widget for the `revision' text-mode UI
;;;; framework.  It emulates a terminal with libvterm (via CFFI), drives a real
;;;; child process over a PTY, and renders the emulated screen into a revision
;;;; VIEW so a live shell (or any terminal program) can live inside a revision
;;;; window -- and be embedded in any revision application.

(defpackage #:revision-term
  (:use #:cl #:revision)
  (:import-from #:cffi-callback-closures
                #:make-foreign-callback
                #:free-foreign-callback)
  (:documentation "A libvterm-backed terminal widget for the revision framework.")
  (:export
   ;; the reusable widget
   #:terminal-view
   #:terminal-window
   #:make-terminal
   #:run-terminal
   ;; introspection / control
   #:terminal-alive-p
   #:terminal-send-string
   #:terminal-child-pid
   #:*terminal-keys*))
