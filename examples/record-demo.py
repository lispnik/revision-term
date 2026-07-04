#!/usr/bin/env python3
"""Record examples/demo-defs.lisp (the self-driving desktop) into an asciinema
v2 .cast.  Builds a saved core first so startup is instant and silent (no
compile/load noise in the recording), then runs the demo from it under a PTY and
logs every output chunk, timed from when the alt-screen opens.

Convert with:  agg out.cast out.gif

Usage:  python3 examples/record-demo.py [out.cast] [duration_seconds]
"""
import os, pty, select, time, termios, struct, fcntl, json, sys, signal, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
OUT  = sys.argv[1] if len(sys.argv) > 1 else os.path.join(PROJ, "media", "demo.cast")
DUR  = float(sys.argv[2]) if len(sys.argv) > 2 else 22.0
CORE = os.path.join(PROJ, "media", "demo.core")
COLS, ROWS = 100, 30

def build_core():
    print("building demo core (once)…")
    subprocess.run(
        ["sbcl", "--non-interactive",
         "--load", os.path.join(PROJ, "setup.lisp"),
         "--eval", "(asdf:load-system :revision-term)",
         "--load", os.path.join(HERE, "demo-defs.lisp"),
         "--eval", f'(sb-ext:save-lisp-and-die "{CORE}" :toplevel (quote revision-term::run-demo))'],
        cwd=PROJ, check=True)

def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if not os.path.exists(CORE):
        build_core()

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(PROJ)
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLORTERM"] = "truecolor"
        os.environ["LINES"] = str(ROWS); os.environ["COLUMNS"] = str(COLS)
        os.execvp("sbcl", ["sbcl", "--core", CORE, "--non-interactive"])
        os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    events, start, hard_deadline = [], None, time.time() + DUR + 30
    while time.time() < hard_deadline:
        if start is not None and time.time() - start > DUR:
            break
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            continue
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        text = d.decode("utf-8", "replace")
        if start is None:
            i = text.find("\x1b[?1049h")            # alt-screen open = the desktop appears
            if i < 0:
                continue                            # still loading; drop pre-desktop noise
            start = time.time()
            text = text[i:]
        events.append([round(time.time() - start, 3), "o", text])

    try: os.kill(pid, signal.SIGKILL)
    except OSError: pass
    try: os.close(fd)
    except OSError: pass
    try: os.waitpid(pid, 0)
    except OSError: pass

    with open(OUT, "w") as f:
        f.write(json.dumps({"version": 2, "width": COLS, "height": ROWS,
                            "env": {"TERM": "xterm-256color"}}) + "\n")
        for e in events:
            f.write(json.dumps(e) + "\n")
    print(f"wrote {OUT}  ({len(events)} frames)")

if __name__ == "__main__":
    main()
