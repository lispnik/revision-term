;;;; setup.lisp --- put the sibling `revision' and `cffi-callback-closures'
;;;; checkouts (and cffi-callback-closures' bundled ocicl dependencies) on the
;;;; ASDF registry, so (asdf:load-system :revision-term) just works.
;;;;
;;;; Usage:   sbcl --load setup.lisp --eval '(asdf:load-system :revision-term)'
;;;;
;;;; Layout assumed (siblings under one parent directory):
;;;;   .../revision-term/            <- this project
;;;;   .../revision/                 <- the framework
;;;;   .../cffi-callback-closures/   <- the closure library (bundles cffi in ocicl/)

(require :asdf)

(let* ((here (or *load-truename* *load-pathname* *default-pathname-defaults*))
       (root (make-pathname :directory (butlast (pathname-directory here))
                            :name nil :type nil :defaults here))
       (revision (merge-pathnames "revision/" root))
       (ccc      (merge-pathnames "cffi-callback-closures/" root)))
  (flet ((reg (dir)
           (when (probe-file dir)
             (pushnew (truename dir) asdf:*central-registry* :test #'equal)))
         (reg-tree (dir)
           ;; register every directory that directly contains a .asd file
           (dolist (asd (directory (merge-pathnames "**/*.asd" dir)))
             (pushnew (make-pathname :directory (pathname-directory asd)
                                     :name nil :type nil)
                      asdf:*central-registry* :test #'equal))))
    ;; this project
    (reg (make-pathname :directory (pathname-directory here) :name nil :type nil :defaults here))
    ;; the framework (no external deps)
    (reg revision)
    ;; cffi-callback-closures + its bundled cffi / cffi-libffi / bordeaux-threads
    (reg-tree (merge-pathnames "ocicl/" ccc))   ; deps first, so their cffi wins
    (reg ccc)))

(format t "~&; revision-term registry ready.  (asdf:load-system :revision-term)~%")
