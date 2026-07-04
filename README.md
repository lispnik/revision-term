# revision-term — a reusable terminal widget for the `revision` framework

A **terminal-emulator window** for the [`revision`](../revision) CLOS-native
text-mode UI framework. It runs a real child process (your shell, `vi`, `top`,
anything) on a pseudo-terminal, emulates the terminal with **libvterm**, and
renders the emulated screen into a `revision` view — so a live terminal can
live inside a `revision` window and be **embedded in any `revision`
application**, exactly the way the framework's REPL/editor windows are.

```lisp
(revision-term:run-terminal)                       ; your $SHELL, full-screen
(revision-term:run-terminal :command '("/usr/bin/vi"))
```

![reuse]: a `terminal-view` is just another focusable `revision` view — drop it
in a `stack`/`row`, give it bounds, and it hosts a shell.

## What it demonstrates

Three libraries meeting at one widget:

- **`revision`** provides the view/window/event/theming machinery and the
  worker→UI bridge. `terminal-view` is a `view` subclass: it implements `draw`
  and `handle-event` and nothing about the framework had to change.
- **libvterm** (a C library) does the hard part — parsing the ANSI/VT stream
  the child emits into a grid of cells. We bind the slice we need via **CFFI**.
- **[`cffi-callback-closures`](../cffi-callback-closures)** supplies libvterm's
  per-instance callbacks. libvterm wants a *scrollback-push* callback, a
  *cursor-visibility* callback, a *resize* callback and an *output* callback,
  each of which must close over **this** terminal's state. That is precisely the
  "N distinct C function pointers, each carrying its own data" case that
  `cffi:defcallback` cannot express and libffi closures can — every
  `terminal-view` mints its own set with `make-foreign-callback`.

## Requirements

- **SBCL** (uses `sb-thread`, `sb-ext`).
- **libvterm** — `brew install libvterm` (macOS) or your distro's `libvterm`.
- The sibling checkouts next to this one:
  `../revision` and `../cffi-callback-closures` (which bundles its own `cffi` /
  `cffi-libffi` under `ocicl/`). `setup.lisp` puts all of them on the ASDF
  registry, so there is nothing else to install.
- macOS or Linux (POSIX `forkpty`).

## Run it

```sh
make run          # your $SHELL full-screen in a revision window
# or:
sbcl --script examples/run-shell.lisp
```

Keys, once inside:

| Key | Action |
|-----|--------|
| *(anything)* | forwarded to the child process |
| `Ctrl-\` | close the terminal window (full-screen host) |
| `Shift-Insert` | paste (bracketed) from the clipboard |
| `Shift-PageUp` / `Shift-PageDown` | scroll the scrollback |
| `Shift-Home` / `Shift-End` | jump to the top / back to live |
| mouse wheel | scroll the scrollback (or forwarded when the app grabs the mouse) |
| mouse drag | select text; on release it's copied (to the macOS clipboard too) |

The child process drives more than text: it can **grab the mouse** (vim, htop,
tmux get real mouse events), set the **window title** (OSC — reflected on the
window frame), pick the **cursor shape** (block/underline/bar), copy to the
**system clipboard** (OSC 52), and toggle the alternate screen. When the child
exits, the widget shows a **`[process exited: N]`** banner instead of freezing,
and window **resize** is propagated to the child.

Rendering is faithful: exact **24-bit colour**, text **styles** (bold, italic,
single/double/curly **underline**, blink, reverse, strike), **double-width**
CJK/emoji, and **combining marks / grapheme clusters** (an accent or ZWJ emoji
renders as one glyph). Reverse video is applied by swapping fg/bg so it looks the
same on any host terminal, **concealed** text (SGR 8) renders blank, clearing the
scrollback (CSI 3J) empties the ring, and a live text selection keeps tracking
its content as the scrollback ring trims. The
clipboard uses `pbcopy`/`pbpaste` on macOS and `wl-copy`/`xclip`/`xsel` on
Linux.

## Embed it in your own app

`make-terminal` mirrors the framework's `make-repl` builder — it returns
`(values WINDOW FOCUS OPEN)`, where `OPEN` (run after layout) starts the child
and returns a cleanup thunk:

```lisp
(multiple-value-bind (win focus open)
    (revision-term:make-terminal :command '("/bin/sh")
                                 :title " shell "
                                 :on-exit (lambda (tv) (declare (ignore tv))
                                            (format *debug-io* "child exited~%")))
  ;; host it full-screen ...
  (revision:run-view win :focus focus :open open))
  ;; ... or hand (win focus open) to a desktop to open it as a managed window.
