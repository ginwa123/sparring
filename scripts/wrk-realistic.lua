-- wrk script: realistic-payload mix to exercise ~1KB responses + ~0.6KB JSON
-- request parsing on every framework.
-- Distribution: 50% GET /api/v1/product/:id, 50% POST /api/v1/checkout.
-- The checkout body is fixed so all frameworks compute the same order
-- (subtotal 183.62, SAVE10 discount, total 165.26, 9 items).

local counter = 0
local checkout_body = '{"user_id":"u-7f3a9c","items":[{"sku":"SKU-0042-BLK","qty":2,"price":29.99},{"sku":"SKU-0091-CABLE","qty":1,"price":12.49},{"sku":"SKU-0117-PAD","qty":3,"price":8.75},{"sku":"SKU-0200-STAND","qty":1,"price":45.0},{"sku":"SKU-0333-MAT","qty":2,"price":19.95}],"coupon":"SAVE10","customer":{"email":"ada@example.com","phone":"+49-170-123456"},"shipping":{"name":"Ada Lovelace","street":"12 Algorithm Ave","city":"Berlin","zip":"10115","country":"DE"},"payment":{"method":"card","last4":"4242"},"notes":"Leave at reception if absent, ring twice on delivery"}'

request = function()
  counter = counter + 1
  if counter % 2 == 0 then
    return wrk.format("GET", "/api/v1/product/" .. (1000 + (counter % 9000)))
  else
    return wrk.format("POST", "/api/v1/checkout", {["Content-Type"] = "application/json"}, checkout_body)
  end
end
