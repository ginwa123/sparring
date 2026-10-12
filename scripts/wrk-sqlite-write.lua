-- wrk-sqlite-write.lua: multiple-write sqlite workload (single-writer stress).
-- Distribution: 50% POST /db/user (insert), 50% PUT /db/user/:id (update).
-- POST bodies use unique usernames per request so inserts never collide.
-- PUT targets ids 1..5000 (seeded rows, always exist at start).

local counter = 0

request = function()
  counter = counter + 1
  if counter % 2 == 0 then
    local body = '{"username":"wrk_user_' .. counter .. '","email":"wrk_' .. counter .. '@bench.local"}'
    return wrk.format("POST", "/db/user", {["Content-Type"] = "application/json"}, body)
  else
    local id = 1 + (counter % 5000)
    local body = '{"username":"upd_' .. counter .. '","email":"upd_' .. counter .. '@bench.local"}'
    return wrk.format("PUT", "/db/user/" .. id, {["Content-Type"] = "application/json"}, body)
  end
end
