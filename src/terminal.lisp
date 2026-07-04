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
;;;; (sb_pushline / sb_popline), terminal properties (settermprop: cursor
;;;; visibility + shape, mouse mode, window title, alt-screen), resize, bell --
;;;; and the output callback are libffi *closures* (cffi-callback-closures),
;;;; each closing over *this* terminal.  That is exactly the "N distinct
;;;; callbacks, each with its own data" case cffi:defcallback cannot express.

(in-package #:revision-term)

(defvar *terminal-clipboard* "" "Last text copied from any terminal (fallback clipboard).")

;;; Live terminals are tracked so they can be torn down before an image dump:
;;; save-lisp-and-die requires a single thread (a live reader thread blocks it
;;; outright) and cannot preserve libffi closures or the child process.
(defvar *live-terminals* nil)
(defvar *live-terminals-lock* (sb-thread:make-mutex :name "revision-term-registry"))

(defun %register-terminal (tv)
  (sb-thread:with-mutex (*live-terminals-lock*) (pushnew tv *live-terminals*)))
(defun %unregister-terminal (tv)
  (sb-thread:with-mutex (*live-terminals-lock*) (setf *live-terminals* (remove tv *live-terminals*))))

(defun shutdown-all-terminals ()
  "Stop every live terminal (kill children, join reader threads, free foreign
resources).  Registered as an image-dump hook so `save-lisp-and-die' gets a
single thread and a clean heap; also callable directly on shutdown."
  (dolist (tv (sb-thread:with-mutex (*live-terminals-lock*) (copy-list *live-terminals*)))
    (ignore-errors (terminal-shutdown tv))))

(defvar *dump-hook-registered* nil)
(unless *dump-hook-registered*
  (uiop:register-image-dump-hook 'shutdown-all-terminals)
  (setf *dump-hook-registered* t))
(defvar *use-system-clipboard* t
  "When true, copies also go to the OS clipboard via an external tool (pbcopy /
wl-copy / xclip / xsel).  Bind to NIL to keep copies in-process (e.g. in tests).")

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
   ;; render cache: the live screen as packed cells + a per-row dirty flag, so
   ;; DRAW only re-polls (get_cell + colour convert) the rows libvterm damaged.
   (cache       :initform nil :accessor tv-cache)       ; (simple-array (unsigned-byte 53)) rows*cols
   (dirty-rows  :initform nil :accessor tv-dirty-rows)  ; simple-bit-vector, 1 = needs re-poll
   ;; coalesced input: the reader appends bytes under a lock and posts ONE drain
   ;; thunk per burst, so a flood of output isn't one run-on-ui closure per read.
   (in-lock   :initform (sb-thread:make-mutex :name "revision-term-input") :accessor tv-in-lock)
   (in-buf    :initform (make-array 8192 :element-type '(unsigned-byte 8)
                                    :adjustable t :fill-pointer 0) :accessor tv-in-buf)
   (in-posted :initform nil :accessor tv-in-posted)
   (exited      :initform nil :accessor tv-exited)      ; child has exited?
   (exit-status :initform nil :accessor tv-exit-status)
   (cursor-visible :initform t     :accessor tv-cursor-visible)
   (cursor-shape   :initform :block :accessor tv-cursor-shape)
   (alt-screen  :initform nil :accessor tv-alt-screen)   ; child on the alternate screen?
   (mouse-mode  :initform 0   :accessor tv-mouse-mode)   ; 0 none / 1 click / 2 drag / 3 move
   (title       :initform nil :accessor tv-title)        ; last OSC-set title (also -> window)
   (title-buf   :initform (make-string-output-stream) :accessor tv-title-buf)
   ;; scrollback: a ring of packed-cell lines pushed off the top by the child.
   (history   :initform (make-array 0 :adjustable t :fill-pointer 0) :accessor tv-history)
   (max-history :initform 2000 :accessor tv-max-history)
   (scroll    :initform 0 :accessor tv-scroll)        ; rows scrolled back (0 = live)
   ;; mouse text selection (in virtual row coords: history ++ live screen)
   (sel-anchor :initform nil :accessor tv-sel-anchor) ; (vrow . col) or NIL
   (sel-point  :initform nil :accessor tv-sel-point)  ; (vrow . col) or NIL
   (selecting  :initform nil :accessor tv-selecting)  ; a drag is in progress
   ;; OSC 52 (apps copying to the system clipboard) accumulation
   (osc52-buf :initform nil :accessor tv-osc52-buf)
   ;; foreign resources to free on shutdown
   (cell        :initform nil :accessor tv-cell)          ; reusable VTermScreenCell*
   (cbs-ptr     :initform nil :accessor tv-cbs-ptr)       ; VTermScreenCallbacks*
   (sel-cbs     :initform nil :accessor tv-sel-cbs)       ; VTermSelectionCallbacks*
   (sel-buf     :initform nil :accessor tv-sel-buf)       ; libvterm scratch buffer
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

(defun %set-color (colp r g b)
  (setf (cffi:foreign-slot-value colp '(:struct vterm-color) 'type) 0   ; VTERM_COLOR_RGB
        (cffi:foreign-slot-value colp '(:struct vterm-color) 'red)   r
        (cffi:foreign-slot-value colp '(:struct vterm-color) 'green) g
        (cffi:foreign-slot-value colp '(:struct vterm-color) 'blue)  b))

;;; --- colour + cell translation ----------------------------------------------

(declaim (inline color-rgb))
(defun color-rgb (colp)
  "The (values R G B) of a VTermColor pointer (already resolved to RGB)."
  (values (cffi:foreign-slot-value colp '(:struct vterm-color) 'red)
          (cffi:foreign-slot-value colp '(:struct vterm-color) 'green)
          (cffi:foreign-slot-value colp '(:struct vterm-color) 'blue)))

(defun cell-code (chars)
  "The display code for a VTermScreenCell's CHARS array: chars[0], or -- when the
cell carries combining code points (chars[1..5]) -- an interned grapheme cluster,
so the base glyph and its combining marks render as one unit.  libvterm marks the
right half of a double-width glyph with chars[0] = (uint32)-1; any code beyond the
Unicode range maps to the +wide-cont+ sentinel."
  (let ((c0 (cffi:mem-aref chars :uint32 0)))
    (cond
      ((zerop c0) 32)
      ((>= c0 #x110000) revision::+wide-cont+)          ; right half of a wide glyph
      (t
       (let ((n 1))
         (loop for i from 1 below 6
               for ci = (cffi:mem-aref chars :uint32 i)
               while (and (/= 0 ci) (< ci #x110000))
               do (setf n (1+ i)))
         (if (= n 1)
             c0
             (revision::intern-grapheme
              (with-output-to-string (s)
                (dotimes (i n) (write-char (code-char (cffi:mem-aref chars :uint32 i)) s))))))))))

(defun attrs->style (attrs)
  "Translate a VTermScreenCellAttrs bitfield word into revision's style bitmask
(bold / italic / underline{single,double,curly} / blink / reverse / strike)."
  (let ((uline (ldb (byte 2 1) attrs)))                                    ; 0 off 1 single 2 double 3 curly
    (logior (if (logbitp 0 attrs) revision::+style-bold+ 0)                ; bold
            (if (logbitp 3 attrs) revision::+style-italic+ 0)              ; italic
            (if (plusp uline) revision::+style-underline+ 0)               ; underline
            (case uline (2 revision::+style-uline-double+)
                        (3 revision::+style-uline-curly+) (t 0))
            (if (logbitp 4 attrs) revision::+style-blink+ 0)               ; blink
            (if (logbitp 5 attrs) revision::+style-reverse+ 0)             ; reverse
            (if (logbitp 7 attrs) revision::+style-strike+ 0))))           ; strike

(defun cell->packed (tv cellp)
  "Translate the foreign VTermScreenCell at CELLP into (values CODE ATTR WIDTH),
where ATTR is a revision true-colour + text-style attribute.  Reverse video is
applied by swapping fg/bg *here* -- deterministic and independent of how the
host terminal renders SGR 7 -- rather than emitted as a style."
  (let* ((screen (tv-vscreen tv))
         (chars (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'chars))
         (code  (cell-code chars))
         (width (cffi:foreign-slot-value cellp '(:struct vterm-screen-cell) 'width))
         (attrs (cffi:foreign-slot-value cellp '(:struct vterm-screen-cell) 'attrs))
         (style (attrs->style attrs))
         (fgp (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'fg))
         (bgp (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'bg)))
    (when (logbitp 6 attrs) (setf code 32))                     ; conceal (SGR 8): render blank
    (vterm-screen-convert-color-to-rgb screen fgp)
    (vterm-screen-convert-color-to-rgb screen bgp)
    (multiple-value-bind (fr fg fb) (color-rgb fgp)
      (multiple-value-bind (br bg bb) (color-rgb bgp)
        (when (logtest style revision::+style-reverse+)          ; swap, don't emit SGR 7
          (rotatef fr br) (rotatef fg bg) (rotatef fb bb)
          (setf style (logandc2 style revision::+style-reverse+)))
        (values code
                (rgb-attr (pack-rgb fr fg fb) (pack-rgb br bg bb) style)
                (if (<= width 0) 1 width))))))

(defun style->vattrs (style)
  "Rebuild a VTermScreenCellAttrs bitfield word from revision's style bitmask
(the inverse of ATTRS->STYLE), so a popped scrollback line keeps bold/underline/…"
  (logior (if (logtest style revision::+style-bold+)   #b1       0)         ; bit 0
          (ash (cond ((logtest style revision::+style-uline-double+) 2)     ; bits 1-2:
                     ((logtest style revision::+style-uline-curly+)  3)     ;   underline
                     ((logtest style revision::+style-underline+)    1)     ;   sub-type
                     (t 0))
               1)
          (if (logtest style revision::+style-italic+) (ash 1 3) 0)         ; bit 3
          (if (logtest style revision::+style-blink+)  (ash 1 4) 0)         ; bit 4
          (if (logtest style revision::+style-strike+) (ash 1 7) 0)))       ; bit 7

(defun packed->cell (cellp packed)
  "Write a revision PACKED cell back into the foreign VTermScreenCell at CELLP
(the inverse of CELL->PACKED, for the sb_popline callback).  Reverse is already
baked into the cell's swapped colours, so only the decorative styles are
reconstructed into the attrs bitfield."
  (let* ((code (revision::cell-char-code packed))
         (attr (revision::cell-attr packed))
         (style (if (attr-rgb-p attr) (revision::attr-rgb-style attr) 0))
         (chars (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'chars)))
    (dotimes (i 6) (setf (cffi:mem-aref chars :uint32 i) 0))
    (cond
      ((= code revision::+wide-cont+) (setf (cffi:mem-aref chars :uint32 0) 32))
      ((revision::cluster-code-p code)                     ; expand a cluster back out
       (let ((s (revision::cluster-string code)))
         (loop for i from 0 below (min 6 (length s))
               do (setf (cffi:mem-aref chars :uint32 i) (char-code (char s i))))))
      (t (setf (cffi:mem-aref chars :uint32 0) code)))
    (setf (cffi:foreign-slot-value cellp '(:struct vterm-screen-cell) 'width) 1
          (cffi:foreign-slot-value cellp '(:struct vterm-screen-cell) 'attrs) (style->vattrs style))
    (let ((fgp (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'fg))
          (bgp (cffi:foreign-slot-pointer cellp '(:struct vterm-screen-cell) 'bg)))
      (if (attr-rgb-p attr)
          (let ((fg (attr-rgb-fg attr)) (bg (attr-rgb-bg attr)))
            (%set-color fgp (ldb (byte 8 16) fg) (ldb (byte 8 8) fg) (ldb (byte 8 0) fg))
            (%set-color bgp (ldb (byte 8 16) bg) (ldb (byte 8 8) bg) (ldb (byte 8 0) bg)))
          (progn (%set-color fgp 192 192 192) (%set-color bgp 0 0 0))))))

;;; --- render cache: re-poll only the rows libvterm reports as damaged --------

(defun tv-alloc-cache (tv)
  "Allocate (or resize) the live-screen cache; mark every row for re-poll."
  (let ((rows (tv-rows tv)) (cols (tv-cols tv)))
    (setf (tv-cache tv) (make-array (* rows cols) :element-type '(unsigned-byte 53)
                                                  :initial-element (blank-cell tv))
          (tv-dirty-rows tv) (make-array rows :element-type 'bit :initial-element 1))))

(defun tv-mark-dirty (tv r0 r1)
  "Mark rows [R0,R1) as needing a re-poll (called from the damage callback).
Bounds by the dirty-vector's own length: a resize can fire damage before the
cache is reallocated, so tv-rows may briefly disagree with it."
  (let ((dr (tv-dirty-rows tv)))
    (when dr
      (loop for r from (max 0 r0) below (min (length dr) r1) do (setf (sbit dr r) 1)))))

(defun tv-refresh-row (tv row)
  "Re-poll one live ROW from libvterm into the cache (the expensive per-cell
work: get_cell + colour conversion + attr interning), once per damage."
  (let ((screen (tv-vscreen tv)) (cellp (tv-cell tv)) (cols (tv-cols tv))
        (cache (tv-cache tv)) (base (* row (tv-cols tv))) (x 0))
    (loop while (< x cols) do
      (vterm-screen-get-cell screen row x cellp)
      (multiple-value-bind (code attr cw) (cell->packed tv cellp)
        (setf (aref cache (+ base x)) (revision::cell-make-code code attr))
        (when (and (= cw 2) (< (1+ x) cols))
          (setf (aref cache (+ base x 1))
                (revision::cell-make-code revision::+wide-cont+ attr)))
        (incf x (max 1 cw))))))

(defun %copy-cache-row (tv src dst)
  "Copy cached row SRC to row DST (disjoint rows), moving its dirty bit too."
  (let ((cache (tv-cache tv)) (cols (tv-cols tv)) (dirty (tv-dirty-rows tv)))
    (replace cache cache :start1 (* dst cols) :end1 (* (1+ dst) cols)
                         :start2 (* src cols) :end2 (* (1+ src) cols))
    (setf (sbit dirty dst) (sbit dirty src))))

(defun tv-move-rect (tv dr0 dr1 dc0 dc1 sr0 sr1 sc0 sc1)
  "libvterm's moverect: the SRC rectangle was copied to DEST (a scroll).  For a
full-width vertical move we shift the cached rows to match (cheap), so only the
newly-exposed row -- damaged separately -- is re-polled.  Anything else falls
back to marking the destination rows dirty."
  (let ((cols (tv-cols tv)))
    (if (and (tv-cache tv)
             (= dc0 0) (= sc0 0) (= dc1 cols) (= sc1 cols)   ; full-width vertical
             (= (- dr1 dr0) (- sr1 sr0)))
        (let ((n (- sr1 sr0)) (delta (- dr0 sr0)))
          (if (minusp delta)                                 ; moving up: front to back
              (loop for i from 0 below n do (%copy-cache-row tv (+ sr0 i) (+ dr0 i)))
              (loop for i from (1- n) downto 0 do (%copy-cache-row tv (+ sr0 i) (+ dr0 i)))))
        (tv-mark-dirty tv dr0 dr1))))

;;; --- scrollback (the sb_pushline / sb_popline closures call these) ----------

(defun tv-shift-selection-on-trim (tv nhist)
  "A front history line was dropped, so every history-row virtual index shifts
down by one.  Shift the selection's history-row endpoints (rows < NHIST) to
match; live-row endpoints don't move.  If an endpoint scrolls off the top, drop
the selection (its content is gone)."
  (when (or (tv-sel-anchor tv) (tv-sel-point tv))
    (flet ((shift (p) (when (and p (< (car p) nhist)) (decf (car p)))))
      (shift (tv-sel-anchor tv))
      (shift (tv-sel-point tv)))
    (when (or (and (tv-sel-anchor tv) (minusp (car (tv-sel-anchor tv))))
              (and (tv-sel-point tv)  (minusp (car (tv-sel-point tv)))))
      (setf (tv-sel-anchor tv) nil (tv-sel-point tv) nil (tv-selecting tv) nil))))

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
          (decf (fill-pointer h)))
        (tv-shift-selection-on-trim tv (length h)))    ; keep any selection tracking
      (when (plusp (tv-scroll tv))                     ; keep the viewport stable
        (setf (tv-scroll tv) (min (length h) (1+ (tv-scroll tv))))))))

(defun tv-pop-history (tv cols cells)
  "Fill COLS cells at CELLS from the newest scrollback line and remove it (the
sb_popline path, used when a resize taller pulls lines back onto the screen).
Returns 1 if a line was available, 0 otherwise."
  (let ((h (tv-history tv)))
    (if (zerop (length h))
        0
        (let ((line (vector-pop h)))
          (dotimes (i cols)
            (packed->cell (cffi:inc-pointer cells (* i +cell-size+))
                          (if (< i (length line)) (aref line i) (blank-cell tv))))
          (when (plusp (tv-scroll tv)) (setf (tv-scroll tv) (max 0 (1- (tv-scroll tv)))))
          1))))

;;; --- terminal properties (the settermprop closure) --------------------------

(defun tv-accumulate-title (tv val)
  "Reassemble the (possibly fragmented) window title the child sets via OSC and,
when complete, publish it to TV and its owning window."
  (let* ((str    (cffi:foreign-slot-value val '(:struct vterm-string-fragment) 'str))
         (packed (cffi:foreign-slot-value val '(:struct vterm-string-fragment) 'packed))
         (len    (vsf-len packed)))
    (when (vsf-initial-p packed)                          ; initial fragment
      (setf (tv-title-buf tv) (make-string-output-stream)))
    (when (and (not (cffi:null-pointer-p str)) (plusp len))
      (write-string (cffi:foreign-string-to-lisp str :count len :encoding :utf-8)
                    (tv-title-buf tv)))
    (when (vsf-final-p packed)                            ; final fragment
      (let ((title (get-output-stream-string (tv-title-buf tv))))
        (setf (tv-title tv) title)
        (let ((win (view-root tv)))
          (when (typep win 'window)
            (setf (window-title win) (format nil " ~a " title))
            (invalidate win)))))))

;;; --- the libvterm callbacks, as per-instance libffi closures ----------------

(defun %install-callbacks (tv)
  "Mint this terminal's libvterm callbacks as libffi closures (each closes over
TV), stash them in a VTermScreenCallbacks struct, and register it.  Also install
the output callback that pipes the child's replies + our keystrokes to the pty."
  (let* ((cbs (cffi:foreign-alloc '(:struct vterm-screen-callbacks)))
         ;; damage takes a VTermRect by value (4 ints, 16 bytes) -> two integer
         ;; registers; flatten it into two uint64s: (start_row|end_row<<32) and
         ;; (start_col|end_col<<32).  We only need the row span.
         (damage
           (make-foreign-callback
            (lambda (rows-packed cols-packed user)
              (declare (ignore cols-packed user))
              (tv-mark-dirty tv (logand rows-packed #xffffffff) (ash rows-packed -32))
              1)
            :int '(:uint64 :uint64 :pointer)))
         ;; moverect takes two VTermRects by value (dest, src) = 32 bytes -> four
         ;; integer registers; flatten each rect into (rows, cols) uint64s.
         (moverect
           (make-foreign-callback
            (lambda (dest-rows dest-cols src-rows src-cols user)
              (declare (ignore user))
              (tv-move-rect tv
                            (logand dest-rows #xffffffff) (ash dest-rows -32)
                            (logand dest-cols #xffffffff) (ash dest-cols -32)
                            (logand src-rows #xffffffff) (ash src-rows -32)
                            (logand src-cols #xffffffff) (ash src-cols -32))
              1)
            :int '(:uint64 :uint64 :uint64 :uint64 :pointer)))
         (settermprop
           (make-foreign-callback
            (lambda (prop val user)
              (declare (ignore user))
              (cond
                ((= prop +prop-cursorvisible+)
                 (setf (tv-cursor-visible tv) (/= 0 (cffi:mem-ref val :int))))
                ((= prop +prop-altscreen+)
                 (setf (tv-alt-screen tv) (/= 0 (cffi:mem-ref val :int))))
                ((= prop +prop-cursorshape+)
                 (setf (tv-cursor-shape tv)
                       (let ((n (cffi:mem-ref val :int)))
                         (cond ((= n +cursorshape-underline+) :underline)
                               ((= n +cursorshape-bar+) :bar)
                               (t :block)))))
                ((= prop +prop-mouse+)
                 (setf (tv-mouse-mode tv) (cffi:mem-ref val :int)))
                ((= prop +prop-title+)
                 (tv-accumulate-title tv val)))
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
         (sb-popline
           (make-foreign-callback
            (lambda (cols cells user)
              (declare (ignore user))
              (tv-pop-history tv cols cells))
            :int '(:int :pointer :pointer)))
         (sb-clear
           (make-foreign-callback
            (lambda (user)
              (declare (ignore user))
              (setf (fill-pointer (tv-history tv)) 0 (tv-scroll tv) 0)   ; app cleared scrollback
              (invalidate tv)
              1)
            :int '(:pointer)))
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
    ;; movecursor stays NULL -- cursor position is polled once per frame.
    (macrolet ((slot (name) `(cffi:foreign-slot-value cbs '(:struct vterm-screen-callbacks) ',name)))
      (setf (slot damage)      damage
            (slot moverect)    moverect
            (slot movecursor)  (cffi:null-pointer)
            (slot settermprop) settermprop
            (slot bell)        bell
            (slot resize)      resize
            (slot sb-pushline) sb-pushline
            (slot sb-popline)  sb-popline
            (slot sb-clear)    sb-clear))
    (vterm-screen-set-callbacks (tv-vscreen tv) cbs (cffi:null-pointer))
    (vterm-output-set-callback (tv-vt tv) output (cffi:null-pointer))
    (setf (tv-cbs-ptr tv) cbs
          (tv-closures tv)
          (list damage moverect settermprop bell resize
                sb-pushline sb-popline sb-clear output))))

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
      (vterm-screen-set-damage-merge (tv-vscreen tv) +damage-row+)  ; per-row damage
      (vterm-screen-enable-altscreen (tv-vscreen tv) 1)
      (vterm-screen-enable-reflow (tv-vscreen tv) 1)   ; reflow text on resize
      (setf (tv-cell tv) (cffi:foreign-alloc '(:struct vterm-screen-cell)))
      (tv-alloc-cache tv)
      (vterm-screen-reset (tv-vscreen tv) 1)
      (%install-selection tv)                          ; OSC 52 clipboard (after reset)
      ;; spawn the child on a pty of the same size
      (let* ((cmd (or (tv-command tv) (default-shell-command)))
             (pty (spawn-pty cmd rows cols)))
        (setf (tv-pty tv) pty (tv-alive tv) t (tv-exited tv) nil)
        (terminal-start-reader tv)
        (%register-terminal tv)))))

