#!/usr/bin/env bash
# Prueba end-to-end: dos requests identicos -> MISS y luego HIT.
# Uso: scripts/smoke_test.sh <api_url> [redis_enabled=true]
set -euo pipefail

API_URL="${1:?Uso: smoke_test.sh <api_url> [redis_enabled]}"
REDIS_ENABLED="${2:-true}"
PAYLOAD="{\"data\":\"smoke-test $(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}\"}"

request() {
  curl -sS -D - -o /dev/null -X POST "${API_URL}/process" \
    -H 'Content-Type: application/json' -d "${PAYLOAD}" --max-time 15
}

header() { grep -i "^$1:" | head -1 | cut -d' ' -f2- | tr -d '\r'; }
status() { head -1 | awk '{print $2}'; }

echo "### Smoke test ${API_URL}"
health=$(curl -sS -o /dev/null -w '%{http_code}' "${API_URL}/health" --max-time 10)
echo "- GET /health -> ${health}"
[ "${health}" = "200" ] || { echo "::error::health check fallo"; exit 1; }

first=$(request);  s1=$(echo "${first}" | status);  c1=$(echo "${first}" | header x-cache)
second=$(request); s2=$(echo "${second}" | status); c2=$(echo "${second}" | header x-cache)
echo "- 1er POST /process -> ${s1} X-Cache: ${c1}"
echo "- 2do POST /process -> ${s2} X-Cache: ${c2}"

[ "${s1}" = "200" ] && [ "${s2}" = "200" ] || { echo "::error::status inesperado"; exit 1; }
[ "${c1}" = "MISS" ] || { echo "::error::el primer request debia ser MISS"; exit 1; }
if [ "${REDIS_ENABLED}" = "true" ]; then
  [ "${c2}" = "HIT" ] || { echo "::error::el segundo request debia ser HIT"; exit 1; }
else
  echo "- Redis deshabilitado: se valida modo degradado (MISS servido desde DynamoDB)"
fi
echo "OK"
