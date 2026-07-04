;;;; image-restore.lisp --- run inside the RESTORED image: create a fresh
;;;; terminal and confirm it works (libvterm reloaded, new libffi closures).
;;;;
;;;; The child's marker is computed at runtime ($((6*7)) => 42) so it can only
;;;; appear if the restored image really ran the child.  Loaded by
;;;; tests/image-test.sh via `sbcl --core <core>`.

(in-package #:revision-term)

(setf revision::*ui-thread* sb-thread:*current-thread*)

(defun %grid (tv)
  (with-output-to-string (out)
    (dotimes (r (tv-rows tv))
      (dotimes (c (tv-cols tv))
        (vterm-screen-get-cell (tv-vscreen tv) r c (tv-cell tv))
        (let ((code (cffi:mem-aref
                     (cffi:foreign-slot-pointer (tv-cell tv) '(:struct vterm-screen-cell) 'chars)
                     :uint32 0)))
          (write-char (if (or (zerop code) (>= code #x110000)) #\Space (code-char code)) out))))))

(let ((tv (make-instance 'terminal-view
                         :command '("/bin/sh" "-c" "printf RESTORED-$((6*7)); sleep 3"))))
  (setf (revision:view-bounds tv) (revision::make-trect 0 0 80 24))
  (terminal-start tv)
  (let ((deadline (+ (get-internal-real-time) (* 8 internal-time-units-per-second)))
        (seen nil))
    (loop until (or seen (> (get-internal-real-time) deadline)) do
      (revision::drain-ui-callbacks)
      (when (search "RESTORED-42" (%grid tv)) (setf seen t))
      (sleep 0.03))
    (terminal-shutdown tv)
    (format t "~&[restore] fresh terminal rendered child output: ~:[no~;RESTORED-42~]~%" seen)
    (uiop:quit (if seen 0 1))))