(defun default-shell-command ()
  (list (or (sb-ext:posix-getenv "SHELL") "/bin/sh")))

(defun terminal-start-reader (tv)
  "Spawn the reader thread: it only reads bytes off the pty and appends them to
the pending-input buffer; it never touches libvterm.  It posts at most one drain
thunk per burst (coalescing), so a flood of output doesn't queue a closure per
read."
  (let ((fd (pty-master (tv-pty tv))))
    (setf (tv-reader tv)
          (sb-thread:make-thread
           (lambda ()
             (cffi:with-foreign-object (buf :unsigned-char 8192)
               (loop while (tv-alive tv) do
                 (let ((n (pty-read fd buf 8192)))
                   (cond
                     ((> n 0) (terminal-enqueue-input tv buf n))
                     (t                                   ; EOF or error: child gone
                      (setf (tv-alive tv) nil)
                      (run-on-ui (lambda () (terminal-child-exited tv)))
                      (return)))))))
           :name "revision-term-reader"))))

(defun terminal-enqueue-input (tv buf n)
  "Reader thread: append N bytes from the foreign BUF to the pending input, and
post a single drain thunk if one isn't already pending."
  (let ((post nil))
    (sb-thread:with-mutex ((tv-in-lock tv))
      (let ((v (tv-in-buf tv)))
        (dotimes (i n) (vector-push-extend (cffi:mem-aref buf :unsigned-char i) v)))
      (unless (tv-in-posted tv) (setf (tv-in-posted tv) t post t)))
    (when post (run-on-ui (lambda () (terminal-drain-input tv))))))

