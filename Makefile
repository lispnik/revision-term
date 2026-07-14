# revision-term --- a libvterm-backed terminal widget for the revision framework.
#
# Assumes the sibling checkouts ../revision and ../cffi-callback-closures exist,
# libvterm is installed (brew install libvterm), and SBCL is on PATH.

SBCL ?= sbcl
LOAD := --load setup.lisp

.PHONY: all build test smoke run clean

all: build

# Compile + load the whole system (a build check).
build:
	$(SBCL) --non-interactive $(LOAD) \
	  --eval '(asdf:load-system :revision-term)' \
	  --eval '(format t "~&BUILD OK~%")'

# Headless FiveAM suite: libvterm bindings, a real PTY round-trip, and each of
# the resize / exit / mouse / title / cursor / selection / scrollback features.
test:
	$(SBCL) --non-interactive $(LOAD) \
	  --eval '(asdf:load-system :revision-term/test)' \
	  --eval '(revision-term-tests:run)'

# End-to-end: drive the full-screen widget under a real pty (needs python3).
smoke:
	python3 tests/pty-smoke.py
	python3 tests/pty-input-smoke.py
	python3 tests/pty-paste-smoke.py
	python3 tests/pty-exit-smoke.py

# End-to-end image dump: save-lisp-and-die with a live terminal, then restore
# and run a fresh one.  Builds a multi-MB core, so it's separate from `make test`.
image-test:
	sh tests/image-test.sh

# Run your $$SHELL full-screen inside a revision terminal window.
run:
	$(SBCL) --script examples/run-shell.lisp

# Self-driving desktop showcase (terminals + a Lisp REPL as managed windows).
demo:
	$(SBCL) --script examples/demo.lisp

# Regenerate media/demo.gif from the demo (needs python3 + asciinema's agg).
record-demo:
	python3 examples/record-demo.py media/demo.cast 18
	agg --idle-time-limit 1.2 --font-size 15 --fps-cap 24 media/demo.cast media/demo.gif

clean:
	rm -rf ~/.cache/common-lisp/*revision-term* 2>/dev/null || true
