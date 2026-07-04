;;;; revision-term.asd --- a reusable libvterm-backed terminal widget for the
;;;; `revision' text-mode UI framework.
;;;;
;;;; Depends on:
;;;;   revision                 -- the CLOS-native TUI framework (sibling checkout)
;;;;   cffi / cffi-libffi       -- the FFI
;;;;   cffi-callback-closures   -- runtime C-callable closures for libvterm's
;;;;                               per-instance screen callbacks (sibling checkout)
;;;;
;;;; The sibling systems are put on the ASDF registry by ../setup.lisp; load that
;;;; first (or `make run'), then (asdf:load-system :revision-term).

(asdf:defsystem "revision-term"
  :description "A libvterm-backed terminal-window widget for the revision framework."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("revision" "cffi" "cffi-callback-closures")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "vterm")
                             (:file "pty")
                             (:file "terminal")
                             (:file "app"))))
  :in-order-to ((test-op (test-op "revision-term/test"))))

(asdf:defsystem "revision-term/test"
  :description "Headless tests for revision-term (no interactive terminal needed)."
  :depends-on ("revision-term")
  :components ((:module "tests"
                :serial t
                :components ((:file "tests"))))
  :perform (test-op (o c)
             (uiop:symbol-call :revision-term-tests '#:run)))
