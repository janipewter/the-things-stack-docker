#!/bin/sh
# Test the ACME reload watcher: swap cert.pem for a throwaway, confirm the
# stack restarts, then restore. Run this ON THE DEVICE (balenaOS host).
#
# Usage: sh test_acme_reload.sh <stack-container-name>

set -e

STACK="$1"
if [ -z "${STACK}" ]; then
    echo "ERROR: pass the stack container name."
    echo "Find it with: balena ps --format '{{.Names}}' | grep -i stack"
    exit 1
fi

# The real certificate stays safe in the certbot container at
# /etc/letsencrypt/live/<domain>/. This only touches the published copy.
BACKUP=/tmp/acme_test_real.pem

echo "== 1. Backing up published cert to host =="
balena exec "${STACK}" cat /srv/data/cert.pem > "${BACKUP}"
openssl x509 -in "${BACKUP}" -noout -issuer
echo "Backup: ${BACKUP} ($(wc -c < "${BACKUP}") bytes)"

echo
echo "== 2. Noting current container start time =="
STARTED_BEFORE=$(balena inspect -f '{{.State.StartedAt}}' "${STACK}")
echo "StartedAt: ${STARTED_BEFORE}"

echo
echo "== 3. Swapping in a throwaway cert =="
balena exec "${STACK}" sh -c \
    'openssl req -x509 -newkey rsa:2048 -keyout /tmp/t.key -out /tmp/t.crt -days 1 -nodes -subj "/CN=reload-test" 2>/dev/null && cp /tmp/t.crt /srv/data/cert.pem'
echo "Swapped. Watcher polls every 60s."

echo
echo "== 4. Waiting up to 150s for restart =="
i=0
RESTARTED=no
while [ $i -lt 150 ]; do
    sleep 10
    i=$((i + 10))
    STARTED_NOW=$(balena inspect -f '{{.State.StartedAt}}' "${STACK}" 2>/dev/null || echo "${STARTED_BEFORE}")
    if [ "${STARTED_NOW}" != "${STARTED_BEFORE}" ]; then
        echo "RESTARTED after ~${i}s (StartedAt: ${STARTED_NOW})"
        RESTARTED=yes
        break
    fi
    echo "  ${i}s: no restart yet"
done

echo
echo "== 5. Restoring real cert =="
# Wait for the container to be up before exec'ing into it
sleep 5
balena exec -i "${STACK}" sh -c 'cat > /srv/data/cert.pem' < "${BACKUP}"
balena exec "${STACK}" openssl x509 -in /srv/data/cert.pem -noout -issuer
echo "Restored. Stack will restart once more onto the real cert."

echo
echo "=================================================="
if [ "${RESTARTED}" = "yes" ]; then
    echo "PASS: watcher detected the change and restarted."
else
    echo "FAIL: no restart within 150s."
    echo "Check the log for 'Certificate on disk changed':"
    echo "  balena logs ${STACK} --tail 40"
    echo "If the line IS there, kill -TERM 1 is not stopping the container."
    echo "If it is NOT there, the new code is not deployed or ACME is inactive."
fi
echo "=================================================="
