;;;; tests.lisp --- headless tests (no interactive terminal required).
;;;;
;;;; Exercises the whole non-UI stack: the libvterm bindings + by-value
;;;; get_cell, and a real PTY round-trip driving a child process through the
;;;; TERMINAL-VIEW exactly as the UI would (minus the screen).

(defpackage #:revision-term-tests
  (:use #:cl #:revision-term)
  (:export #:run))

(in-package #:revision-term-tests)

(defvar *failures* 0)

(defmacro check (form &optional (desc nil))
  `(let ((ok (ignore-errors ,form)))
     (format t "~&  [~:[FAIL~;pass~]] ~a~%" ok (or ,desc ',form))
     (unless ok (incf *failures*))))

;;; --- 1. headless libvterm: write bytes, read the grid back ------------------

(defun read-cell-char (screen cell row col)
  (revision-term::vterm-screen-get-cell screen row col cell)
  (let ((code (cffi:mem-aref
               (cffi:foreign-slot-pointer
                cell '(:struct revision-term::vterm-screen-cell) 'revision-term::chars)
               :uint32 0)))
    (if (zerop code) #\Space (code-char code))))

(defun test-headless-vterm ()
  (format t "~&headless libvterm (by-value get_cell + cell layout):~%")
  (revision-term::ensure-libvterm)
  (let ((vt (revision-term::vterm-new 24 80)))
    (unwind-protect
         (progn
           (revision-term::vterm-set-utf8 vt 1)
           (let ((screen (revision-term::vterm-obtain-screen vt)))
             (revision-term::vterm-screen-reset screen 1)
             (let ((bytes (map '(vector (unsigned-byte 8)) #'char-code "hello")))
               (cffi:with-foreign-object (buf :unsigned-char (length bytes))
                 (dotimes (i (length bytes))
                   (setf (cffi:mem-aref buf :unsigned-char i) (aref bytes i)))
                 (revision-term::vterm-input-write vt buf (length bytes))))
             (cffi:with-foreign-object (cell '(:struct revision-term::vterm-screen-cell))
               (let ((got (coerce (loop for c below 5
                                        collect (read-cell-char screen cell 0 c))
                                  'string)))
                 (format t "    row 0 = ~s~%" got)
                 (check (string= got "hello") "grid reads back \"hello\"")))))
      (revision-term::vterm-free vt))))

;;; --- 2. real PTY round-trip through a TERMINAL-VIEW -------------------------

(defun grid-text (tv)
  "The full emulated grid as one newline-joined string (trailing blanks kept)."
  (let ((screen (revision-term::tv-vscreen tv))
        (cell (revision-term::tv-cell tv))
        (rows (revision-term::tv-rows tv))
        (cols (revision-term::tv-cols tv)))
    (with-output-to-string (out)
      (dotimes (r rows)
        (dotimes (c cols) (write-char (read-cell-char screen cell r c) out))
        (terpri out)))))

(defun test-pty-roundtrip ()
  (format t "~&real PTY round-trip (spawn a child, read its output):~%")
  ;; drive the bridge ourselves: make US the UI thread, so the reader thread
  ;; enqueues and we drain here (exactly the real control flow, sans screen).
  (let ((revision::*ui-thread* sb-thread:*current-thread*)
        (tv (make-instance 'revision-term::terminal-view
                           :command '("/bin/sh" "-c" "printf 'SMOKE_OK_42\\n'; sleep 2"))))
    (setf (revision:view-bounds tv) (revision::make-trect 0 0 80 24))
    (revision-term::terminal-start tv)
    (unwind-protect
         (let ((deadline (+ (get-internal-real-time)
                            (* 5 internal-time-units-per-second)))
               (seen nil))
           (loop until (or seen (> (get-internal-real-time) deadline)) do
             (revision::drain-ui-callbacks)
             (when (search "SMOKE_OK_42" (grid-text tv)) (setf seen t))
             (sleep 0.05))
           (check seen "child output \"SMOKE_OK_42\" appeared on the grid")
           (check (integerp (terminal-child-pid tv)) "child pid is known"))
      (revision-term::terminal-shutdown tv))))

;;; --- runner -----------------------------------------------------------------

(defun run ()
  (setf *failures* 0)
  (test-headless-vterm)
  (test-pty-roundtrip)
  (format t "~2&~[ALL TESTS PASSED~:;~:*~d TEST(S) FAILED~]~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  t)
