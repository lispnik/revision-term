#!/usr/bin/env python3
r"""End-to-end smoke test for BRACKETED-PASTE FORWARDING: run the full-screen
widget under a PTY, write a bracketed paste (ESC[200~PASTE-OK-42 ESC[201~) to
the outer terminal, and confirm the child received it *still bracketed*.

The child enables bracketed paste (`\033[?2004h`) and reads in raw mode, then
`cat -v` renders control bytes visibly.  libvterm only wraps a paste in the
`\e[200~`/`\e[201~` markers for a child that opted into bracketed paste (as
`claude` does) -- so seeing the `200~` begin marker, the `PASTE-OK-42` payload,
and the `201~` end marker (in order) proves the outer terminal's paste was
parsed into a paste-event, routed to the focused terminal-view, and re-wrapped as
a bracketed paste to the child -- the whole path a dragged file path travels to
reach e.g. `claude`.

Usage:  python3 tests/pty-paste-smoke.py     (exit 0 on success)
"""
import os, pty, select, sys, time, termios, struct, fcntl, re

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
# The child: raw mode (so cat echoes each byte immediately, not line-buffered) +
# enable bracketed paste + cat -v (renders ESC as ^[).  The doubled backslash in
# \\033 survives the Lisp reader (which eats a single backslash) so the child's
# `printf` emits a real ESC and libvterm turns on bracketed paste.
CHILD = r"stty -icanon -echo min 1 time 0; printf '\\033[?2004h'; cat -v; sleep 20"
LISP = ('(revision-term:run-terminal :command '
        "'(\"/bin/sh\" \"-c\" \"" + CHILD + "\"))")
ARGS = ["sbcl", "--non-interactive",
        "--load", os.path.join(PROJ, "setup.lisp"),
        "--eval", "(asdf:load-system :revision-term)",
        "--eval", LISP]

# ESC[200~ <payload> ESC[201~  -- a bracketed paste, as the outer terminal sends
# one (e.g. from a drag-and-drop).
PASTE = b"\x1b[200~PASTE-OK-42\x1b[201~"

# In cat -v's rendering, ESC prints as "^[", so the markers appear as ^[[200~ /
# ^[[201~ with the payload between them (order-preserving, DOTALL for line wraps).
WANT = re.compile(r"200~.*PASTE-OK-42.*201~", re.S)

def main():
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(PROJ)
        os.execvp("sbcl", ARGS)
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    def write(b):
        try: os.write(fd, b)
        except OSError: pass

    buf = bytearray(); sent = got = False
    t0 = time.time(); deadline = t0 + 40
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: break
            if not d: break
            buf += d
        if (not sent) and (time.time() - t0 > 6):   # shell + cat are up by now
            write(PASTE); sent = True
        if WANT.search(buf.decode("utf-8", "replace")):
            got = True; break
    write(b"\x1c")                                    # Ctrl-\ quit
    try: os.close(fd)
    except OSError: pass
    try: os.waitpid(pid, 0)
    except OSError: pass

    print(f"[{'pass' if got else 'FAIL'}] bracketed paste reached the child intact "
          f"(saw ^[[200~ ... PASTE-OK-42 ... ^[[201~)")
    sys.exit(0 if got else 1)

if __name__ == "__main__":
    main()
