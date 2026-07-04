;;;; demo.lisp --- run the self-driving desktop showcase standalone.
;;;;
;;;;     sbcl --script examples/demo.lisp
;;;;
;;;; (For a clean recording, examples/record-demo.py builds a saved core so
;;;; startup is instant and silent; this script is the from-source path.)

(let* ((here (or *load-pathname* *default-pathname-defaults*))
       (root (make-pathname :directory (butlast (pathname-directory here))
                            :name nil :type nil :defaults here)))
  (load (merge-pathnames "setup.lisp" root))
  (asdf:load-system :revision-term)
  (load (merge-pathnames "examples/demo-defs.lisp" root)))

(funcall (intern "RUN-DEMO" :revision-term))
