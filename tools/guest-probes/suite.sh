#!/bin/sh
set -u
ulimit -c 0
mkdir -p /home/cross-scratch || exit 1
chmod 700 /home/cross-scratch
export TMPDIR=/home/cross-scratch
cd /home/cross-scratch || exit 1
expected=$(wc -l < /home/cross-data/tests/manifest)
printf 'ZAP_GUEST_EXPECTED %s\n' "$expected"
while IFS= read -r root; do
    printf 'ZAP_GUEST_BEGIN %s\n' "$root"
    /usr/bin/timeout 120 "/home/cross-data/tests/$root" </dev/null >"$root.log" 2>&1
    status=$?
    cat "$root.log"
    printf 'ZAP_GUEST_END %s %s\n' "$root" "$status"
done < /home/cross-data/tests/manifest
echo ZAP_GUEST_COMPLETE
