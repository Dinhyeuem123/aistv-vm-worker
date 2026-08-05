#!/usr/bin/env bash
set -u
MINS="${DURATION_MINUTES:-60}"
DEADLINE=$(( $(date +%s) + MINS * 60 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 60
done
echo "Session finished after ${MINS} minutes."
exit 0
