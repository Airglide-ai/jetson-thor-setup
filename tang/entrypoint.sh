#!/bin/sh
# Generate Tang keys on first start, then serve tangd over TCP 8080.
set -eu

DB=/var/db/tang

if [ -z "$(ls -A "$DB" 2>/dev/null)" ]; then
  echo "tang: no keys found in $DB, generating new keys"
  tangd-keygen "$DB"
fi

echo "tang: serving keys from $DB on :8080"
ls -1 "$DB"

exec socat TCP-LISTEN:8080,reuseaddr,fork EXEC:"tangd $DB"
