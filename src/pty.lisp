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

;;; ioctl() is variadic (`int ioctl(int, unsigned long, ...)`), and on Apple
;;; arm64 the AAPCS passes variadic arguments on the stack -- so a plain
;;; `cffi:foreign-funcall`, which passes the pointer in a register, is silently
;;; ignored by the kernel (verified: the resize never reaches the child).  We
;;; therefore build a proper *variadic* libffi call interface (ffi_prep_cif_var,
;;; which cffi-libffi does not expose) and call ioctl through it.  This is the
;;; same libffi path cffi-libffi already uses for struct-by-value calls, just
;;; parameterised as variadic.

(cffi:defcfun ("ffi_prep_cif_var" %ffi-prep-cif-var) cffi::status
  (cif :pointer) (abi cffi::abi)
  (nfixedargs :unsigned-int) (ntotalargs :unsigned-int)
  (rtype :pointer) (atypes :pointer))

(defvar *ioctl-cif* nil "Cached variadic call interface for ioctl(int, ulong, ptr).")

(defun ioctl-cif ()
  (or *ioctl-cif*
      (let* ((types '(:int :unsigned-long :pointer))
             (cif (cffi:foreign-alloc '(:struct cffi::ffi-cif)))
             (atypes (cffi:foreign-alloc :pointer :count 3)))
        (loop for ty in types for i from 0
              do (setf (cffi:mem-aref atypes :pointer i)
                       (cffi::make-libffi-type-descriptor (cffi::parse-type ty))))
        (unless (eql :ok (%ffi-prep-cif-var
                          cif :default-abi 2 3          ; 2 fixed args, 3 total
                          (cffi::make-libffi-type-descriptor (cffi::parse-type :int))
                          atypes))
          (error "ffi_prep_cif_var failed for ioctl"))
        (setf *ioctl-cif* cif))))

(defun ioctl3 (fd request ptr)
  "Call ioctl(FD, REQUEST, PTR) with the correct variadic ABI.  Returns the
ioctl result, or NIL if the variadic machinery is unavailable (falls back to a
plain call, which is correct on ABIs that pass varargs in registers)."
  (handler-case
      (let ((cif (ioctl-cif)))
        (cffi:with-foreign-objects ((afd :int) (areq :unsigned-long) (aptr :pointer)
                                    (rv :int) (av :pointer 3))
          (setf (cffi:mem-ref afd :int) fd
                (cffi:mem-ref areq :unsigned-long) request
                (cffi:mem-ref aptr :pointer) ptr
                (cffi:mem-aref av :pointer 0) afd
                (cffi:mem-aref av :pointer 1) areq
                (cffi:mem-aref av :pointer 2) aptr)
          (cffi::libffi/call cif (cffi:foreign-symbol-pointer "ioctl") rv av)
          (cffi:mem-ref rv :int)))
    (error ()
      (cffi:foreign-funcall "ioctl" :int fd :unsigned-long request :pointer ptr :int))))

(defun set-winsize (fd rows cols)
  "Tell the kernel the pty is ROWS x COLS (delivers SIGWINCH to the child), via
a variadic-correct ioctl(TIOCSWINSZ)."
  (when (and fd (>= fd 0) (plusp rows) (plusp cols))
    (cffi:with-foreign-object (ws '(:struct winsize))
      (setf (cffi:foreign-slot-value ws '(:struct winsize) 'row) rows
            (cffi:foreign-slot-value ws '(:struct winsize) 'col) cols
            (cffi:foreign-slot-value ws '(:struct winsize) 'xpixel) 0
            (cffi:foreign-slot-value ws '(:struct winsize) 'ypixel) 0)
      (ioctl3 fd +tiocswinsz+ ws))))

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

(defun reap-child (pty)
  "Non-blocking waitpid: if the child has exited, reap it and return its exit
code (or 128+signal if it was killed); NIL if not yet dead / already reaped.
Marks the pty's pid consumed so PTY-CLOSE won't wait on it again."
  (when (and pty (> (pty-pid pty) 0))
    (cffi:with-foreign-object (st :int)
      (let ((r (cffi:foreign-funcall "waitpid" :int (pty-pid pty)
                                     :pointer st :int 1 :int)))   ; WNOHANG = 1
        (when (> r 0)
          (setf (pty-pid pty) -1)
          (let ((s (cffi:mem-ref st :int)))
            (if (zerop (logand s #x7f))                 ; WIFEXITED
                (logand (ash s -8) #xff)                ; WEXITSTATUS
                (+ 128 (logand s #x7f)))))))))          ; killed by a signal

;;; --- non-blocking-ish read / write on the master fd -------------------------

(defun pty-read (fd buf max)
  "read(2) up to MAX bytes from FD into the foreign BUF.  Returns the byte
count (0 on EOF, negative on error)."
  (cffi:foreign-funcall "read" :int fd :pointer buf :unsigned-long max :long))

(defun pty-write (fd buf len)
  "write(2) LEN bytes of the foreign BUF to FD.  Returns bytes written."
  (cffi:foreign-funcall "write" :int fd :pointer buf :unsigned-long len :long))
