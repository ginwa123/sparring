-- wrk-sqlite-read.lua: multiple-read sqlite workload (no writes, DB size stable).
-- Distribution: 50% GET /db/user/:id (point read, random id 1..5000),
-- 25% GET /db/users?limit=20 (range scan), 25% GET /db/search (complex LIKE read).

local counter = 0

request = function()
  counter = counter + 1
  local m = counter % 4
  if m < 2 then
    local id = 1 + (counter % 5000)
    return wrk.format("GET", "/db/user/" .. id)
  elseif m < 3 then
    return wrk.format("GET", "/db/users?limit=20")
  else
    return wrk.format("GET", "/db/search?q=user_1&limit=20")
  end
end
