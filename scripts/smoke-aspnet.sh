#!/usr/bin/env bash
# scripts/smoke-aspnet.sh — quick endpoint smoke test for the ASP.NET Core bench server.
# Starts the server, curls each endpoint, kills it. Exits 0 on all-pass.
set -u
SRV=/home/ginwa/sparringhttp/bin/aspnet-bench
LOG=/tmp/aspnet_smoke.log
"$SRV" >"$LOG" 2>&1 &
SRV_PID=$!
cleanup() {
  kill "$SRV_PID" 2>/dev/null || true
  # Do NOT wait on it — the bash 'wait' builtin hangs forever on children
  # that have already reaped themselves (zig/go/dotnet/rust servers exit on SIGTERM).
}
trap cleanup EXIT
sleep 2
fail=0
t() {
  local name="$1" want="$2"; shift 2
  local got
  got=$(curl -s -m 3 "$@" 2>/dev/null)
  if [[ "$got" == *"$want"* ]]; then
    echo "PASS $name: $got"
  else
    echo "FAIL $name: want '$want' got '$got'"
    fail=1
  fi
}
t health OK http://127.0.0.1:29590/health
t hello "Hello, Alice!" http://127.0.0.1:29590/hello/Alice
t users '"username":"bob"' -X POST -H 'Content-Type: application/json' -d '{"username":"bob","email":"b@x.com"}' http://127.0.0.1:29590/users
t echo 'echo-me' -X POST -d 'echo-me' http://127.0.0.1:29590/api/v1/echo
t product '"name":"Ergonomic Wireless Mouse"' http://127.0.0.1:29590/api/v1/product/42
t product-id '"id":42' http://127.0.0.1:29590/api/v1/product/42
t checkout '"total":165.26' -X POST -H 'Content-Type: application/json' -d '{"user_id":"u-7f3a9c","items":[{"sku":"SKU-0042-BLK","qty":2,"price":29.99},{"sku":"SKU-0091-CABLE","qty":1,"price":12.49},{"sku":"SKU-0117-PAD","qty":3,"price":8.75},{"sku":"SKU-0200-STAND","qty":1,"price":45.0},{"sku":"SKU-0333-MAT","qty":2,"price":19.95}],"coupon":"SAVE10","customer":{"email":"ada@example.com","phone":"+49-170-123456"},"shipping":{"name":"Ada Lovelace","street":"12 Algorithm Ave","city":"Berlin","zip":"10115","country":"DE"},"payment":{"method":"card","last4":"4242"},"notes":"Leave at reception if absent, ring twice on delivery"}' http://127.0.0.1:29590/api/v1/checkout
t checkout-items '"items":9' -X POST -H 'Content-Type: application/json' -d '{"user_id":"u-7f3a9c","items":[{"sku":"SKU-0042-BLK","qty":2,"price":29.99},{"sku":"SKU-0091-CABLE","qty":1,"price":12.49},{"sku":"SKU-0117-PAD","qty":3,"price":8.75},{"sku":"SKU-0200-STAND","qty":1,"price":45.0},{"sku":"SKU-0333-MAT","qty":2,"price":19.95}],"coupon":"SAVE10"}' http://127.0.0.1:29590/api/v1/checkout
t page 'Hello, Alice!' "http://127.0.0.1:29590/page?name=Alice"
t sse 'event: tick' "http://127.0.0.1:29590/events"
# WS echo check (graceful degradation: websockets lib -> wscat -> SKIP)
if python3 -c "import websockets" 2>/dev/null; then
  if python3 -c 'import asyncio,sys;from websockets import connect
async def main():
    async with connect("ws://127.0.0.1:29590/ws",open_timeout=3,close_timeout=3) as ws:
        await ws.send("hello-ws");got=await asyncio.wait_for(ws.recv(),timeout=3)
        sys.exit(0 if "hello-ws" in str(got) else 1)
asyncio.run(main())' 2>/dev/null; then
    echo "PASS ws: echo ok"
  else
    echo "FAIL ws: echo mismatch"
    fail=1
  fi
elif command -v wscat >/dev/null 2>&1; then
  if printf 'hello-ws' | timeout 8 wscat -c ws://127.0.0.1:29590/ws 2>/dev/null | grep -q 'hello-ws'; then
    echo "PASS ws: echo ok"
  else
    echo "FAIL ws: echo mismatch"
    fail=1
  fi
else
  echo "SKIP ws (no client)"
fi
if [[ $fail -eq 0 ]]; then
  echo ALL_PASS
fi
exit $fail
