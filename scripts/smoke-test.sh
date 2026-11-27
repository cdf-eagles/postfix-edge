#!/bin/sh
# Runs the smoke test against a built postfix-edge image.
#
# Usage: sh scripts/smoke-test.sh <image>
# ENGINE selects docker or podman; by default podman when it is installed,
# otherwise docker. Needs openssl on the host. Prints PASS or FAIL per check
# and exits non-zero on any failure.
set -eu

IMAGE="${1:?usage: smoke-test.sh <image>}"
if [ -z "${ENGINE:-}" ]; then
  if command -v podman >/dev/null 2>&1; then ENGINE=podman; else ENGINE=docker; fi
fi
ROOT="$(cd "$(dirname "${0}")/.." && pwd)"
ID="postfix-edge-smoke-$$"
TESTS="localhost/${ID}-tests:latest"
DOMAIN="edge.test"
HOST="mail.${DOMAIN}"
TMP="$(mktemp -d)"
FAILED=0

# The capabilities the README documents for running with --cap-drop ALL.
CAPS="--cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETUID --cap-add SETGID --cap-add NET_BIND_SERVICE"

cleanup() {
  # The sink shares the MTA's network namespace, so Podman removes it first.
  "$ENGINE" rm -f "${ID}-sink" >/dev/null 2>&1 || :
  "$ENGINE" rm -f "${ID}-mta" >/dev/null 2>&1 || :
  "$ENGINE" volume rm -f "${ID}-tls" "${ID}-spool" "${ID}-conf" >/dev/null 2>&1 || :
  "$ENGINE" rmi -f "$TESTS" >/dev/null 2>&1 || :
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*"
  FAILED=$((FAILED + 1))
}

# Copies a host file into a volume through standard input, so no bind mount is needed.
to_volume() {
  "$ENGINE" run --rm -i -v "${1}:/v" "$TESTS" sh -c "cat > /v/${2} && chmod ${3} /v/${2}" <"$4"
}

# Starts the MTA, then the LMTP sink inside its network namespace.
start_pair() {
  # shellcheck disable=SC2086 # CAPS and the extra arguments are word lists.
  "$ENGINE" run -d --name "${ID}-mta" $CAPS \
    -e POSTFIX_EDGE_DOMAINS="$DOMAIN" \
    -v "${ID}-tls:/etc/postfix-edge/tls:ro" \
    "$@" "$IMAGE" >/dev/null
  "$ENGINE" run -d --name "${ID}-sink" --network "container:${ID}-mta" \
    -v "${ID}-spool:/spool" "$TESTS" \
    python /tests/lmtp_sink.py --spool /spool --accept "user@${DOMAIN}" >/dev/null
}

stop_pair() {
  label="$1"
  start="$(date +%s)"
  "$ENGINE" stop -t 20 "${ID}-mta" >/dev/null 2>&1 || :
  took=$(($(date +%s) - start))
  rc="$("$ENGINE" inspect -f '{{.State.ExitCode}}' "${ID}-mta")"
  printf -- '--- %s: MTA log ---\n' "$label"
  "$ENGINE" logs "${ID}-mta" 2>&1 | tee "${TMP}/mta.log"
  if [ "$rc" = 0 ] && [ "$took" -lt 15 ]; then
    pass "${label}: MTA stopped cleanly in ${took}s"
  else
    fail "${label}: MTA stop exit code ${rc} after ${took}s"
  fi
  if grep -Eq 'fatal:|panic:' "${TMP}/mta.log"; then
    fail "${label}: MTA log holds fatal or panic lines"
  else
    pass "${label}: MTA log holds no fatal or panic lines"
  fi
  "$ENGINE" rm -f "${ID}-sink" >/dev/null
  "$ENGINE" rm -f "${ID}-mta" >/dev/null
}

