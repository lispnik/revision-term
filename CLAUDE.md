# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`revision-term` is a reusable **terminal-emulator widget** for the [`revision`](../revision)
CLOS-native text-mode UI framework. A `terminal-view` is a `revision` `view` subclass that
runs a real child process (a shell, `vi`, `top`, …) on a pseudo-terminal, emulates the terminal
with **libvterm** (a C library, via CFFI), and renders the emulated screen into `revision` cells —
so a live terminal can be embedded in any `revision` window. SBCL-only.

## Building, testing, running

The project is loaded through `setup.lisp`, which puts the sibling checkouts on the ASDF registry
(there is nothing to `install`). Never `(asdf:load-system :revision-term)` without loading
`setup.lisp` first.

```sh
make build       # compile + load the whole system (a build check; expect no warnings)
make test        # headless FiveAM suite — no tty needed; the main test signal
make smoke       # end-to-end: drive the full-screen widget under a real pty (needs python3)
make image-test  # save-lisp-and-die with a live terminal, then restore & run a fresh one
make run         # your $SHELL full-screen in a revision window
make demo        # self-driving desktop showcase (terminals + a Lisp REPL as managed windows)
```

Run a **single** test from a REPL (there is no make target for it):

```lisp
(load "setup.lisp")
(asdf:load-system :revision-term/test)
(fiveam:run! 'revision-term-tests::wide-char-width)   ; one test by name
```

Test names are the `(test NAME ...)` forms in `tests/tests.lisp`. `make test` calls
`revision-term-tests:run`, which runs the whole suite and exits non-zero on failure.

## Required environment

- **SBCL** (uses `sb-thread`, `sb-ext`, `sb-alien`).
- **libvterm** — `brew install libvterm` (macOS; installed under `/opt/homebrew/lib`, which
  `ensure-libvterm` adds to the dyld search path) or your distro's `libvterm-dev`.
- **Sibling checkouts next to this one**: `../revision` (the framework) and
  `../cffi-callback-closures` (which bundles its own `cffi` / `cffi-libffi` under `ocicl/`).
  `setup.lisp` assumes this sibling layout. The framework must be new enough to have text-style
  support in its RGB attributes (`attr-rgb-style`, the style arg to `rgb-attr`/`make-rgb`) —
  older checkouts fail to build; `git pull` them.
- macOS or Linux (POSIX `forkpty`).

## Architecture