(defun terminal-drain-input (tv)
  "UI thread: feed ALL pending bytes through libvterm in one shot (callbacks fire
here), flush merged damage, then ask for a repaint."
  (let ((bytes (sb-thread:with-mutex ((tv-in-lock tv))
                 (setf (tv-in-posted tv) nil)
                 (prog1 (subseq (tv-in-buf tv) 0)
                   (setf (fill-pointer (tv-in-buf tv)) 0)))))
    (when (and (tv-vt tv) (plusp (length bytes)))
      (let ((n (length bytes)))
        (cffi:with-foreign-object (fb :unsigned-char n)
          (dotimes (i n) (setf (cffi:mem-aref fb :unsigned-char i) (aref bytes i)))
          (vterm-input-write (tv-vt tv) fb n)
          (vterm-screen-flush-damage (tv-vscreen tv))))   ; -> damage callback -> dirty rows
      (invalidate tv))))

(defun terminal-child-exited (tv)
  (setf (tv-alive tv) nil (tv-exited tv) t)
  (setf (tv-exit-status tv) (reap-child (tv-pty tv)))
  (invalidate tv)
  (when (tv-on-exit tv) (ignore-errors (funcall (tv-on-exit tv) tv))))

(defun terminal-shutdown (tv)
  "Stop the child + reader and free every foreign resource.  Runs on the UI
thread (as run-view's cleanup); idempotent."
  (%unregister-terminal tv)
  (setf (tv-alive tv) nil)
  (when (tv-pty tv) (pty-close (tv-pty tv)))          ; closes fd -> unblocks reader
  (when (tv-reader tv)
    (ignore-errors (sb-thread:join-thread (tv-reader tv) :timeout 2))
    (setf (tv-reader tv) nil))
  (dolist (c (tv-closures tv)) (ignore-errors (free-foreign-callback c)))
  (setf (tv-closures tv) nil)
  (when (tv-cell tv)    (cffi:foreign-free (tv-cell tv))    (setf (tv-cell tv) nil))
  (when (tv-cbs-ptr tv) (cffi:foreign-free (tv-cbs-ptr tv)) (setf (tv-cbs-ptr tv) nil))
  (when (tv-sel-cbs tv) (cffi:foreign-free (tv-sel-cbs tv)) (setf (tv-sel-cbs tv) nil))
  (when (tv-vt tv)      (vterm-free (tv-vt tv))             (setf (tv-vt tv) nil))
  (when (tv-sel-buf tv) (cffi:foreign-free (tv-sel-buf tv)) (setf (tv-sel-buf tv) nil)))

;;; --- resize (when the view's bounds change) ---------------------------------

(defun terminal-ensure-size (tv)
  (when (tv-vt tv)
    (multiple-value-bind (rows cols) (%bounds-size tv)
      (when (or (/= rows (tv-rows tv)) (/= cols (tv-cols tv)))
        (setf (tv-rows tv) rows (tv-cols tv) cols)
        (tv-alloc-cache tv)                             ; realloc BEFORE set-size (which may
        (vterm-set-size (tv-vt tv) rows cols)           ; fire damage against the new dirty vector)
        (when (tv-pty tv) (set-winsize (pty-master (tv-pty tv)) rows cols))))))

;;; --- viewport geometry (shared by draw, mouse, selection) -------------------

(defun tv-viewport-top (tv)
  "The first VIRTUAL row (index into history ++ live screen) shown at the top of
the viewport.  The viewport is bottom-aligned; SCROLL lifts it into history."
  (let ((b (view-bounds tv)))
    (- (+ (length (tv-history tv)) (tv-rows tv)) (rect-height b) (tv-scroll tv))))

(defun tv-event-vcell (tv e)
  "(values VROW COL) in virtual coordinates for a mouse event over the view."
  (let* ((b (view-bounds tv))
         (ry  (- (cdr (event-where e)) (rect-ay b)))
         (col (max 0 (min (1- (rect-width b)) (- (car (event-where e)) (rect-ax b))))))
    (values (+ (tv-viewport-top tv) ry) col)))

;;; --- drawing ----------------------------------------------------------------

(defun tv-cursor-pos (tv)
  (cffi:with-foreign-object (pos '(:struct vterm-pos))
    (vterm-state-get-cursorpos (tv-vstate tv) pos)
    (values (cffi:foreign-slot-value pos '(:struct vterm-pos) 'row)
            (cffi:foreign-slot-value pos '(:struct vterm-pos) 'col))))

(defun %draw-live-row (tv ry live-row w ax ay)
  ;; refresh this row from libvterm only if it was damaged since we last drew it
  (let ((dr (tv-dirty-rows tv)))
    (when (and dr (< live-row (length dr)) (= 1 (sbit dr live-row)))
      (tv-refresh-row tv live-row)
      (setf (sbit dr live-row) 0)))
  (let ((cache (tv-cache tv)) (base (* live-row (tv-cols tv))) (gy (+ ay ry)))
    (when (and cache *screen*)
      (dotimes (x (min w (tv-cols tv)))
        (screen-cell-set *screen* (+ ax x) gy (aref cache (+ base x)))))))

(defun %draw-history-row (tv ry line w ax ay)
  (let ((gy (+ ay ry)) (n (length line)) (blank (blank-cell tv)))
    (dotimes (x w)
      (when *screen*
        (screen-cell-set *screen* (+ ax x) gy (if (< x n) (aref line x) blank))))))

(defun %draw-blank-row (tv ry w ax ay)
  (let ((gy (+ ay ry)) (blank (blank-cell tv)))
    (dotimes (x w) (when *screen* (screen-cell-set *screen* (+ ax x) gy blank)))))

(defun %code-string (code)
  "A display CODE as a string (a grapheme-cluster code expands to its code
points; a blank is a space; a wide-glyph continuation contributes nothing, since
the wide glyph in the preceding column already covers it)."
  (cond ((zerop code) " ")
        ((= code revision::+wide-cont+) "")
        ((revision::cluster-code-p code) (revision::cluster-string code))
        (t (string (code-char code)))))

(defun tv-line-string (tv line)
  "A packed-cell scrollback LINE as a right-trimmed string."
  (declare (ignore tv))
  (string-right-trim
   '(#\Space)
   (with-output-to-string (s)
     (loop for c across line
           do (write-string (%code-string (revision::cell-char-code c)) s)))))

(defun tv-vrow-code (tv vrow col)
  "The display CODE at virtual (VROW,COL) -- from history or the live screen."
  (let ((nhist (length (tv-history tv))))
    (if (< vrow nhist)
        (let ((line (aref (tv-history tv) vrow)))
          (if (< col (length line)) (revision::cell-char-code (aref line col)) 32))
        (let ((lr (- vrow nhist)))
          (if (and (<= 0 lr) (< lr (tv-rows tv)))
              (progn
                (vterm-screen-get-cell (tv-vscreen tv) lr col (tv-cell tv))
                (cell-code (cffi:foreign-slot-pointer (tv-cell tv) '(:struct vterm-screen-cell) 'chars)))
              32)))))

(defun %ordered-selection (tv)
  "The selection as (values R0 C0 R1 C1) with the earlier point first, or NIL."
  (when (and (tv-sel-anchor tv) (tv-sel-point tv))
    (let ((ar (car (tv-sel-anchor tv))) (ac (cdr (tv-sel-anchor tv)))
          (pr (car (tv-sel-point tv)))  (pc (cdr (tv-sel-point tv))))
      (when (or (> ar pr) (and (= ar pr) (> ac pc)))
        (rotatef ar pr) (rotatef ac pc))
      (values ar ac pr pc))))

(defun tv-draw-selection (tv ax ay w h top)
  (multiple-value-bind (r0 c0 r1 c1) (%ordered-selection tv)
    (when r0
      (let ((attr (rgb-attr (pack-rgb 255 255 255) (pack-rgb 38 79 120))))
        (dotimes (ry h)
          (let ((vr (+ top ry)))
            (when (<= r0 vr r1)
              (let ((from (if (= vr r0) c0 0))
                    (to   (if (= vr r1) c1 (1- w))))
                (loop for col from (max 0 from) to (min (1- w) to) do
                  (put-code (+ ax col) (+ ay ry) (tv-vrow-code tv vr col) attr))))))))))

(defun %draw-exit-banner (tv ax ay w h)
  (let* ((msg (if (tv-exit-status tv)
                  (format nil " [process exited: ~a — Ctrl-\\ to close] " (tv-exit-status tv))
                  " [process exited — Ctrl-\\ to close] "))
         (attr (rgb-attr (pack-rgb 255 255 255) (pack-rgb 176 32 32)))
         (row (+ ay (1- h)))
         (start (max 0 (floor (- w (length msg)) 2))))
    (loop for i below (length msg) while (< (+ start i) w)
          do (put-code (+ ax start i) row (char-code (char msg i)) attr))))

(defmethod draw ((tv terminal-view))
  (terminal-ensure-size tv)
  (let* ((b (view-bounds tv)))
    (when (and b (tv-vscreen tv) (tv-cell tv))
      (let* ((ax (rect-ax b)) (ay (rect-ay b))
             (w (rect-width b)) (h (rect-height b))
             (nhist (length (tv-history tv)))
             (scroll (tv-scroll tv))
             (top (tv-viewport-top tv)))
        (dotimes (ry h)
          (let ((vr (+ top ry)))
            (cond
              ((< vr 0)       (%draw-blank-row tv ry w ax ay))
              ((< vr nhist)   (%draw-history-row tv ry (aref (tv-history tv) vr) w ax ay))
              (t              (%draw-live-row tv ry (- vr nhist) w ax ay)))))
        (tv-draw-selection tv ax ay w h top)
        (when (tv-exited tv) (%draw-exit-banner tv ax ay w h))
        ;; the hardware cursor, only in the live view and while focused
        (when (and (zerop scroll) (not (tv-exited tv)) (tv-cursor-visible tv)
                   (view-focused-p tv) *screen*)
          (multiple-value-bind (cr cc) (tv-cursor-pos tv)
            (let ((srow (- (+ nhist cr) top)))
              (when (and (<= 0 srow (1- h)) (<= 0 cc (1- w)))
                (set-cursor-pos *screen* (+ ax cc) (+ ay srow))
                (set-cursor-shape (tv-cursor-shape tv))
                (show-cursor *screen*)))))))))

;;; --- keyboard input ---------------------------------------------------------

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

(defun terminal-paste-text (tv text)
  "Send TEXT to the child wrapped in a bracketed-paste, so a paste-aware shell
treats it as literal input (newlines don't auto-execute mid-paste)."
  (when (and (tv-vt tv) text (plusp (length text)))
    (vterm-keyboard-start-paste (tv-vt tv))
    (loop for ch across text do
      (if (char= ch #\Newline)
          (vterm-keyboard-key (tv-vt tv) +key-enter+ 0)
          (vterm-keyboard-unichar (tv-vt tv) (char-code ch) 0)))
    (vterm-keyboard-end-paste (tv-vt tv))
    (setf (tv-scroll tv) 0)
    (invalidate tv)))

;;; --- clipboard (internal + the OS clipboard, cross-platform) ----------------

(defparameter *clipboard-put-cmds*
  #+darwin '(("pbcopy"))
  #-darwin '(("wl-copy") ("xclip" "-selection" "clipboard") ("xsel" "-ib"))
  "Commands tried in order to write the OS clipboard (first that works wins).")

(defparameter *clipboard-get-cmds*
  #+darwin '(("pbpaste"))
  #-darwin '(("wl-paste" "-n") ("xclip" "-selection" "clipboard" "-o") ("xsel" "-ob"))
  "Commands tried in order to read the OS clipboard.")

(defun clipboard-put (text)
  "Copy TEXT to the internal clipboard and, when *USE-SYSTEM-CLIPBOARD*, to the
OS clipboard via the first available external tool."
  (setf *terminal-clipboard* text)
  (when *use-system-clipboard*
    (dolist (cmd *clipboard-put-cmds*)
      (when (ignore-errors
             (with-input-from-string (in text)
               (eql 0 (sb-ext:process-exit-code
                       (sb-ext:run-program (first cmd) (rest cmd)
                                           :search t :wait t :input in)))))
        (return t)))))

(defun clipboard-get ()
  "Read the OS clipboard (first available tool), falling back to the internal
clipboard."
  (or (when *use-system-clipboard*
        (dolist (cmd *clipboard-get-cmds*)
          (let ((s (ignore-errors
                    (with-output-to-string (out)
                      (sb-ext:run-program (first cmd) (rest cmd)
                                          :search t :wait t :output out)))))
            (when (and s (plusp (length s))) (return s)))))
      *terminal-clipboard*))

;;; --- OSC 52: a program setting the clipboard --------------------------------

(defun %install-selection (tv)
  "Route OSC 52 (a program copying to the system clipboard) through a selection
`set' closure.  libvterm passes a VTermStringFragment *by value*; that 16-byte
struct occupies two integer argument slots on arm64 / x86-64, so we declare the
closure with the fragment flattened into (STR, PACKED)."
  (let* ((cbs (cffi:foreign-alloc '(:struct vterm-selection-callbacks)))
         (buf (cffi:foreign-alloc :unsigned-char :count 16384))
         (setcb
           (make-foreign-callback
            (lambda (mask str packed user)
              (declare (ignore mask user))
              (let ((len (vsf-len packed)))
                (when (vsf-initial-p packed)
                  (setf (tv-osc52-buf tv) (make-string-output-stream)))
                (when (and (tv-osc52-buf tv) (not (cffi:null-pointer-p str)) (plusp len))
                  (write-string (cffi:foreign-string-to-lisp str :count len :encoding :utf-8)
                                (tv-osc52-buf tv)))
                (when (and (tv-osc52-buf tv) (vsf-final-p packed))
                  (clipboard-put (get-output-stream-string (tv-osc52-buf tv)))
                  (setf (tv-osc52-buf tv) nil)))
              1)
            :int '(:int :pointer :uint64 :pointer))))
    (setf (cffi:foreign-slot-value cbs '(:struct vterm-selection-callbacks) 'set) setcb
          (cffi:foreign-slot-value cbs '(:struct vterm-selection-callbacks) 'query) (cffi:null-pointer))
    (vterm-state-set-selection-callbacks (tv-vstate tv) cbs (cffi:null-pointer) buf 16384)
    (setf (tv-sel-cbs tv) cbs (tv-sel-buf tv) buf)
    (push setcb (tv-closures tv))))

;;; --- selection --------------------------------------------------------------

(defun tv-selection-text (tv)
  "The currently-selected text (linear/stream selection), trailing blanks
trimmed per line, or NIL."
  (multiple-value-bind (r0 c0 r1 c1) (%ordered-selection tv)
    (when r0
      (let ((w (rect-width (view-bounds tv))))
        (with-output-to-string (out)
          (loop for vr from r0 to r1 do
            (let* ((from (if (= vr r0) c0 0))
                   (to   (if (= vr r1) c1 (1- w)))
                   (line (with-output-to-string (l)
                           (loop for col from (max 0 from) to (min (1- w) to)
                                 do (write-string (%code-string (tv-vrow-code tv vr col)) l)))))
              (write-string (string-right-trim '(#\Space) line) out)
              (when (< vr r1) (terpri out)))))))))

(defun tv-copy-selection (tv)
  (let ((text (tv-selection-text tv)))
    (when (and text (plusp (length text))) (clipboard-put text)))
  (invalidate tv))

(defun tv-clear-selection (tv)
  (when (or (tv-sel-anchor tv) (tv-sel-point tv))
    (setf (tv-sel-anchor tv) nil (tv-sel-point tv) nil (tv-selecting tv) nil)
    (invalidate tv)))

;;; --- scrollback navigation --------------------------------------------------

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
(define-command terminal-paste       (v e) (terminal-paste-text v (clipboard-get)))

(defkeymap *terminal-keys* ()
  ((code-char 28)  quit)                 ; Ctrl-\  : close the terminal (full-screen host)
  ('(:ins  . 1)    terminal-paste)       ; Shift-Insert : paste (bracketed)
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
       (tv-clear-selection tv)
       (terminal-send-key tv ks mods)                          ; forward to the child
       (unless (zerop (tv-scroll tv)) (setf (tv-scroll tv) 0)) ; typing jumps to live
       (invalidate tv)
       (setf (handled-p e) t))
      (t (setf (handled-p e) t)))))

;;; --- mouse ------------------------------------------------------------------
;;; When the child has enabled mouse reporting (VTERM_PROP_MOUSE), pointer
;;; events are forwarded to it (so vim/htop/tmux get the mouse).  Otherwise the
;;; mouse drives local text selection + scrollback, the way a normal terminal
;;; emulator behaves when the app isn't grabbing the mouse.

(defun tv-forward-mouse-p (tv)
  (and (plusp (tv-mouse-mode tv)) (zerop (tv-scroll tv)) (tv-alive tv)))

(defun %vbutton (e)
  (if (logtest (event-buttons e) revision:+mb-right+) 3 1))

(defun %forward-mouse-at (tv e press pressed)
  "Forward a mouse event to the child at its live-screen cell."
  (multiple-value-bind (vr c) (tv-event-vcell tv e)
    (let ((lr (- vr (length (tv-history tv)))))
      (when (<= 0 lr (1- (tv-rows tv)))
        (vterm-mouse-move (tv-vt tv) lr c 0)
        (when press (vterm-mouse-button (tv-vt tv) (%vbutton e) pressed 0)))))
  (invalidate tv))

(defmethod handle-event ((tv terminal-view) (e mouse-down))
  (cond
    ((tv-forward-mouse-p tv) (%forward-mouse-at tv e t 1))
    (t (tv-clear-selection tv)
       (multiple-value-bind (vr c) (tv-event-vcell tv e)
         (setf (tv-sel-anchor tv) (cons vr c)
               (tv-sel-point tv)  (cons vr c)
               (tv-selecting tv)  t))
       (invalidate tv)))
  (setf (handled-p e) t))

(defmethod handle-event ((tv terminal-view) (e revision::mouse-move))
  (cond
    ((and (tv-forward-mouse-p tv) (>= (tv-mouse-mode tv) 2))   ; drag / any-motion modes
     (%forward-mouse-at tv e nil 0))
    ((tv-selecting tv)
     (multiple-value-bind (vr c) (tv-event-vcell tv e)
       (setf (tv-sel-point tv) (cons vr c)))
     (invalidate tv)))
  (setf (handled-p e) t))

(defmethod handle-event ((tv terminal-view) (e revision::mouse-up))
  (cond
    ((tv-forward-mouse-p tv) (%forward-mouse-at tv e t 0))
    ((tv-selecting tv)
     (setf (tv-selecting tv) nil)
     (tv-copy-selection tv)))                                  ; auto-copy on release
  (setf (handled-p e) t))

(defmethod handle-event ((tv terminal-view) (e wheel-event))
  (if (tv-forward-mouse-p tv)
      (progn                                                   ; wheel -> button 4/5
        (multiple-value-bind (vr c) (tv-event-vcell tv e)
          (let ((lr (max 0 (min (1- (tv-rows tv)) (- vr (length (tv-history tv)))))))
            (vterm-mouse-move (tv-vt tv) lr c 0)))
        (vterm-mouse-button (tv-vt tv) (if (minusp (event-delta e)) 4 5) 1 0)
        (invalidate tv))
      (terminal-scroll-by tv (* 3 (- (event-delta e)))))       ; else scroll the scrollback
  (setf (handled-p e) t))
