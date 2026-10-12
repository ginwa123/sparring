-- wrk-sqlite-mixed.lua: both reads + writes (realistic CRUD mix).
-- Distribution: 50% point read, 15% list read, 10% complex search read,
-- 10% insert (POST), 10% update (PUT), 5% delete (DELETE).
-- Reads hit seeded ids 1..5000; writes use unique names / seeded targets.
-- POSTs outnumber DELETEs 2:1 so the table grows slowly under load.

local counter = 0

request = function()
  counter = counter + 1
  local m = counter % 20
  if m < 10 then
    local id = 1 + (counter % 5000)
    return wrk.format("GET", "/db/user/" .. id)
  elseif m < 13 then
    return wrk.format("GET", "/db/users?limit=20")
  elseif m < 15 then
    return wrk.format("GET", "/db/search?q=user_1&limit=20")
  elseif m < 17 then
    local body = '{"username":"mix_user_' .. counter .. '","email":"mix_' .. counter .. '@bench.local"}'
    return wrk.format("POST", "/db/user", {["Content-Type"] = "application/json"}, body)
  elseif m < 19 then
    local id = 1 + (counter % 5000)
    local body = '{"username":"mix_upd_' .. counter .. '","email":"mixupd_' .. counter .. '@bench.local"}'
    return wrk.format("PUT", "/db/user/" .. id, {["Content-Type"] = "application/json"}, body)
  else
    local id = 1 + (counter % 5000)
    return wrk.format("DELETE", "/db/user/" .. id)
  end
end