Three libraries meet at one widget. The data flow (also drawn in `src/terminal.lisp`'s header):

```
child ──stdout──▶ pty master ──(reader thread: read() only)──▶ run-on-ui
                                                                   │
 UI thread: vterm_input_write ◀──────────────────────────────────┘
            │  libvterm parses the ANSI stream and updates its grid
            ▼
 draw: poll vterm_screen_get_cell for damaged rows ─▶ revision cells

 keystroke ─▶ vterm_keyboard_* ─▶ (output closure) ─▶ pty master ─▶ child
```

Source files (`:serial t`, load in this order):

- **`src/package.lisp`** — the `revision-term` package (`:use #:cl #:revision`). Exports the
  public API: `terminal-view`, `terminal-window`, `make-terminal`, `run-terminal`,
  `terminal-alive-p`, `terminal-send-string`, `terminal-child-pid`, `*terminal-keys*`.
- **`src/vterm.lisp`** — the CFFI binding to libvterm. Only the slice we need. Struct layouts
  (`vterm-screen-cell`, `vterm-color`, `vterm-string-fragment`) are hand-defined to match the C
  ABI — no cffi-grovel.
- **`src/pty.lisp`** — `forkpty`-based child spawning, argv/envp, and the variadic `ioctl` resize.
- **`src/terminal.lisp`** — the bulk: the `terminal-view` class, `draw`, `handle-event`, the
  callback closures, scrollback, selection, clipboard. Start here for widget behavior.
- **`src/app.lisp`** — `make-terminal` / `run-terminal` window builders.

### Design invariants (violating these breaks things subtly)

- **Only the UI thread touches libvterm.** The reader thread does *nothing* but the blocking
  `read()`; it appends bytes under `tv-in-lock` and posts at most **one** drain thunk per burst
  (`tv-in-posted`) via `run-on-ui`. All `vterm_*` calls — and therefore all libvterm callbacks —
  run on the UI thread, so no locks guard libvterm itself. This mirrors the framework's "only the
  UI thread touches the model" rule. `sb-thread:make-thread` does **not** inherit dynamic
  bindings, so anything the reader-driven callbacks read (e.g. `*ui-thread*`) must be set globally.

- **Render by polling, not by damage callbacks pushing pixels.** libvterm's `damage` / `moverect`
  / `movecursor` callbacks pass `VTermRect` / `VTermPos` **by value**, which the closure layer
  does not marshal. So `draw` re-polls `vterm_screen_get_cell`. To keep it cheap, the `damage`
  callback (flattened to `:uint64` args) marks changed rows in `tv-dirty-rows`; `draw` re-polls
  only dirty rows into `tv-cache` and blits the rest. `moverect` **shifts** cached rows so a
  scroll re-polls only the newly-exposed row. **Allocate the cache before `vterm_set_size`** —
  set-size fires `damage` synchronously against the new (possibly larger) row range.

- **By-value structs are packed into integer args.** `VTermPos` (2 ints, 8 bytes) → one
  `:uint64` (`pack-pos`: row in low 32, col in high 32) — ABI-correct for an all-integer struct
  in a single register on arm64/x86-64. Same trick flattens `VTermRect` (→ two `:uint64`s) for
  `damage`, four for `moverect`, and `VTermStringFragment` for the OSC-52 selection callback.

- **`ioctl(TIOCSWINSZ)` must go through a *variadic* libffi call interface.** `ioctl` is variadic;
  on Apple arm64 the variadic ABI passes the pointer arg on the stack, so a plain
  `cffi:foreign-funcall` (register) is silently dropped and the resize never reaches the child.
  `pty.lisp` binds `ffi_prep_cif_var` itself (cffi-libffi only exposes the non-variadic
  `ffi_prep_cif`) and calls `ioctl` through it. The abi enum is `cffi::abi` (a cenum that
  translates `:default-abi`), **not** `cffi::ffi-abi`.

- **`cffi-callback-closures` for per-instance callbacks.** libvterm's `sb_pushline`, `sb_popline`,
  `sb_clear`, `settermprop`, `resize`, `bell`, the `damage`/`moverect` grid callbacks, the OSC-52
  selection `set` callback, and the output callback each must close over **this** terminal's state.
  That is the "N distinct C function pointers, each carrying its own data" case that
  `cffi:defcallback` cannot express — every `terminal-view` mints its own set with
  `make-foreign-callback` in `%install-callbacks`, freed on shutdown.

- **Image dumps require tearing down live terminals first.** `save-lisp-and-die` needs a single
  thread (a live reader thread blocks it) and can't preserve libffi closures or the child.
  Each running terminal registers in `*live-terminals*`; `shutdown-all-terminals` (a
  `uiop:register-image-dump-hook`) tears them all down before the core is written. A restored
  image starts fresh terminals — libvterm reloads and closures re-mint at `terminal-start`.

### Reuse contract

`make-terminal` mirrors the framework's `make-repl`: it returns `(values WINDOW FOCUS OPEN)`,
where `OPEN` (run after layout, so the view has bounds) starts the child and returns a cleanup
thunk. Or drop a raw `terminal-view` into a `stack`/`row` layout and call
`terminal-start` / `terminal-shutdown` on it directly.

## Working notes

- Some `revision` symbols this widget needs are **not exported** — reference them with `revision::`
  (e.g. `revision::mouse-move`, `revision::mouse-up`, `revision::intern-grapheme`,
  `revision::cell-make-code`, `revision::make-screen`). Only `mouse-down`, `mouse-event`,
  `wheel-event`, `key-event` and the like are exported.
- Some fidelity features (text styles, RGB style bitmask, double/curly underline) required
  **extending the `revision` framework itself** (`base/colors.lisp`) in a backward-compatible way.
  Changing style encoding here may mean a matching change over in `../revision`; re-run revision's
  own test suite if you touch its files.
- `chars[0] == 0xFFFFFFFF` marks the **right half of a double-width glyph** — `cell-code` maps any
  out-of-range code point to `+wide-cont+`, which `%code-string` renders as "". Don't call
  `code-char` on a raw cell char without that guard (it crashed on any CJK/emoji).
- The FiveAM tests read libvterm directly (`get_cell`); most do **not** exercise `draw`/the cache
  (the `render-via-cache` test and the python smoke tests do). A green `make test` does not by
  itself prove a rendering change works — run `make smoke` too.
- Beware false-positive smoke tests: SBCL echoes its `--eval` command line in crash backtraces, so
  child-output markers must be computed at runtime (e.g. `$((6*7))`), not literals in the command.
- A focused terminal forwards **all** keys to the child, so host window-management keys don't
  bubble up — drive demos with an in-app autopilot thread (`run-on-ui`), not external keystrokes.
```