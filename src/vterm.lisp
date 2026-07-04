;;;; vterm.lisp --- CFFI bindings to libvterm (the terminal-emulation library).
;;;;
;;;; We bind only the slice of libvterm the widget needs: build a VTerm, push
;;;; child bytes in (`vterm_input_write'), read the emulated grid back out cell
;;;; by cell (`vterm_screen_get_cell'), turn keystrokes into the bytes a real
;;;; terminal would send (`vterm_keyboard_*'), and register the handful of
;;;; screen callbacks whose signatures are scalar/pointer-only (so they can be
;;;; libffi *closures* via cffi-callback-closures -- see terminal.lisp).
;;;;
;;;; The by-value struct callbacks (damage / moverect / movecursor, which take
;;;; VTermRect / VTermPos by value) are deliberately left unbound: we render by
;;;; *polling* the grid each frame instead, which needs no by-value callback.

(in-package #:revision-term)

;;; --- the shared library -----------------------------------------------------

(cffi:define-foreign-library libvterm
  (:darwin (:or "libvterm.0.dylib" "libvterm.dylib"))
  (:unix   (:or "libvterm.so.0" "libvterm.so"))
  (t (:default "libvterm")))

(defun ensure-libvterm ()
  "Load libvterm, adding Homebrew's lib dir to the search path first (Apple
Silicon installs it under /opt/homebrew/lib, which is not always on the default
dyld search path)."
  (dolist (d '(#p"/opt/homebrew/lib/" #p"/usr/local/lib/" #p"/usr/lib/"))
    (pushnew d cffi:*foreign-library-directories* :test #'equal))
  (unless (cffi:foreign-library-loaded-p 'libvterm)
    (cffi:use-foreign-library libvterm)))

;;; --- foreign types ----------------------------------------------------------

(cffi:defcstruct (vterm-pos :conc-name vterm-pos-)
  (row :int)
  (col :int))

;; VTermColor is a tagged union; after vterm_screen_convert_color_to_rgb the
;; layout is { uint8 type; uint8 red; uint8 green; uint8 blue; }.
(cffi:defcstruct (vterm-color :conc-name vterm-color-)
  (type  :uint8)
  (red   :uint8)
  (green :uint8)
  (blue  :uint8))

;; VTermScreenCell.  `attrs' is a C bitfield struct; we read it as one uint32
;; and pull bits out by hand (bold = bit 0, reverse = bit 5).  The :uint32
;; slot's 4-byte alignment reproduces the pad C inserts after `width'.
(cffi:defcstruct (vterm-screen-cell :conc-name vterm-cell-)
  (chars :uint32 :count 6)
  (width :char)
  (attrs :uint32)
  (fg (:struct vterm-color))
  (bg (:struct vterm-color)))

(defparameter +cell-size+ (cffi:foreign-type-size '(:struct vterm-screen-cell))
  "sizeof(VTermScreenCell); the stride for the sb_pushline cell array.")

;; VTermScreenCallbacks: nine function pointers.  We only fill the ones with
;; scalar/pointer signatures; the by-value ones stay NULL (we poll instead).
(cffi:defcstruct (vterm-screen-callbacks :conc-name vscb-)
  (damage      :pointer)
  (moverect    :pointer)
  (movecursor  :pointer)
  (settermprop :pointer)
  (bell        :pointer)
  (resize      :pointer)
  (sb-pushline :pointer)
  (sb-popline  :pointer)
  (sb-clear    :pointer))

;;; --- VTermKey / VTermModifier (from vterm_keycodes.h) -----------------------

(defconstant +mod-none+  #x00)
(defconstant +mod-shift+ #x01)
(defconstant +mod-alt+   #x02)
(defconstant +mod-ctrl+  #x04)

(defconstant +key-none+       0)
(defconstant +key-enter+      1)
(defconstant +key-tab+        2)
(defconstant +key-backspace+  3)
(defconstant +key-escape+     4)
(defconstant +key-up+         5)
(defconstant +key-down+       6)
(defconstant +key-left+       7)
(defconstant +key-right+      8)
(defconstant +key-ins+        9)
(defconstant +key-del+        10)
(defconstant +key-home+       11)
(defconstant +key-end+        12)
(defconstant +key-pageup+     13)
(defconstant +key-pagedown+   14)
(defconstant +key-function-0+ 256)         ; VTERM_KEY_FUNCTION(n) = 256 + n

;;; --- VTermProp (the few we care about) --------------------------------------

(defconstant +prop-cursorvisible+ 1)

;;; --- functions --------------------------------------------------------------

(cffi:defcfun ("vterm_new" vterm-new) :pointer
  (rows :int) (cols :int))

(cffi:defcfun ("vterm_free" vterm-free) :void
  (vt :pointer))

(cffi:defcfun ("vterm_set_utf8" vterm-set-utf8) :void
  (vt :pointer) (is-utf8 :int))

(cffi:defcfun ("vterm_set_size" vterm-set-size) :void
  (vt :pointer) (rows :int) (cols :int))

(cffi:defcfun ("vterm_input_write" vterm-input-write) :unsigned-long
  (vt :pointer) (bytes :pointer) (len :unsigned-long))

(cffi:defcfun ("vterm_output_set_callback" vterm-output-set-callback) :void
  (vt :pointer) (func :pointer) (user :pointer))

(cffi:defcfun ("vterm_keyboard_unichar" vterm-keyboard-unichar) :void
  (vt :pointer) (c :uint32) (mod :int))

(cffi:defcfun ("vterm_keyboard_key" vterm-keyboard-key) :void
  (vt :pointer) (key :int) (mod :int))

(cffi:defcfun ("vterm_obtain_screen" vterm-obtain-screen) :pointer
  (vt :pointer))

(cffi:defcfun ("vterm_obtain_state" vterm-obtain-state) :pointer
  (vt :pointer))

(cffi:defcfun ("vterm_screen_set_callbacks" vterm-screen-set-callbacks) :void
  (screen :pointer) (callbacks :pointer) (user :pointer))

(cffi:defcfun ("vterm_screen_reset" vterm-screen-reset) :void
  (screen :pointer) (hard :int))

(cffi:defcfun ("vterm_screen_enable_altscreen" vterm-screen-enable-altscreen) :void
  (screen :pointer) (altscreen :int))

(cffi:defcfun ("vterm_screen_set_default_colors" vterm-screen-set-default-colors) :void
  (screen :pointer) (default-fg :pointer) (default-bg :pointer))

(cffi:defcfun ("vterm_screen_convert_color_to_rgb" vterm-screen-convert-color-to-rgb) :void
  (screen :pointer) (col :pointer))

(cffi:defcfun ("vterm_state_set_default_colors" vterm-state-set-default-colors) :void
  (state :pointer) (default-fg :pointer) (default-bg :pointer))

(cffi:defcfun ("vterm_state_get_cursorpos" vterm-state-get-cursorpos) :void
  (state :pointer) (cursorpos :pointer))

;;; vterm_screen_get_cell takes VTermPos *by value*.  A VTermPos is two ints (8
;;; bytes, all-integer); on both arm64 (AAPCS) and x86-64 (SysV) such a struct
;;; is passed in a single general register, identically to a uint64 with row in
;;; the low 32 bits and col in the high 32 bits.  Packing it that way lets us
;;; make the call without libffi by-value marshalling on this per-cell hot path.
(declaim (inline pack-pos))
(defun pack-pos (row col)
  (logior (logand row #xffffffff) (ash (logand col #xffffffff) 32)))

(declaim (inline vterm-screen-get-cell))
(defun vterm-screen-get-cell (screen row col cell)
  "Read the emulated cell at (ROW,COL) into the foreign CELL (a
VTermScreenCell*).  Returns non-zero if the position is valid."
  (cffi:foreign-funcall "vterm_screen_get_cell"
                        :pointer screen
                        :uint64 (pack-pos row col)
                        :pointer cell
                        :int))