```

Or use the raw `terminal-view` directly inside a layout you build with the
framework's `stack`/`row`, then call `revision-term::terminal-start` on it once
it has bounds (and `terminal-shutdown` when done).

Public API (`revision-term` package): `terminal-view`, `terminal-window`,
`make-terminal`, `run-terminal`, `terminal-alive-p`, `terminal-child-pid`,
`terminal-send-string`, `*terminal-keys*`.

## How it works

```
child ──stdout──▶ pty master ──(reader thread: read() only)──▶ run-on-ui
                                                                   │
 UI thread: vterm_input_write ◀──────────────────────────────────┘
            │  libvterm parses the stream and updates its grid
            ▼
 draw: poll vterm_screen_get_cell for every visible cell ─▶ revision cells

 keystroke ─▶ vterm_keyboard_* ─▶ (output closure) ─▶ pty master ─▶ child
```

Design choices worth calling out:

- **Render by polling** `vterm_screen_get_cell` each frame. libvterm's
  *damage* / *moverect* / *movecursor* callbacks pass `VTermRect` / `VTermPos`
  **by value**, which the closure layer does not yet marshal — so we leave those
  NULL and just read the grid. `VTermPos` (two ints) is packed into a `:uint64`
  for the one by-value argument on the hot path, which is ABI-correct on arm64
  and x86-64.
- **Only the UI thread touches libvterm.** The reader thread does nothing but
  the blocking `read()`; it appends bytes to a lock-guarded buffer and posts at
  most **one** drain thunk per burst (so a flood of output isn't one closure per
  read). The drain feeds all pending bytes in a single `vterm_input_write`; all
  `vterm_*` calls (and therefore all callbacks) run on the UI thread, so no
  locks guard libvterm itself — the same rule the framework's REPL follows.
- **Draw re-polls only damaged rows.** libvterm's `damage` callback (a by-value
  `VTermRect`, flattened into two `:uint64`s like `VTermPos`) marks changed rows
  in a per-row dirty set; `draw` re-polls (`get_cell` + colour conversion) only
  those rows into a packed-cell cache and blits the rest. A static screen costs
  zero `get_cell` calls per frame; a one-line update re-polls one row, not all.
  Scrolls go through the `moverect` callback (two by-value `VTermRect`s → four
  `:uint64`s), which **shifts the cached rows** to match, so a scroll re-polls
  only the newly-exposed row rather than the whole screen.
- **Colours** are resolved to true RGB (`vterm_screen_convert_color_to_rgb`)
  and drawn with `revision`'s 24-bit attributes, so themes render exactly.
- **Scrollback** is a ring of packed-cell lines fed by the `sb_pushline`
  closure; the viewport is bottom-aligned over `history ++ live screen`.

## Test

```sh
make test    # headless FiveAM suite (no tty needed)
make smoke   # end-to-end: drives the full-screen widget under a pty (python3)
```

`make test` runs a [FiveAM](https://github.com/lispci/fiveam) suite that creates
a `VTerm`, writes bytes and reads the grid back (proving the by-value `get_cell`
and cell-struct layout), spawns a child on a real pty and checks its output
reaches the grid, then covers each feature: **resize** propagates to the child
(`stty size` changes), the child is **reaped** with the right exit status, an
enabled **mouse** mode is picked up, an **OSC title** and **DECSCUSR cursor
shape** are applied, a **text selection** extracts the right string, output
longer than the screen fills the **scrollback** ring, a **combining mark** folds
into one grapheme cluster, a **double-width** glyph claims two cells, content
**reflows** when the terminal is widened, an SGR **underline** reaches the
attribute, a 24-bit SGR **colour** resolves exactly, and **OSC 52** sets the
clipboard. `make smoke` runs the
actual full-screen program under a pseudo-terminal and verifies rendering,
keystroke delivery, and the process-exited banner.

## Saving an image

`save-lisp-and-die` requires a single thread and cannot preserve libffi closures
or a child process, so a live terminal's reader thread would block a dump. Each
running terminal registers itself, and an **image-dump hook** tears them all down
(kills the child, joins the reader, frees foreign state) before the core is
written — so dumping works, and a **restored image can start fresh terminals**
(libvterm is reloaded and new closures are minted at `terminal-start`).
`make image-test` proves both ends.

## Resize and the variadic `ioctl`

`TIOCSWINSZ` is delivered by `ioctl`, which is variadic; on Apple arm64 the
variadic ABI passes the pointer argument on the stack, so a plain
`cffi:foreign-funcall` (which uses a register) is silently dropped by the kernel
— the resize never reaches the child (the exact wrinkle noted in
`cffi-callback-closures`' libcurl example). `revision-term` fixes this by
calling `ioctl` through a real **variadic libffi call interface**
(`ffi_prep_cif_var`), reusing the `cffi-libffi` machinery that is already loaded.
So dynamic resize propagates correctly (there's a test for it), and the initial
size is set through `forkpty`'s `winp`.

## License

MIT.
