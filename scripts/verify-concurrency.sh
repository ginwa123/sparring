#!/usr/bin/env bash
# scripts/verify-concurrent.sh — direct correctness verification under concurrency.
# Fires N parallel curl requests at each endpoint and counts exact expected bodies.
# Usage: verify-concurrency.sh <port> <connections>
set -u
PORT="$1"
N="${2:-200}"

check() { # url expected_substring
  local url="$1" want="$2"
  local i got ok=0
  for ((i = 0; i < N; i++)); do
    (
      got=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url")
      body=$(curl -s -m 5 "$url")
      if [[ "$got" == "200" && "$body" == *"$want"* ]]; then
        echo OK
      else
        echo "BAD:$got:$body"
      fi
    ) &
  done
  wait
}

fail=0
r=$(check "http://127.0.0.1:$PORT/health" "OK" | sort | uniq -c)
echo "health: $r"
[[ "$r" == *" $N OK"* ]] || fail=1

r=$(check "http://127.0.0.1:$PORT/hello/Bench" "Hello, Bench! (greeting: hello, mood: neutral)" | sort | uniq -c)
echo "hello : $r"
[[ "$r" == *" $N OK"* ]] || fail=1

(( fail == 0 )) && echo VERIFY_PASS || echo VERIFY_FAIL
exit $fail