# Waits until Postfix's master and the sink are up; fails fast when the MTA exits.
wait_ready() {
  i=0
  while [ "$i" -lt 30 ]; do
    if [ "$("$ENGINE" inspect -f '{{.State.Running}}' "${ID}-mta")" != true ]; then
      return 1
    fi
    if "$ENGINE" logs "${ID}-mta" 2>&1 | grep -q 'daemon started' &&
      "$ENGINE" logs "${ID}-sink" 2>&1 | grep -q 'lmtp_sink: listening'; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# The health check the image declares, read the way each engine reports it.
declared_healthcheck() {
  if [ "$ENGINE" = podman ]; then
    "$ENGINE" image inspect -f '{{json .HealthCheck}}' "$IMAGE"
  else
    "$ENGINE" image inspect -f '{{json .Config.Healthcheck}}' "$IMAGE"
  fi
}

# Runs the declared health check through the engine itself: podman runs it on
# demand; Docker runs it on its own schedule, so wait for its status.
engine_reports_healthy() {
  if [ "$ENGINE" = podman ]; then
    "$ENGINE" healthcheck run "${ID}-mta"
    return
  fi
  i=0
  while [ "$i" -lt 90 ]; do
    status="$("$ENGINE" inspect -f '{{.State.Health.Status}}' "${ID}-mta" 2>/dev/null)"
    [ "$status" = healthy ] && return 0
    [ "$status" = unhealthy ] && return 1
    sleep 1
    i=$((i + 1))
  done
  return 1
}

client() {
  "$ENGINE" run --rm --network "container:${ID}-mta" -v "${ID}-spool:/spool" "$TESTS" \
    python /tests/smoke_client.py "$@" --hostname "$HOST" --domain "$DOMAIN"
}

echo "engine: $("$ENGINE" --version)"
echo "image: ${IMAGE}"
"$ENGINE" run --rm --entrypoint postconf "$IMAGE" -d mail_version
"$ENGINE" build -q -t "$TESTS" -f "${ROOT}/tests/Dockerfile" "${ROOT}/tests" >/dev/null

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=${HOST}" \
  -keyout "${TMP}/tls.key" -out "${TMP}/tls.crt" 2>/dev/null
"$ENGINE" volume create "${ID}-tls" >/dev/null
"$ENGINE" volume create "${ID}-spool" >/dev/null
"$ENGINE" volume create "${ID}-conf" >/dev/null
to_volume "${ID}-tls" tls.key 600 "${TMP}/tls.key"
to_volume "${ID}-tls" tls.crt 644 "${TMP}/tls.crt"
printf 'message_size_limit = 1234567\n' >"${TMP}/50-test.cf"
to_volume "${ID}-conf" 50-test.cf 644 "${TMP}/50-test.cf"

echo "=== configuration checks"
rc=0
"$ENGINE" run --rm "$IMAGE" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 64 ]; then pass "refuses to start without POSTFIX_EDGE_DOMAINS"; else fail "no POSTFIX_EDGE_DOMAINS gave rc=${rc}, not 64"; fi
rc=0
"$ENGINE" run --rm -e POSTFIX_EDGE_DOMAINS="$DOMAIN" "$IMAGE" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 64 ]; then pass "refuses to start with TLS required and no certificate"; else fail "missing certificate gave rc=${rc}, not 64"; fi
rc=0
"$ENGINE" run --rm -e POSTFIX_EDGE_DOMAINS="a.test b..test" -e POSTFIX_EDGE_TLS=none "$IMAGE" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 64 ]; then pass "refuses a malformed domain"; else fail "malformed domain gave rc=${rc}, not 64"; fi
for bad in "POSTFIX_EDGE_TLS=required" "POSTFIX_EDGE_MYNETWORKS=static:all" "POSTFIX_EDGE_MYNETWORKS=10.0.0.0/8;x" "POSTFIX_EDGE_LMTP=inet:a b:24" "POSTFIX_EDGE_LMTP=static:all"; do
  rc=0
  "$ENGINE" run --rm -e POSTFIX_EDGE_DOMAINS="$DOMAIN" -e POSTFIX_EDGE_TLS=none -e "$bad" "$IMAGE" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 64 ]; then pass "refuses ${bad}"; else fail "${bad} gave rc=${rc}, not 64"; fi
