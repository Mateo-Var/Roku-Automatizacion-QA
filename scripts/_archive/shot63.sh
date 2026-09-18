#!/usr/bin/env bash
# Screenshot helper against .63, usage: shot63.sh <output.jpg>
set -e
PW=$(grep ROKU_DEV_PASSWORD ../../.env | cut -d= -f2)
OUT="$1"
curl --digest -u "rokudev:${PW}" --silent --show-error --fail --max-time 30 \
  -F 'mysubmit=Screenshot' http://192.168.1.63:8060/plugin_inspect > /tmp/shotresp.txt 2>&1 || true
if ! grep -qi "Screenshot ok" /tmp/shotresp.txt; then
  echo "SCREENSHOT NOT OK"; cat /tmp/shotresp.txt; exit 1
fi
curl --digest -u "rokudev:${PW}" --silent --show-error --fail --max-time 30 \
  "http://192.168.1.63:8060/pkgs/dev.jpg?time=$(date +%s%N)" -o "$OUT"
echo "saved $OUT"
