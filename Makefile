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

# Headless suite: libvterm bindings + a real PTY round-trip (no tty needed).
test:
	$(SBCL) --non-interactive $(LOAD) \
	  --eval '(asdf:load-system :revision-term/test)' \
	  --eval '(revision-term-tests:run)'

# End-to-end: drive the full-screen widget under a real pty (needs python3).
smoke:
	python3 tests/pty-smoke.py
	python3 tests/pty-input-smoke.py

# Run your $$SHELL full-screen inside a revision terminal window.
run:
	$(SBCL) --script examples/run-shell.lisp

clean:
	rm -rf ~/.cache/common-lisp/*revision-term* 2>/dev/null || true
