-- wrk script: mix of endpoints to exercise routing + JSON.
-- Distribution: 70% GET /health, 20% GET /hello/:name, 10% POST /api/v1/echo.
-- Deterministic per-request counter (wrk threads share via `counter` upvalue).

local counter = 0
local bodies = {}

request = function()
  counter = counter + 1
  local m = counter % 10
  if m < 7 then
    return wrk.format("GET", "/health")
  elseif m < 9 then
    return wrk.format("GET", "/hello/user" .. (counter % 64))
  else
    return wrk.format("POST", "/api/v1/echo", {["Content-Type"] = "text/plain"}, "ping-" .. counter)
  end
end
