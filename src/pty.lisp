;;;; pty.lisp --- spawn a child process on a pseudo-terminal.
;;;;
;;;; `forkpty' does the hard part: allocate a pty pair, fork, and in the child
;;;; make the slave the controlling terminal (setsid + TIOCSCTTY + dup2 onto
;;;; 0/1/2).  We hand it an initial window size and, in the child, immediately
;;;; `execve' the requested command -- doing NO Lisp allocation between fork and
;;;; exec (argv/envp are built in the parent and inherited), which is the safe
;;;; way to fork a threaded SBCL.
;;;;
;;;; forkpty lives in libSystem on macOS and libutil on Linux (loaded below).

(in-package #:revision-term)

(cffi:define-foreign-library libutil
  (:darwin (:default "libSystem"))            ; forkpty is in libSystem on macOS
  (:unix   (:or "libutil.so.1" "libutil.so"))
  (t (:default "libutil")))

(defun ensure-libutil ()
  (ignore-errors
   (unless (cffi:foreign-library-loaded-p 'libutil)
     (cffi:use-foreign-library libutil))))

;;; --- window size ------------------------------------------------------------

(cffi:defcstruct (winsize :conc-name ws-)
  (row    :unsigned-short)
  (col    :unsigned-short)
  (xpixel :unsigned-short)
  (ypixel :unsigned-short))

;; TIOCSWINSZ is an _IOW('t',103,struct winsize); its numeric value differs by
;; platform.  (struct winsize is identical everywhere, so we define it above.)
(defconstant +tiocswinsz+
  #+darwin #x80087467
  #+linux  #x5414
  #-(or darwin linux) #x80087467)

(defun set-winsize (fd rows cols)
  "Tell the kernel the pty is ROWS x COLS (delivers SIGWINCH to the child).
Best-effort: ioctl is variadic, so on some ABIs the pointer arg may not
propagate -- the initial size (set at spawn) is unaffected."
  (when (and fd (>= fd 0) (plusp rows) (plusp cols))
    (cffi:with-foreign-object (ws '(:struct winsize))
      (setf (cffi:foreign-slot-value ws '(:struct winsize) 'row) rows
            (cffi:foreign-slot-value ws '(:struct winsize) 'col) cols
            (cffi:foreign-slot-value ws '(:struct winsize) 'xpixel) 0
            (cffi:foreign-slot-value ws '(:struct winsize) 'ypixel) 0)
      (cffi:foreign-funcall "ioctl" :int fd :unsigned-long +tiocswinsz+
                                    :pointer ws :int))))

;;; --- building argv / envp (in the parent, inherited by the child) -----------

(defun %foreign-string-array (strings)
  "Allocate a NULL-terminated C array of freshly malloc'd C strings from the
Lisp list STRINGS.  Returns the char** pointer; free with %free-string-array."
  (let* ((n (length strings))
         (arr (cffi:foreign-alloc :pointer :count (1+ n))))
    (loop for s in strings for i from 0
          do (setf (cffi:mem-aref arr :pointer i) (cffi:foreign-string-alloc s)))
    (setf (cffi:mem-aref arr :pointer n) (cffi:null-pointer))
    arr))

(defun %free-string-array (arr)
  (unless (cffi:null-pointer-p arr)
    (loop for i from 0
          for p = (cffi:mem-aref arr :pointer i)
          until (cffi:null-pointer-p p)
          do (cffi:foreign-string-free p))
    (cffi:foreign-free arr)))

(defun %child-environment ()
  "The current environment as VAR=VALUE strings, with TERM / COLORTERM forced to
values a modern terminal program expects."
  (let ((keep (remove-if (lambda (e)
                           (let ((p (position #\= e)))
                             (and p (member (subseq e 0 p)
                                            '("TERM" "COLORTERM") :test #'string=))))
                         (sb-ext:posix-environ))))
    (list* "TERM=xterm-256color" "COLORTERM=truecolor" keep)))

;;; --- spawn ------------------------------------------------------------------

(defstruct pty pid master argv envp)

(defun spawn-pty (command rows cols)
  "Fork COMMAND (a list of strings; COMMAND[0] must be an absolute program
path) on a fresh pty sized ROWS x COLS.  Returns a PTY (pid + master fd), or
signals an error.  The child execve's COMMAND and never returns to Lisp."
  (ensure-libutil)
  (let* ((argv (%foreign-string-array command))
         (envp (%foreign-string-array (%child-environment)))
         (path (first command)))
    (cffi:with-foreign-objects ((amaster :int) (ws '(:struct winsize)))
      (setf (cffi:foreign-slot-value ws '(:struct winsize) 'row) rows
            (cffi:foreign-slot-value ws '(:struct winsize) 'col) cols
            (cffi:foreign-slot-value ws '(:struct winsize) 'xpixel) 0
            (cffi:foreign-slot-value ws '(:struct winsize) 'ypixel) 0)
      (let ((pid (cffi:foreign-funcall "forkpty"
                                       :pointer amaster
                                       :pointer (cffi:null-pointer)   ; slave name (unused)
                                       :pointer (cffi:null-pointer)   ; termios (defaults)
                                       :pointer ws
                                       :int)))
        (cond
          ((zerop pid)
           ;; --- child: exec the command, allocating nothing.  Only async-safe
           ;; foreign calls here (argv/envp are already built & inherited). ---
           (cffi:with-foreign-string (cpath path)
             (cffi:foreign-funcall "execve" :pointer cpath :pointer argv
                                            :pointer envp :int))
           (cffi:foreign-funcall "_exit" :int 127 :void)) ; exec failed
          ((< pid 0)
           (%free-string-array argv)
           (%free-string-array envp)
           (error "forkpty failed"))
          (t
           (make-pty :pid pid
                     :master (cffi:mem-ref amaster :int)
                     :argv argv :envp envp)))))))

(defun pty-close (pty)
  "Close the master fd, hang up + reap the child, and free argv/envp."
  (when pty
    (let ((fd (pty-master pty)) (pid (pty-pid pty)))
      (when (and fd (>= fd 0))
        (cffi:foreign-funcall "close" :int fd :int)
        (setf (pty-master pty) -1))
      (when (and pid (> pid 0))
        (cffi:foreign-funcall "kill" :int pid :int 1 :int)              ; SIGHUP
        (cffi:foreign-funcall "waitpid" :int pid
                              :pointer (cffi:null-pointer) :int 0 :int))
      (when (pty-argv pty) (%free-string-array (pty-argv pty)) (setf (pty-argv pty) nil))
      (when (pty-envp pty) (%free-string-array (pty-envp pty)) (setf (pty-envp pty) nil)))))

;;; --- non-blocking-ish read / write on the master fd -------------------------

(defun pty-read (fd buf max)
  "read(2) up to MAX bytes from FD into the foreign BUF.  Returns the byte
count (0 on EOF, negative on error)."
  (cffi:foreign-funcall "read" :int fd :pointer buf :unsigned-long max :long))

(defun pty-write (fd buf len)
  "write(2) LEN bytes of the foreign BUF to FD.  Returns bytes written."
  (cffi:foreign-funcall "write" :int fd :pointer buf :unsigned-long len :long))
