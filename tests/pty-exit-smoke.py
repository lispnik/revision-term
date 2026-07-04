#!/usr/bin/env python3
"""End-to-end smoke test for the process-exited banner (#3): run a child that
exits on its own while the window stays open, and confirm the widget renders a
"[process exited: N ...]" banner instead of just freezing.

Usage:  python3 tests/pty-exit-smoke.py     (exit 0 on success)
"""
import os, pty, select, sys, time, termios, struct, fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
LISP = ('(revision-term:run-terminal :command '
        "'(\"/bin/sh\" \"-c\" \"echo done; exit 5\"))")
ARGS = ["sbcl", "--non-interactive",
        "--load", os.path.join(PROJ, "setup.lisp"),
        "--eval", "(asdf:load-system :revision-term)",
        "--eval", LISP]

def main():
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(PROJ)
        os.execvp("sbcl", ARGS)
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    buf = bytearray(); seen = False
    deadline = time.time() + 40
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: break
            if not d: break
            buf += d
        if "process exited" in buf.decode("utf-8", "replace"):
            seen = True; break
    try: os.write(fd, b"\x1c")
    except OSError: pass
    try: os.close(fd)
    except OSError: pass
    try: os.waitpid(pid, 0)
    except OSError: pass

    print(f"[{'pass' if seen else 'FAIL'}] rendered the '[process exited]' banner when the child exited")
    sys.exit(0 if seen else 1)

if __name__ == "__main__":
    main()
