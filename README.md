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
| `Shift-PageUp` / `Shift-PageDown` | scroll the scrollback |
| `Shift-Home` / `Shift-End` | jump to the top / back to live |
| mouse wheel | scroll the scrollback |

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
  the blocking `read()` and hands the bytes over with `run-on-ui`; all
  `vterm_*` calls (and therefore all callbacks) run on the UI thread, so no
  locks are needed — the same rule the framework's REPL follows.
- **Colours** are resolved to true RGB (`vterm_screen_convert_color_to_rgb`)
  and drawn with `revision`'s 24-bit attributes, so themes render exactly.
- **Scrollback** is a ring of packed-cell lines fed by the `sb_pushline`
  closure; the viewport is bottom-aligned over `history ++ live screen`.

## Test

```sh
make test    # headless: libvterm bindings + a real PTY round-trip (no tty)
make smoke   # end-to-end: drives the full-screen widget under a pty (python3)
```

`make test` creates a `VTerm`, writes bytes, and reads the grid back (proving
the by-value `get_cell` and cell-struct layout), then spawns a child on a real
pty and checks its output reaches the emulated grid. `make smoke` runs the
actual full-screen program under a pseudo-terminal and verifies a child's
output renders and that typed keystrokes reach the child.

## Caveat

Dynamic window resize uses `ioctl(TIOCSWINSZ)`, which is variadic; on Apple
arm64 a plain `cffi:foreign-funcall` may not pass the pointer argument the way
the variadic ABI expects (the same wrinkle noted in
`cffi-callback-closures`' libcurl example). The **initial** size is set through
`forkpty`'s `winp` and is unaffected, so a freshly opened terminal is always the
right size; only live re-sizing of an already-running child may not propagate on
that platform.

## License

MIT.
