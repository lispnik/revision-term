#!/bin/sh
# image-test.sh --- end-to-end: dump a Lisp image while a terminal is live, then
# restore that image and run a fresh terminal.  Proves the image-dump hook lets
# save-lisp-and-die succeed (single thread + clean heap) and that a restored
# image can drive libvterm again.  Exits 0 on success.
#
# (Builds a multi-megabyte core, so it's a separate target, not part of `make test`.)

set -eu
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
export RT_IMAGE_CORE="${TMPDIR:-/tmp}/revision-term-image-test.core"
rm -f "$RT_IMAGE_CORE"

echo "== dumping an image while a terminal is live =="
sbcl --non-interactive --load "$PROJ/setup.lisp" \
     --eval '(asdf:load-system :revision-term)' \
     --load "$PROJ/tests/image-dump.lisp"

if [ ! -f "$RT_IMAGE_CORE" ]; then
  echo "[FAIL] no core written -- the dump was blocked (hook did not tear the terminal down)"
  exit 1
fi
echo "[pass] dumped an image with a live terminal (hook stopped the reader thread)"

echo "== restoring the image and running a fresh terminal =="
if sbcl --core "$RT_IMAGE_CORE" --non-interactive --load "$PROJ/tests/image-restore.lisp"; then
  echo "[pass] restored image drove a fresh terminal"
  rm -f "$RT_IMAGE_CORE"
  exit 0
else
  echo "[FAIL] restored image could not run a terminal"
  rm -f "$RT_IMAGE_CORE"
  exit 1
fi
