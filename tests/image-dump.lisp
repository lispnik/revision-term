;;;; image-dump.lisp --- start a live terminal, then dump a Lisp image.
;;;;
;;;; This only succeeds if the image-dump hook tears the terminal down first:
;;;; save-lisp-and-die requires a single thread, and a live terminal has a
;;;; running reader thread that would otherwise block the dump.  Loaded by
;;;; tests/image-test.sh; the core path comes from $RT_IMAGE_CORE.

(in-package #:revision-term)

(setf revision::*ui-thread* sb-thread:*current-thread*)

(let ((tv (make-instance 'terminal-view :command '("/bin/sh" "-c" "sleep 60"))))
  (setf (revision:view-bounds tv) (revision::make-trect 0 0 80 24))
  (terminal-start tv)
  (assert (and (tv-reader tv) (sb-thread:thread-alive-p (tv-reader tv))))
  (format t "~&[dump] terminal live (~d thread(s)); dumping image...~%"
          (length (sb-thread:list-all-threads))))

;; uiop:dump-image runs the registered image-dump hooks (which shut the terminal
;; down) and then save-lisp-and-die.  Without the hook this errors on the live
;; reader thread; with it, the core is written and the process exits 0.
(uiop:dump-image (uiop:getenv "RT_IMAGE_CORE"))
