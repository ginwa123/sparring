#!/usr/bin/env bash
# scripts/smoke-db.sh — sqlite parity check against one running server.
# Usage: smoke-db.sh <port> [label]. Checks all 5 /db endpoints + edge cases.
# Exits 0 on ALL_PASS.
set -u
PORT="${1:-29590}"
LABEL="${2:-db}"
fail=0
t() {
  local name="$1" want="$2"; shift 2
  local got
  got=$(curl -s -m 3 "$@" 2>/dev/null)
  if [[ "$got" == *"$want"* ]]; then
    echo "PASS $LABEL/$name: $got"
  else
    echo "FAIL $LABEL/$name: want '$want' got '$got'"
    fail=1
  fi
}
t health '"ok":true' "http://127.0.0.1:$PORT/db/health"
t user42 '"username":"user_42"' "http://127.0.0.1:$PORT/db/user/42"
t user42-id '"id":42' "http://127.0.0.1:$PORT/db/user/42"
t users3 '"id":3' "http://127.0.0.1:$PORT/db/users?limit=3"
t post '"username":"smoke"' -X POST -H 'Content-Type: application/json' -d '{"username":"smoke","email":"smoke@bench.local"}' "http://127.0.0.1:$PORT/db/user"
t put '"id":42' -X PUT -H 'Content-Type: application/json' -d '{"username":"smoke2","email":"smoke2@bench.local"}' "http://127.0.0.1:$PORT/db/user/42"
t search '"username":"user_1"' "http://127.0.0.1:$PORT/db/search?q=user_1&limit=3"
t search400 'invalid query' "http://127.0.0.1:$PORT/db/search"
t delete '"deleted":4998' -X DELETE "http://127.0.0.1:$PORT/db/user/4998"
t badjson 'invalid JSON' -X POST -H 'Content-Type: application/json' -d '{"username":""}' "http://127.0.0.1:$PORT/db/user"
code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/db/user/9999999")
if [[ "$code" == "404" ]]; then echo "PASS $LABEL/404: $code"; else echo "FAIL $LABEL/404: want 404 got $code"; fail=1; fi
code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/db/user/abc")
if [[ "$code" == "404" ]]; then echo "PASS $LABEL/badid-404: $code"; else echo "FAIL $LABEL/badid-404: want 404 got $code"; fail=1; fi
if [[ $fail -eq 0 ]]; then echo ALL_PASS; fi
exit $fail
