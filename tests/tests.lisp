;;;; tests.lisp --- headless FiveAM suite (no interactive terminal required).
;;;;
;;;; Exercises the whole non-UI stack by driving a TERMINAL-VIEW exactly as the
;;;; UI would (minus the screen): we make the running thread the "UI thread", so
;;;; the reader thread enqueues bytes via RUN-ON-UI and we drain them here.
;;;; Covers the libvterm bindings, the by-value get_cell, the PTY round-trip,
;;;; and each of improvements 1-7 (resize, child reaping/exit, mouse mode, OSC
;;;; title, cursor shape, selection/copy, scrollback push).

(defpackage #:revision-term-tests
  (:use #:cl)
  (:import-from #:fiveam #:def-suite #:in-suite #:test #:is #:is-true #:is-false #:finishes #:run!)
  (:export #:run))

(in-package #:revision-term-tests)

(def-suite revision-term :description "revision-term terminal widget")
(in-suite revision-term)

;;; --- helpers ----------------------------------------------------------------

(defun cell-char (screen cell row col)
  (revision-term::vterm-screen-get-cell screen row col cell)
  (let ((code (cffi:mem-aref
               (cffi:foreign-slot-pointer
                cell '(:struct revision-term::vterm-screen-cell) 'revision-term::chars)
               :uint32 0)))
    (if (or (zerop code) (>= code #x110000)) #\Space (code-char code))))  ; wide-glyph right half

(defun grid-text (tv)
  "The full emulated grid as one newline-joined string."
  (let ((screen (revision-term::tv-vscreen tv))
        (cell (revision-term::tv-cell tv)))
    (with-output-to-string (out)
      (dotimes (r (revision-term::tv-rows tv))
        (dotimes (c (revision-term::tv-cols tv)) (write-char (cell-char screen cell r c) out))
        (terpri out)))))

(defmacro with-terminal ((tv command &key (cols 80) (rows 24)) &body body)
  "Run BODY with TV a started terminal-view driving COMMAND, with THIS thread as
the UI thread; guarantees shutdown.  *UI-THREAD* is set globally (not just
bound) so the reader thread also observes it and hands work back here via
RUN-ON-UI, exactly as under RUN-VIEW -- otherwise callbacks would run on the
reader thread, outside our dynamic bindings."
  `(let ((,tv (make-instance 'revision-term::terminal-view :command ,command))
         (saved-ui revision::*ui-thread*))
     (setf (revision:view-bounds ,tv) (revision::make-trect 0 0 ,cols ,rows)
           revision::*ui-thread* sb-thread:*current-thread*)
     (unwind-protect
          (progn (revision-term::terminal-start ,tv) ,@body)
       (revision-term::terminal-shutdown ,tv)
       (setf revision::*ui-thread* saved-ui))))

(defun cell-attr-at (tv row col)
  "The revision attribute of the emulated cell at (ROW,COL)."
  (revision-term::vterm-screen-get-cell (revision-term::tv-vscreen tv) row col
                                        (revision-term::tv-cell tv))
  (nth-value 1 (revision-term::cell->packed tv (revision-term::tv-cell tv))))

(defun cell-code-at (tv row col)
  "The display code of the emulated cell at (ROW,COL)."
  (revision-term::vterm-screen-get-cell (revision-term::tv-vscreen tv) row col
                                        (revision-term::tv-cell tv))
  (revision-term::cell-code
   (cffi:foreign-slot-pointer (revision-term::tv-cell tv)
                              '(:struct revision-term::vterm-screen-cell)
                              'revision-term::chars)))

(defun pump-until (tv pred &optional (secs 6))
  "Drain the UI bridge until PRED returns true or SECS elapse; return PRED's
final value."
  (let ((deadline (+ (get-internal-real-time) (* secs internal-time-units-per-second))))
    (loop
      (revision::drain-ui-callbacks)
      (let ((v (funcall pred)))
        (when v (return v))
        (when (> (get-internal-real-time) deadline) (return nil))
        (sleep 0.02)))))

;;; --- 1. headless libvterm: write bytes, read the grid back ------------------

(test headless-vterm
  "libvterm bindings + by-value get_cell + cell-struct layout round-trip."
  (revision-term::ensure-libvterm)
  (let ((vt (revision-term::vterm-new 24 80)))
    (unwind-protect
         (progn
           (revision-term::vterm-set-utf8 vt 1)
           (let ((screen (revision-term::vterm-obtain-screen vt)))
             (revision-term::vterm-screen-reset screen 1)
             (let ((bytes (map '(vector (unsigned-byte 8)) #'char-code "hello")))
               (cffi:with-foreign-object (buf :unsigned-char 5)
                 (dotimes (i 5) (setf (cffi:mem-aref buf :unsigned-char i) (aref bytes i)))
                 (revision-term::vterm-input-write vt buf 5)))
             (cffi:with-foreign-object (cell '(:struct revision-term::vterm-screen-cell))
               (is (string= "hello"
                            (coerce (loop for c below 5 collect (cell-char screen cell 0 c))
                                    'string))))))
      (revision-term::vterm-free vt))))

;;; --- 2. real PTY round-trip -------------------------------------------------

(test pty-roundtrip
  "A child's output reaches the emulated grid through the reader->UI bridge."
  (with-terminal (tv '("/bin/sh" "-c" "printf 'SMOKE_OK_42\\n'; sleep 2"))
    (is-true (pump-until tv (lambda () (search "SMOKE_OK_42" (grid-text tv)))))
    (is (integerp (revision-term::terminal-child-pid tv)))))

;;; --- improvement 1: dynamic resize propagates to the child ------------------

(test resize-propagates
  "set-winsize (via the variadic-correct ioctl) delivers the new size to the
child -- `stty size' reflects it."
  (let ((pty (revision-term::spawn-pty
              '("/bin/sh" "-c" "while : ; do stty size; sleep 0.15; done") 24 80)))
    (unwind-protect
         (let ((fd (revision-term::pty-master pty)))
           (cffi:with-foreign-object (buf :unsigned-char 4096)
             (flet ((slurp (secs)
                      (let ((end (+ (get-internal-real-time)
                                    (* secs internal-time-units-per-second)))
                            (acc (make-string-output-stream)))
                        (loop while (< (get-internal-real-time) end) do
                          (when (sb-sys:wait-until-fd-usable fd :input 0.1 nil)
                            (let ((n (revision-term::pty-read fd buf 4096)))
                              (when (> n 0)
                                (dotimes (i n)
                                  (write-char (code-char (cffi:mem-aref buf :unsigned-char i)) acc))))))
                        (get-output-stream-string acc))))
               (is (search "24 80" (slurp 0.5)) "initial size seen")
               (revision-term::set-winsize fd 40 100)
               (is (search "40 100" (slurp 1.0)) "resized size seen by child"))))
      (revision-term::pty-close pty))))

;;; --- improvement 2 & 3: the child is reaped and its status recorded ---------

(test child-exit-reaped
  "When the child exits, TERMINAL detects it, reaps it, and records the status."
  (with-terminal (tv '("/bin/sh" "-c" "exit 7"))
    (is-true (pump-until tv (lambda () (revision-term::tv-exited tv))))
    (is (eql 7 (revision-term::tv-exit-status tv)))
    (is-false (revision-term::terminal-alive-p tv))))

;;; --- improvement 4: mouse reporting is picked up from the child -------------

(test mouse-mode-enabled
  "The child enabling mouse tracking (CSI ?1000h) sets the view's mouse mode."
  (with-terminal (tv '("/bin/sh" "-c" "printf '\\033[?1000h'; sleep 2"))
    (is-true (pump-until tv (lambda () (plusp (revision-term::tv-mouse-mode tv)))))))

;;; --- improvement 5: OSC window title + DECSCUSR cursor shape ----------------

(test osc-title
  "An OSC 0 sequence updates the terminal's title."
  (with-terminal (tv '("/bin/sh" "-c" "printf '\\033]0;MY_TITLE_9\\007'; sleep 2"))
    (is-true (pump-until tv (lambda () (equal "MY_TITLE_9" (revision-term::tv-title tv)))))))

(test cursor-shape
  "A DECSCUSR sequence (CSI 4 SP q) switches the cursor shape to underline."
  (with-terminal (tv '("/bin/sh" "-c" "printf '\\033[4 q'; sleep 2"))
    (is-true (pump-until tv (lambda () (eq :underline (revision-term::tv-cursor-shape tv)))))))

;;; --- improvement 6: text selection extraction -------------------------------

(test selection-text
  "A stream selection over the live grid extracts the right text."
  (with-terminal (tv '("/bin/sh" "-c" "printf 'hello world'; sleep 2"))
    (is-true (pump-until tv (lambda () (search "hello world" (grid-text tv)))))
    ;; row 0 holds "hello world"; select cols 0..4 -> "hello"
    (let ((nhist (length (revision-term::tv-history tv))))
      (setf (revision-term::tv-sel-anchor tv) (cons nhist 0)
            (revision-term::tv-sel-point tv)  (cons nhist 4))
      (is (string= "hello" (revision-term::tv-selection-text tv))))))

;;; --- improvement 7: scrollback push -----------------------------------------

(test scrollback-grows
  "Output longer than the screen pushes lines into the scrollback ring
(sb_pushline), and scrolling back exposes an earlier line."
  (with-terminal (tv '("/bin/sh" "-c" "for i in $(seq 1 60); do echo line$i; done; sleep 3")
                     :rows 10 :cols 40)
    (is-true (pump-until tv (lambda () (search "line60" (grid-text tv)))))
    (is (plusp (length (revision-term::tv-history tv))) "scrollback captured lines")
    ;; an early line (pushed off the top of the 10-row screen) is in the ring
    (is-true (find "line3" (revision-term::tv-history tv)
                   :key (lambda (l) (revision-term::tv-line-string tv l))
                   :test #'string=)
             "early output is retained in scrollback")))

;;; --- improvement 1: combining marks fold into one grapheme cluster ----------

(test combining-marks
  "A base letter + combining accent (e + U+0301) becomes a single interned
grapheme cluster, not just the base glyph."
  (with-terminal (tv '("/bin/sh" "-c" "printf 'e\\314\\201'; sleep 2"))
    (is-true (pump-until tv (lambda () (search "e" (grid-text tv)))))
    (let ((code (cell-code-at tv 0 0)))
      (is-true (revision::cluster-code-p code))
      (is (= 2 (length (revision-term::%code-string code)))))))

;;; --- improvement 2: text styles (underline) reach the attribute -------------

(test text-styles
  "An SGR underline attribute is carried on the cell's revision attribute."
  (with-terminal (tv '("/bin/sh" "-c" "printf '\\033[4mU'; sleep 2"))
    (is-true (pump-until tv (lambda () (search "U" (grid-text tv)))))
    (is (logtest (revision::attr-rgb-style (cell-attr-at tv 0 0))
                 revision::+style-underline+))))

;;; --- improvement 3: 24-bit colour fidelity ----------------------------------

(test color-fidelity
  "A 24-bit SGR foreground resolves to exactly that RGB on the cell attribute."
  (with-terminal (tv '("/bin/sh" "-c" "printf '\\033[38;2;10;20;30mX'; sleep 2"))
    (is-true (pump-until tv (lambda () (search "X" (grid-text tv)))))
    (is (= (revision:pack-rgb 10 20 30) (revision:attr-rgb-fg (cell-attr-at tv 0 0))))))

;;; --- improvement 4: OSC 52 sets the clipboard -------------------------------

(test osc52-clipboard
  "A program using OSC 52 copies to the clipboard (base64 \"Q0xJUF9PSw==\" =>
\"CLIP_OK\")."
  (let ((revision-term::*terminal-clipboard* ""))
    (with-terminal (tv '("/bin/sh" "-c" "printf '\\033]52;c;Q0xJUF9PSw==\\007'; sleep 2"))
      (is-true (pump-until tv (lambda ()
                                (string= "CLIP_OK" revision-term::*terminal-clipboard*)))))))

;;; --- improvement 6: the damage-driven cache renders correctly ---------------

(test render-via-cache
  "DRAW renders the live screen through the damage-driven row cache into the
screen back buffer (not just a direct vterm read)."
  (let ((s (revision::make-screen)))
    (revision::screen-resize s 80 24)
    (let ((revision:*screen* s))
      (with-terminal (tv '("/bin/sh" "-c" "printf 'CACHE_OK'; sleep 2"))
        (is-true (pump-until tv (lambda () (search "CACHE_OK" (grid-text tv)))))
        (revision-term::draw tv)                       ; live screen -> cache -> back buffer
        (let ((str (coerce (loop for c below 8
                                 for cell = (aref (revision::screen-back s) c)
                                 collect (code-char (revision::cell-char-code cell)))
                           'string)))
          (is (string= "CACHE_OK" str)))))))

;;; --- improvement 4: reverse video swaps fg/bg deterministically ------------

(test reverse-video
  "SGR reverse swaps fg/bg on the attribute (not left to the host terminal's
SGR 7), and clears the reverse style bit."
  (with-terminal (tv '("/bin/sh" "-c" "printf '\\033[7mR'; sleep 2"))
    (is-true (pump-until tv (lambda () (search "R" (grid-text tv)))))
    (let ((attr (cell-attr-at tv 0 0)))
      ;; default fg is light grey (192) on black bg; reversed => black on grey
      (is (= (revision:pack-rgb 0 0 0)       (revision:attr-rgb-fg attr)))
      (is (= (revision:pack-rgb 192 192 192) (revision:attr-rgb-bg attr)))
      (is-false (logtest (revision::attr-rgb-style attr) revision::+style-reverse+)))))

;;; --- improvement 5: text style survives the sb_popline round-trip -----------

(test style-survives-popline
  "packed->cell (sb_popline) reconstructs the style bits, so a restored
scrollback cell keeps its underline through a round-trip."
  (with-terminal (tv '("/bin/sh" "-c" "sleep 2"))
    (let ((packed (revision::cell-make-code
                   (char-code #\Z)
                   (revision:rgb-attr (revision:pack-rgb 10 20 30) (revision:pack-rgb 0 0 0)
                                      revision::+style-underline+))))
      (revision-term::packed->cell (revision-term::tv-cell tv) packed)   ; -> VTermScreenCell
      (multiple-value-bind (code attr) (revision-term::cell->packed tv (revision-term::tv-cell tv))
        (is (= (char-code #\Z) code))
        (is (= (revision:pack-rgb 10 20 30) (revision:attr-rgb-fg attr)))
        (is (logtest (revision::attr-rgb-style attr) revision::+style-underline+))))))

;;; --- regression: resizing rows never overruns the dirty-row vector ----------

(test resize-rows-no-overflow
  "vterm_set_size fires the damage callback during the resize; the dirty-row
vector must already be the new size (else marking damaged rows overruns it --
the crash seen when a desktop tiled a terminal taller)."
  (let ((s (revision::make-screen)))
    (revision::screen-resize s 40 30)
    (let ((revision:*screen* s))
      (with-terminal (tv '("/bin/sh" "-c" "for i in $(seq 1 30); do echo row$i; done; sleep 3")
                         :cols 40 :rows 24)
        (is-true (pump-until tv (lambda () (search "row30" (grid-text tv)))))
        (setf (revision:view-bounds tv) (revision::make-trect 0 0 40 10))   ; shrink
        (finishes (revision-term::draw tv))
        (is (= 10 (length (revision-term::tv-dirty-rows tv))))
        (setf (revision:view-bounds tv) (revision::make-trect 0 0 40 30))   ; grow (fires damage)
        (finishes (revision-term::draw tv))
        (is (= 30 (length (revision-term::tv-dirty-rows tv))))
        (is (= 30 (revision-term::tv-rows tv)))))))

;;; --- improvement 6: scroll shifts the cache instead of re-polling all -------

(test scroll-shifts-cache
  "A full-screen scroll is handled by moverect (shifting the cache), so only the
newly-exposed row is marked dirty -- not every row."
  (let ((s (revision::make-screen)))
    (revision::screen-resize s 20 5)
    (let ((revision:*screen* s))
      (with-terminal (tv '("/bin/sh" "-c"
                           "for i in 1 2 3 4 5; do echo r$i; done; sleep 0.4; echo NEWLINE; sleep 2")
                         :rows 5 :cols 20)
        (is-true (pump-until tv (lambda () (search "r5" (grid-text tv)))))
        (revision-term::draw tv)                        ; render -> cache clean (0 dirty)
        (is-true (pump-until tv (lambda () (search "NEWLINE" (grid-text tv)))))
        ;; the scroll dirtied fewer than all 5 rows (moverect shifted the rest)
        (is (< (loop for b across (revision-term::tv-dirty-rows tv) sum b) 5))
        ;; and the shifted cache still renders exactly what vterm holds
        (revision-term::draw tv)
        (is-true
         (loop for r below 5 always
               (string= (coerce (loop for c below 20
                                      collect (code-char (revision::cell-char-code
                                                          (aref (revision::screen-back s) (+ c (* r 20))))))
                                'string)
                        (coerce (loop for c below 20
                                      collect (cell-char (revision-term::tv-vscreen tv)
                                                         (revision-term::tv-cell tv) r c))
                                'string))))))))

;;; --- correctness: double / curly underline are distinguished ----------------

(test underline-variants
  "SGR 21 / 4:3 are carried as double / curly underline, not collapsed to single."
  (with-terminal (tv '("/bin/sh" "-c" "printf '\\033[21mD\\033[0m \\033[4:3mC'; sleep 2"))
    (is-true (pump-until tv (lambda () (search "D" (grid-text tv)))))
    (let ((d (cell-attr-at tv 0 0))    ; 'D' double underline
          (c (cell-attr-at tv 0 2)))   ; 'C' curly underline
      (is (logtest (revision::attr-rgb-style d) revision::+style-underline+))
      (is (logtest (revision::attr-rgb-style d) revision::+style-uline-double+))
      (is (logtest (revision::attr-rgb-style c) revision::+style-uline-curly+)))))

;;; --- correctness: clearing scrollback (CSI 3J) empties the ring --------------

(test scrollback-clear
  "When the child clears its scrollback (CSI 3J), sb_clear empties our history
ring -- no stale lines left behind."
  (with-terminal (tv '("/bin/sh" "-c"
                       "for i in $(seq 1 40); do echo l$i; done; sleep 0.4; printf '\\033[3J'; sleep 2")
                     :rows 10 :cols 20)
    (is-true (pump-until tv (lambda () (plusp (length (revision-term::tv-history tv))))))
    (is-true (pump-until tv (lambda () (zerop (length (revision-term::tv-history tv))))))))

;;; --- correctness: double-width glyphs claim two cells -----------------------

(defun row-string (tv row)
  "Row ROW of the emulated grid as a right-trimmed string (direct vterm read)."
  (string-right-trim
   '(#\Space)
   (coerce (loop for c below (revision-term::tv-cols tv)
                 collect (cell-char (revision-term::tv-vscreen tv) (revision-term::tv-cell tv) row c))
           'string)))

(test wide-char-width
  "A double-width glyph (CJK) reports width 2 and, when rendered, claims two
cells: the glyph then the +wide-cont+ sentinel."
  (let ((s (revision::make-screen))
        (cmd (list "/bin/sh" "-c" (format nil "printf '~ax'; sleep 2" (code-char #x4e16)))))  ; 世 + x
    (revision::screen-resize s 20 4)
    (let ((revision:*screen* s))
      (with-terminal (tv cmd :rows 4 :cols 20)
        (is-true (pump-until tv (lambda () (search "x" (grid-text tv)))))
        (revision-term::vterm-screen-get-cell (revision-term::tv-vscreen tv) 0 0 (revision-term::tv-cell tv))
        (is (= 2 (nth-value 2 (revision-term::cell->packed tv (revision-term::tv-cell tv)))))
        (revision-term::draw tv)
        (is (= #x4e16 (revision::cell-char-code (aref (revision::screen-back s) 0))))
        (is (= revision::+wide-cont+ (revision::cell-char-code (aref (revision::screen-back s) 1))))
        (is (= (char-code #\x) (revision::cell-char-code (aref (revision::screen-back s) 2))))))))

(test selection-over-wide-char
  "Selecting across a double-width glyph extracts it cleanly (no crash on the
right-half sentinel, and the continuation column contributes nothing)."
  (with-terminal (tv (list "/bin/sh" "-c" (format nil "printf '~ax'; sleep 2" (code-char #x4e16)))
                     :cols 20 :rows 4)
    (is-true (pump-until tv (lambda () (search "x" (grid-text tv)))))
    (let ((nhist (length (revision-term::tv-history tv))))
      (setf (revision-term::tv-sel-anchor tv) (cons nhist 0)     ; 世 (cols 0-1) + x (col 2)
            (revision-term::tv-sel-point tv)  (cons nhist 2))
      (is (string= (format nil "~ax" (code-char #x4e16))
                   (revision-term::tv-selection-text tv))))))

;;; --- correctness: content reflows when the terminal is resized --------------

(test reflow-on-resize
  "With reflow enabled, a wrapped line re-flows onto one row when the terminal
is widened."
  (with-terminal (tv '("/bin/sh" "-c" "printf 'ABCDEFGHIJKLMNOP'; sleep 3") :rows 4 :cols 10)
    (is-true (pump-until tv (lambda () (search "KLMNOP" (grid-text tv)))))
    (is (string= "ABCDEFGHIJ" (row-string tv 0)))              ; wrapped at width 10
    (setf (revision:view-bounds tv) (revision::make-trect 0 0 20 4))
    (revision-term::terminal-ensure-size tv)                   ; widen -> reflow
    (is (string= "ABCDEFGHIJKLMNOP" (row-string tv 0)))))

;;; --- correctness: conceal (SGR 8) renders blank -----------------------------

(test conceal-blanks-text
  "Concealed text (SGR 8) renders as blank, though the underlying cell still
holds the character."
  (with-terminal (tv '("/bin/sh" "-c" "printf '\\033[8mHIDDEN'; sleep 2"))
    (is-true (pump-until tv (lambda () (search "HIDDEN" (grid-text tv)))))  ; raw chars still 'H'..
    (revision-term::vterm-screen-get-cell (revision-term::tv-vscreen tv) 0 0 (revision-term::tv-cell tv))
    (is (= 32 (nth-value 0 (revision-term::cell->packed tv (revision-term::tv-cell tv)))))))  ; but blanked

;;; --- correctness: a selection tracks history trimming -----------------------

(test selection-tracks-history-trim
  "When the scrollback ring drops its oldest line, history-row selection
endpoints shift to keep tracking; live-row endpoints don't move; a selection
that scrolls off the top is dropped."
  (with-terminal (tv '("/bin/sh" "-c" "sleep 3"))
    ;; history-row selection (nhist = 5): rows 2..3 shift down to 1..2
    (setf (revision-term::tv-sel-anchor tv) (cons 2 0)
          (revision-term::tv-sel-point tv)  (cons 3 4))
    (revision-term::tv-shift-selection-on-trim tv 5)
    (is (equal '(1 . 0) (revision-term::tv-sel-anchor tv)))
    (is (equal '(2 . 4) (revision-term::tv-sel-point tv)))
    ;; live-row selection (rows >= nhist) is untouched
    (setf (revision-term::tv-sel-anchor tv) (cons 7 0)
          (revision-term::tv-sel-point tv)  (cons 7 3))
    (revision-term::tv-shift-selection-on-trim tv 5)
    (is (equal '(7 . 0) (revision-term::tv-sel-anchor tv)))
    ;; a selection on the dropped top line is cleared
    (setf (revision-term::tv-sel-anchor tv) (cons 0 0)
          (revision-term::tv-sel-point tv)  (cons 0 2))
    (revision-term::tv-shift-selection-on-trim tv 5)
    (is-false (revision-term::tv-sel-anchor tv))))

;;; --- image dump: the hook tears down live terminals -------------------------

(test image-dump-hook
  "The image-dump hook stops every live terminal -- joining its reader thread
and freeing its foreign state -- so save-lisp-and-die sees a single thread and a
clean heap."
  (with-terminal (tv '("/bin/sh" "-c" "sleep 5"))
    (is-true (member tv revision-term::*live-terminals*))
    (is-true (revision-term::terminal-alive-p tv))
    (revision-term::shutdown-all-terminals)             ; what the dump hook runs
    (is-false (revision-term::terminal-alive-p tv))
    (is-false (revision-term::tv-vt tv))                 ; foreign state freed
    (is-false (revision-term::tv-reader tv))             ; reader thread joined + cleared
    (is-false (member tv revision-term::*live-terminals*))))

;;; --- runner -----------------------------------------------------------------

(defun run ()
  ;; never touch the developer's real OS clipboard while testing
  (let ((revision-term::*use-system-clipboard* nil))
    (let ((results (run! 'revision-term)))
      (unless results (sb-ext:exit :code 1))
      results)))
