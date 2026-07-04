#!/usr/bin/env python3
"""End-to-end smoke test: run the full-screen terminal widget under a real PTY
and confirm it renders a child process's output, then quits on Ctrl-\\.

Usage:  python3 tests/pty-smoke.py
Exits 0 on success, 1 on failure.
"""
import os, pty, select, sys, time, termios, struct, fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
# The marker is COMPUTED by the child shell ($((6*7)) -> 42), so it can only
# appear if the child actually ran and its output was rendered -- it never
# appears literally in the command line (which sbcl would echo in a backtrace).
MARKER = "READY-42"

LISP = (
    '(revision-term:run-terminal :command '
    "'(\"/bin/sh\" \"-c\" \"echo READY-$((6*7)); sleep 30\"))"
)
ARGS = ["sbcl", "--non-interactive",
        "--load", os.path.join(PROJ, "setup.lisp"),
        "--eval", "(asdf:load-system :revision-term)",
        "--eval", LISP]

def main():
    pid, fd = pty.fork()
    if pid == 0:                     # child: become the sbcl process
        os.chdir(PROJ)
        os.execvp("sbcl", ARGS)
        os._exit(127)

    # parent: give the pty a real size so the widget lays out
    winsz = struct.pack("HHHH", 40, 120, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsz)

    buf = bytearray()
    saw_marker = False
    deadline = time.time() + 40      # sbcl cold-load can be slow
    sent_quit = False
    try:
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                buf += data
            text = buf.decode("utf-8", "replace")
            if (not saw_marker) and MARKER in text:
                saw_marker = True
                time.sleep(0.3)
                os.write(fd, b"\x1c")   # Ctrl-\  -> quit
                sent_quit = True
                deadline = min(deadline, time.time() + 8)
        # drain a little more after quit
        if sent_quit:
            t2 = time.time() + 3
            while time.time() < t2:
                r, _, _ = select.select([fd], [], [], 0.3)
                if not r:
                    break
                try:
                    d = os.read(fd, 65536)
                except OSError:
                    break
                if not d:
                    break
                buf += d
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass

    ok = saw_marker
    print(f"[{'pass' if ok else 'FAIL'}] rendered child marker {MARKER!r} on the alt-screen")
    print(f"[{'pass' if sent_quit else 'FAIL'}] widget accepted Ctrl-\\ quit")
    sys.exit(0 if (ok and sent_quit) else 1)

if __name__ == "__main__":
    main()
