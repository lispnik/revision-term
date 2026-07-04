;;;; terminal.lisp --- the reusable TERMINAL-VIEW / TERMINAL-WINDOW widgets.
;;;;
;;;; A TERMINAL-VIEW is a revision VIEW that hosts a live child process:
;;;;
;;;;   child ──stdout──▶ pty master ──(reader thread: read only)──▶ run-on-ui
;;;;                                                                    │
;;;;   UI thread: vterm_input_write ◀────────────────────────────────┘
;;;;              │  (libvterm parses the ANSI stream and updates its grid)
;;;;              ▼
;;;;   draw: poll vterm_screen_get_cell for every visible cell ─▶ revision cells
;;;;
;;;;   keystroke ─▶ vterm_keyboard_* ─▶ (output closure) ─▶ pty master ─▶ child
;;;;
;;;; Everything that touches libvterm runs on the UI thread; the reader thread
;;;; only does the blocking read() syscall and hands bytes over via RUN-ON-UI,
;;;; so no locks are needed (the framework's "only the UI thread touches the
;;;; model" rule).
;;;;
;;;; libvterm's screen callbacks that carry per-instance state -- scrollback
;;;; (sb_pushline), cursor visibility (settermprop), resize, bell -- and the
;;;; output callback are libffi *closures* (cffi-callback-closures), each closing
;;;; over *this* terminal.  That is exactly the "N distinct callbacks, each with
;;;; its own data" case cffi:defcallback cannot express.

(in-package #:revision-term)

;;; --- the view ---------------------------------------------------------------

(defclass terminal-view (view)
  ((vt        :initform nil :accessor tv-vt)          ; VTerm*
   (vscreen   :initform nil :accessor tv-vscreen)     ; VTermScreen*
   (vstate    :initform nil :accessor tv-vstate)      ; VTermState*
   (rows      :initform 24  :accessor tv-rows)
   (cols      :initform 80  :accessor tv-cols)
   (pty       :initform nil :accessor tv-pty)
   (reader    :initform nil :accessor tv-reader)      ; reader thread
   (alive     :initform nil :accessor tv-alive)       ; child running?
   (cursor-visible :initform t :accessor tv-cursor-visible)
   ;; scrollback: a ring of packed-cell lines pushed off the top by the child.
   (history   :initform (make-array 0 :adjustable t :fill-pointer 0) :accessor tv-history)
   (max-history :initform 2000 :accessor tv-max-history)
   (scroll    :initform 0 :accessor tv-scroll)        ; rows scrolled back (0 = live)
   ;; foreign resources to free on shutdown
   (cell        :initform nil :accessor tv-cell)          ; reusable VTermScreenCell*
   (cbs-ptr     :initform nil :accessor tv-cbs-ptr)       ; VTermScreenCallbacks*
   (closures    :initform nil :accessor tv-closures)      ; list of ccc callbacks
   (blank-attr  :initform (make-attr 7 0) :accessor tv-blank-attr)
   ;; configuration
   (command   :initarg :command :initform nil :accessor tv-command)
   (on-exit   :initarg :on-exit :initform nil :accessor tv-on-exit))
  (:metaclass reactive-class))

(defmethod focusable-p ((tv terminal-view)) t)

(defun terminal-alive-p (tv) (tv-alive tv))
(defun terminal-child-pid (tv) (and (tv-pty tv) (pty-pid (tv-pty tv))))

;;; --- low-level cell writing (mirrors the kernel's %put-code) ----------------

(declaim (inline put-code))
(defun put-code (x y code attr)
  (when *screen*
    (screen-cell-set *screen* x y (revision::cell-make-code code attr))))

(defun blank-cell (tv) (revision::cell-make-code 32 (tv-blank-attr tv)))

;;; --- colour + cell translation ----------------------------------------------

(declaim (inline color-rgb))
(defun color-rgb (colp)
  "The (values R G B) of a VTermColor pointer (already resolved to RGB)."
  (values (cffi:foreign-slot-value colp '(:struct vterm-color) 'red)
          (cffi:foreign-slot-value colp '(:struct vterm-color) 'green)
          (cffi:foreign-slot-value colp '(:struct vterm-color) 'blue)))

(declaim (inline %brighten))
(defun %brighten (v) (min 255 (+ v 63)))

(defun cell->packed (tv cellp)
  "Translate the foreign VTermScreenCell at CELLP into (values CODE ATTR WIDTH),
where ATTR is a revision true-colour attribute.  Resolves the cell's fg/bg to
RGB (in place) and honours bold (brighten) + reverse (swap)."
  (let* ((screen (tv-vscreen tv))
         (chars  (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'chars))
         (code   (cffi:mem-aref chars :uint32 0))
         (width  (cffi:foreign-slot-value cellp '(:struct vterm-screen-cell) 'width))
         (attrs  (cffi:foreign-slot-value cellp '(:struct vterm-screen-cell) 'attrs))
         (boldp    (logbitp 0 attrs))
         (reversep (logbitp 5 attrs))
         (fgp (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'fg))
         (bgp (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'bg)))
    (vterm-screen-convert-color-to-rgb screen fgp)
    (vterm-screen-convert-color-to-rgb screen bgp)
    (multiple-value-bind (fr fg fb) (color-rgb fgp)
      (multiple-value-bind (br bg bb) (color-rgb bgp)
        (when boldp (setf fr (%brighten fr) fg (%brighten fg) fb (%brighten fb)))
        (when reversep (rotatef fr br) (rotatef fg bg) (rotatef fb bb))
        (values (if (zerop code) 32 code)
                (rgb-attr (pack-rgb fr fg fb) (pack-rgb br bg bb))
                (if (<= width 0) 1 width))))))

;;; --- scrollback (the sb_pushline closure calls this) ------------------------

(defun tv-push-history (tv cols cells)
  "Store a line of COLS cells (a VTermScreenCell array at CELLS) as packed
revision cells in the scrollback ring.  Runs on the UI thread."
  (let ((line (make-array (max 0 cols) :element-type '(unsigned-byte 53))))
    (dotimes (i (max 0 cols))
      (multiple-value-bind (code attr)
          (cell->packed tv (cffi:inc-pointer cells (* i +cell-size+)))
        (setf (aref line i) (revision::cell-make-code code attr))))
    (let ((h (tv-history tv)))
      (vector-push-extend line h)
      (when (> (length h) (tv-max-history tv))         ; drop the oldest line
        (let ((n (length h)))
          (dotimes (k (1- n)) (setf (aref h k) (aref h (1+ k))))
          (decf (fill-pointer h))))
      (when (plusp (tv-scroll tv))                     ; keep the viewport stable
        (setf (tv-scroll tv) (min (length h) (1+ (tv-scroll tv))))))))

;;; --- the libvterm callbacks, as per-instance libffi closures ----------------

(defun %set-color (colp r g b)
  (setf (cffi:foreign-slot-value colp '(:struct vterm-color) 'type) 0   ; VTERM_COLOR_RGB
        (cffi:foreign-slot-value colp '(:struct vterm-color) 'red)   r
        (cffi:foreign-slot-value colp '(:struct vterm-color) 'green) g
        (cffi:foreign-slot-value colp '(:struct vterm-color) 'blue)  b))

(defun %install-callbacks (tv)
  "Mint this terminal's libvterm callbacks as libffi closures (each closes over
TV), stash them in a VTermScreenCallbacks struct, and register it.  Also install
the output callback that pipes the child's replies + our keystrokes to the pty."
  (let* ((cbs (cffi:foreign-alloc '(:struct vterm-screen-callbacks)))
         (settermprop
           (make-foreign-callback
            (lambda (prop val user)
              (declare (ignore user))
              (when (= prop +prop-cursorvisible+)
                (setf (tv-cursor-visible tv) (/= 0 (cffi:mem-ref val :int))))
              1)
            :int '(:int :pointer :pointer)))
         (bell
           (make-foreign-callback
            (lambda (user) (declare (ignore user)) 1)
            :int '(:pointer)))
         (resize
           (make-foreign-callback
            (lambda (rows cols user) (declare (ignore rows cols user)) 1)
            :int '(:int :int :pointer)))
         (sb-pushline
           (make-foreign-callback
            (lambda (cols cells user)
              (declare (ignore user))
              (tv-push-history tv cols cells)
              1)
            :int '(:int :pointer :pointer)))
         (output
           (make-foreign-callback
            (lambda (s len user)
              (declare (ignore user))
              (let ((pty (tv-pty tv)))
                (when (and pty (>= (pty-master pty) 0))
                  (pty-write (pty-master pty) s len)))
              (values))
            :void '(:pointer :unsigned-long :pointer))))
    ;; by-value callbacks (damage/moverect/movecursor) stay NULL -- we poll.
    (macrolet ((slot (name) `(cffi:foreign-slot-value cbs '(:struct vterm-screen-callbacks) ',name)))
      (setf (slot damage)      (cffi:null-pointer)
            (slot moverect)    (cffi:null-pointer)
            (slot movecursor)  (cffi:null-pointer)
            (slot settermprop) settermprop
            (slot bell)        bell
            (slot resize)      resize
            (slot sb-pushline) sb-pushline
            (slot sb-popline)  (cffi:null-pointer)
            (slot sb-clear)    (cffi:null-pointer)))
    (vterm-screen-set-callbacks (tv-vscreen tv) cbs (cffi:null-pointer))
    (vterm-output-set-callback (tv-vt tv) output (cffi:null-pointer))
    (setf (tv-cbs-ptr tv) cbs
          (tv-closures tv) (list settermprop bell resize sb-pushline output))))

;;; --- lifecycle --------------------------------------------------------------

(defun %bounds-size (tv)
  "The (values ROWS COLS) the view's bounds afford (at least 1x1)."
  (let ((b (view-bounds tv)))
    (if b
        (values (max 1 (rect-height b)) (max 1 (rect-width b)))
        (values 24 80))))

(defun terminal-start (tv)
  "Build the emulator, spawn the child, and start the reader thread.  Call this
after the view has been laid out (its bounds set the initial size)."
  (ensure-libvterm)
  (multiple-value-bind (rows cols) (%bounds-size tv)
    (setf (tv-rows tv) rows (tv-cols tv) cols)
    (let ((vt (vterm-new rows cols)))
      (when (cffi:null-pointer-p vt) (error "vterm_new failed"))
      (setf (tv-vt tv) vt)
      (vterm-set-utf8 vt 1)
      (setf (tv-vscreen tv) (vterm-obtain-screen vt)
            (tv-vstate tv)  (vterm-obtain-state vt))
      ;; default colours: light grey on near-black
      (cffi:with-foreign-objects ((fg '(:struct vterm-color)) (bg '(:struct vterm-color)))
        (%set-color fg 192 192 192) (%set-color bg 0 0 0)
        (vterm-state-set-default-colors  (tv-vstate tv) fg bg)
        (vterm-screen-set-default-colors (tv-vscreen tv) fg bg))
      (%install-callbacks tv)
      (vterm-screen-enable-altscreen (tv-vscreen tv) 1)
      (vterm-screen-reset (tv-vscreen tv) 1)
      (setf (tv-cell tv) (cffi:foreign-alloc '(:struct vterm-screen-cell)))
      ;; spawn the child on a pty of the same size
      (let* ((cmd (or (tv-command tv) (default-shell-command)))
             (pty (spawn-pty cmd rows cols)))
        (setf (tv-pty tv) pty (tv-alive tv) t)
        (terminal-start-reader tv)))))

(defun default-shell-command ()
  (list (or (sb-ext:posix-getenv "SHELL") "/bin/sh")))

(defun terminal-start-reader (tv)
  "Spawn the reader thread: it only reads bytes off the pty and hands them to
the UI thread; it never touches libvterm."
  (let ((fd (pty-master (tv-pty tv))))
    (setf (tv-reader tv)
          (sb-thread:make-thread
           (lambda ()
             (cffi:with-foreign-object (buf :unsigned-char 8192)
               (loop while (tv-alive tv) do
                 (let ((n (pty-read fd buf 8192)))
                   (cond
                     ((> n 0)
                      (let ((vec (make-array n :element-type '(unsigned-byte 8))))
                        (dotimes (i n) (setf (aref vec i) (cffi:mem-aref buf :unsigned-char i)))
                        (run-on-ui (lambda () (terminal-feed tv vec)))))
                     (t                                   ; EOF or error: child gone
                      (setf (tv-alive tv) nil)
                      (run-on-ui (lambda () (terminal-child-exited tv)))
                      (return)))))))
           :name "revision-term-reader"))))

(defun terminal-feed (tv vec)
  "UI thread: push VEC's bytes through libvterm (callbacks fire here), then ask
for a repaint."
  (when (tv-vt tv)
    (let ((n (length vec)))
      (cffi:with-foreign-object (buf :unsigned-char n)
        (dotimes (i n) (setf (cffi:mem-aref buf :unsigned-char i) (aref vec i)))
        (vterm-input-write (tv-vt tv) buf n)))
    (invalidate tv)))

(defun terminal-child-exited (tv)
  (setf (tv-alive tv) nil)
  (invalidate tv)
  (when (tv-on-exit tv) (ignore-errors (funcall (tv-on-exit tv) tv))))

(defun terminal-shutdown (tv)
  "Stop the child + reader and free every foreign resource.  Runs on the UI
thread (as run-view's cleanup)."
  (setf (tv-alive tv) nil)
  (when (tv-pty tv) (pty-close (tv-pty tv)))          ; closes fd -> unblocks reader
  (when (tv-reader tv)
    (ignore-errors (sb-thread:join-thread (tv-reader tv) :timeout 2))
    (setf (tv-reader tv) nil))
  (dolist (c (tv-closures tv)) (ignore-errors (free-foreign-callback c)))
  (setf (tv-closures tv) nil)
  (when (tv-cell tv)    (cffi:foreign-free (tv-cell tv))    (setf (tv-cell tv) nil))
  (when (tv-cbs-ptr tv) (cffi:foreign-free (tv-cbs-ptr tv)) (setf (tv-cbs-ptr tv) nil))
  (when (tv-vt tv)      (vterm-free (tv-vt tv))             (setf (tv-vt tv) nil)))

;;; --- resize (when the view's bounds change) ---------------------------------

(defun terminal-ensure-size (tv)
  (when (tv-vt tv)
    (multiple-value-bind (rows cols) (%bounds-size tv)
      (when (or (/= rows (tv-rows tv)) (/= cols (tv-cols tv)))
        (setf (tv-rows tv) rows (tv-cols tv) cols)
        (vterm-set-size (tv-vt tv) rows cols)
        (when (tv-pty tv) (set-winsize (pty-master (tv-pty tv)) rows cols))))))

;;; --- drawing ----------------------------------------------------------------

(defun tv-cursor-pos (tv)
  (cffi:with-foreign-object (pos '(:struct vterm-pos))
    (vterm-state-get-cursorpos (tv-vstate tv) pos)
    (values (cffi:foreign-slot-value pos '(:struct vterm-pos) 'row)
            (cffi:foreign-slot-value pos '(:struct vterm-pos) 'col))))

(defun %draw-live-row (tv ry live-row w ax ay)
  (let ((screen (tv-vscreen tv)) (cellp (tv-cell tv)) (gy (+ ay ry)) (x 0))
    (loop while (< x w) do
      (vterm-screen-get-cell screen live-row x cellp)
      (multiple-value-bind (code attr cw) (cell->packed tv cellp)
        (put-code (+ ax x) gy code attr)
        (when (and (= cw 2) (< (1+ x) w))
          (put-code (+ ax x 1) gy revision::+wide-cont+ attr))
        (incf x (max 1 cw))))))

(defun %draw-history-row (tv ry line w ax ay)
  (let ((gy (+ ay ry)) (n (length line)) (blank (blank-cell tv)))
    (dotimes (x w)
      (when *screen*
        (screen-cell-set *screen* (+ ax x) gy (if (< x n) (aref line x) blank))))))

(defun %draw-blank-row (tv ry w ax ay)
  (let ((gy (+ ay ry)) (blank (blank-cell tv)))
    (dotimes (x w) (when *screen* (screen-cell-set *screen* (+ ax x) gy blank)))))

(defmethod draw ((tv terminal-view))
  (terminal-ensure-size tv)
  (let* ((b (view-bounds tv)))
    (when (and b (tv-vscreen tv) (tv-cell tv))
      (let* ((ax (rect-ax b)) (ay (rect-ay b))
             (w (rect-width b)) (h (rect-height b))
             (hist (tv-history tv)) (nhist (length hist))
             (scroll (tv-scroll tv))
             ;; the viewport is bottom-aligned over (history ++ live screen);
             ;; TOP is the first virtual row shown.
             (top (- (+ nhist (tv-rows tv)) h scroll)))
        (dotimes (ry h)
          (let ((vr (+ top ry)))
            (cond
              ((< vr 0)       (%draw-blank-row tv ry w ax ay))
              ((< vr nhist)   (%draw-history-row tv ry (aref hist vr) w ax ay))
              (t              (%draw-live-row tv ry (- vr nhist) w ax ay)))))
        ;; the hardware cursor, only in the live view and while focused
        (when (and (zerop scroll) (tv-cursor-visible tv) (tv-alive tv)
                   (view-focused-p tv) *screen*)
          (multiple-value-bind (cr cc) (tv-cursor-pos tv)
            (let ((srow (- (+ nhist cr) top)))
              (when (and (<= 0 srow (1- h)) (<= 0 cc (1- w)))
                (set-cursor-pos *screen* (+ ax cc) (+ ay srow))
                (set-cursor-shape :block)
                (show-cursor *screen*)))))))))

;;; --- input ------------------------------------------------------------------

(defun %vmods (mods)
  "Translate revision modifier bits (shift=1 ctrl=2 alt=4) to libvterm's
(shift=1 alt=2 ctrl=4)."
  (logior (if (logtest mods revision:+md-shift+) +mod-shift+ 0)
          (if (logtest mods revision:+md-ctrl+)  +mod-ctrl+  0)
          (if (logtest mods revision:+md-alt+)   +mod-alt+   0)))

(defparameter *special-key-map*
  (list (cons :enter +key-enter+) (cons :tab +key-tab+) (cons :back +key-backspace+)
        (cons :esc +key-escape+) (cons :up +key-up+) (cons :down +key-down+)
        (cons :left +key-left+) (cons :right +key-right+) (cons :ins +key-ins+)
        (cons :del +key-del+) (cons :home +key-home+) (cons :end +key-end+)
        (cons :pgup +key-pageup+) (cons :pgdn +key-pagedown+)
        (cons :f1 (+ +key-function-0+ 1)) (cons :f2 (+ +key-function-0+ 2))
        (cons :f3 (+ +key-function-0+ 3)) (cons :f4 (+ +key-function-0+ 4))
        (cons :f5 (+ +key-function-0+ 5)) (cons :f6 (+ +key-function-0+ 6))
        (cons :f7 (+ +key-function-0+ 7)) (cons :f8 (+ +key-function-0+ 8))
        (cons :f9 (+ +key-function-0+ 9)) (cons :f10 (+ +key-function-0+ 10))))

(defun terminal-send-key (tv keysym mods)
  "Turn a revision keysym + modifiers into the bytes a terminal would send, via
libvterm (which emits them through our output closure to the pty)."
  (let ((vt (tv-vt tv)) (vmods (%vmods mods)))
    (cond
      ((null vt))
      ((keywordp keysym)
       (let ((k (cdr (assoc keysym *special-key-map*))))
         (when k (vterm-keyboard-key vt k vmods))))
      ((characterp keysym)
       (let ((code (char-code keysym)))
         (cond
           ;; a control character (Ctrl-A..Z arrives as code 1..26 + ctrl mod):
           ;; send the base letter WITH the ctrl modifier so libvterm re-encodes.
           ((and (logtest mods revision:+md-ctrl+) (<= 1 code 26))
            (vterm-keyboard-unichar vt (+ code 96) +mod-ctrl+))
           (t (vterm-keyboard-unichar vt code vmods))))))))

(defun terminal-send-string (tv string)
  "Feed STRING to the child as if typed (each character a key press)."
  (loop for ch across string do (terminal-send-key tv ch 0)))

(defun %page (tv) (let ((b (view-bounds tv))) (if b (max 1 (rect-height b)) 1)))

(defun terminal-scroll-by (tv n)
  (let ((maxs (length (tv-history tv))))
    (setf (tv-scroll tv) (max 0 (min maxs (+ (tv-scroll tv) n))))
    (invalidate tv)))

;; Reserved keys (bound on the view's own keymap) are performed as commands;
;; every other key is forwarded to the child.  A host app can supply its own
;; keymap to change which keys are reserved.
(define-command terminal-scroll-up   (v e) (terminal-scroll-by v (%page v)))
(define-command terminal-scroll-down (v e) (terminal-scroll-by v (- (%page v))))
(define-command terminal-scroll-home (v e) (terminal-scroll-by v (length (tv-history v))))
(define-command terminal-scroll-end  (v e) (setf (tv-scroll v) 0) (invalidate v))

(defkeymap *terminal-keys* ()
  ((code-char 28)  quit)                 ; Ctrl-\  : close the terminal (full-screen host)
  ('(:pgup . 1)    terminal-scroll-up)   ; Shift-PageUp
  ('(:pgdn . 1)    terminal-scroll-down) ; Shift-PageDown
  ('(:home . 1)    terminal-scroll-home) ; Shift-Home
  ('(:end  . 1)    terminal-scroll-end)) ; Shift-End

(defmethod handle-event ((tv terminal-view) (e key-event))
  (let* ((ks (event-keysym e)) (mods (event-modifiers e))
         (cmd (keymap-lookup (view-keymap tv) ks mods)))
    (cond
      (cmd (perform cmd tv e) (setf (handled-p e) t))          ; a reserved key
      ((tv-alive tv)
       (terminal-send-key tv ks mods)                          ; forward to the child
       (unless (zerop (tv-scroll tv)) (setf (tv-scroll tv) 0)) ; typing jumps to live
       (invalidate tv)
       (setf (handled-p e) t))
      (t (setf (handled-p e) t)))))

(defmethod handle-event ((tv terminal-view) (e wheel-event))
  (terminal-scroll-by tv (* 3 (- (event-delta e))))            ; wheel up = older
  (setf (handled-p e) t))

(defmethod handle-event ((tv terminal-view) (e mouse-down))
  (setf (handled-p e) t))                                      ; click just focuses (container does it)
