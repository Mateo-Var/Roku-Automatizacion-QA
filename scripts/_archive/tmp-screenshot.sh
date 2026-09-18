#!/usr/bin/env bash
# Uso: tmp-screenshot.sh <host> <password> <outFile>
set -e
HOST="$1"
PASS="$2"
OUT="$3"
SUBMIT=$(curl --digest -u "rokudev:$PASS" --silent --show-error --fail --max-time 30 \
  -F "mysubmit=Screenshot" "http://$HOST/plugin_inspect")
if ! echo "$SUBMIT" | grep -qi "Screenshot ok"; then
  echo "SCREENSHOT NOT OK: $SUBMIT" >&2
  exit 1
fi
curl --digest -u "rokudev:$PASS" --silent --show-error --fail --max-time 30 \
  "http://$HOST/pkgs/dev.jpg?time=$(date +%s%N)" -o "$OUT"
echo "OK -> $OUT"
