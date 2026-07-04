#!/usr/bin/env python3
"""End-to-end smoke test for KEYSTROKE FORWARDING: run the full-screen widget
under a PTY, type "PONG<Enter>", and confirm the child received it (it echoes
GOT-PONG, which can only appear if the keystrokes reached the child process).

Usage:  python3 tests/pty-input-smoke.py     (exit 0 on success)
"""
import os, pty, select, sys, time, termios, struct, fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
LISP = ('(revision-term:run-terminal :command '
        "'(\"/bin/sh\" \"-c\" \"read x; echo GOT-$x; sleep 20\"))")
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
        if (not sent) and (time.time() - t0 > 6):   # shell is up by now
            write(b"PONG\r"); sent = True
        if "GOT-PONG" in buf.decode("utf-8", "replace"):
            got = True; break
    write(b"\x1c")                                    # Ctrl-\ quit
    try: os.close(fd)
    except OSError: pass
    try: os.waitpid(pid, 0)
    except OSError: pass

    print(f"[{'pass' if got else 'FAIL'}] typed 'PONG<Enter>' reached the child (saw GOT-PONG)")
    sys.exit(0 if got else 1)

if __name__ == "__main__":
    main()