done
value="$("$ENGINE" run --rm -e POSTFIX_EDGE_DOMAINS="$DOMAIN" -e POSTFIX_EDGE_TLS=none "$IMAGE" postconf -h smtpd_tls_security_level 2>/dev/null)"
if [ "$value" = none ]; then pass "POSTFIX_EDGE_TLS=none turns STARTTLS off"; else fail "POSTFIX_EDGE_TLS=none left smtpd_tls_security_level='${value}'"; fi
value="$("$ENGINE" run --rm -e POSTFIX_EDGE_DOMAINS="$DOMAIN" -e POSTFIX_EDGE_TLS=none \
  -v "${ID}-conf:/etc/postfix-edge/main.cf.d:ro" "$IMAGE" postconf -h message_size_limit 2>/dev/null)"
if [ "$value" = 1234567 ]; then pass "a main.cf.d file overrides a setting"; else fail "main.cf.d override gave message_size_limit='${value}'"; fi

value="$(declared_healthcheck 2>/dev/null)"
case "$value" in
  *postfix-edge-healthcheck*) pass "the image declares its health check: ${value}" ;;
  *) fail "the image declares no health check (${value}); a Podman build needs --format docker" ;;
esac
rc=0
"$ENGINE" run --rm --entrypoint /usr/local/bin/postfix-edge-healthcheck "$IMAGE" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 1 ]; then pass "health check fails when Postfix is not running"; else fail "health check without Postfix gave rc=${rc}, not 1"; fi

echo "=== client inside mynetworks, empty queue volume"
start_pair --mount type=tmpfs,destination=/var/spool/postfix
if ! wait_ready; then
  fail "accept: the MTA or the sink did not start"
elif client accept --tls yes; then
  pass "accept checks"
else
  fail "accept checks"
fi
if "$ENGINE" exec "${ID}-mta" postfix-edge-healthcheck && "$ENGINE" exec "${ID}-mta" postfix-edge-healthcheck --backend; then
  pass "health check and backend check pass while Postfix and the sink run"
else
  fail "health check or backend check failed while Postfix and the sink run"
fi
if engine_reports_healthy; then pass "${ENGINE} reports the container healthy"; else fail "${ENGINE} does not report the container healthy"; fi
"$ENGINE" stop -t 5 "${ID}-sink" >/dev/null
if "$ENGINE" exec "${ID}-mta" postfix-edge-healthcheck; then
  pass "health check still passes with the backend down"
else
  fail "health check fails with the backend down"
fi
if "$ENGINE" exec "${ID}-mta" postfix-edge-healthcheck --backend; then
  fail "backend check passes with the backend down"
else
  pass "backend check fails with the backend down"
fi
stop_pair accept

echo "=== client outside mynetworks"
start_pair -e POSTFIX_EDGE_MYNETWORKS=192.0.2.0/24
if ! wait_ready; then
  fail "refuse: the MTA or the sink did not start"
elif client refuse; then
  pass "refuse checks"
else
  fail "refuse checks"
fi
stop_pair refuse

echo "=== STARTTLS required"
start_pair -e POSTFIX_EDGE_TLS=encrypt
if ! wait_ready; then
  fail "encrypt: the MTA or the sink did not start"
elif client encrypt; then
  pass "encrypt checks"
else
  fail "encrypt checks"
fi
stop_pair encrypt

if [ "$FAILED" -eq 0 ]; then
  echo "SMOKE TEST PASS"
else
  echo "SMOKE TEST FAIL: ${FAILED} failure(s)"
  exit 1
fi
