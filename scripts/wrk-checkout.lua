-- wrk script: single-endpoint POST /api/v1/checkout with the fixed realistic
-- cart body (same body as wrk-realistic.lua). Used for the per-endpoint
-- checkout sweep; the mixed realistic run lives in wrk-realistic.lua.

local checkout_body = '{"user_id":"u-7f3a9c","items":[{"sku":"SKU-0042-BLK","qty":2,"price":29.99},{"sku":"SKU-0091-CABLE","qty":1,"price":12.49},{"sku":"SKU-0117-PAD","qty":3,"price":8.75},{"sku":"SKU-0200-STAND","qty":1,"price":45.0},{"sku":"SKU-0333-MAT","qty":2,"price":19.95}],"coupon":"SAVE10","customer":{"email":"ada@example.com","phone":"+49-170-123456"},"shipping":{"name":"Ada Lovelace","street":"12 Algorithm Ave","city":"Berlin","zip":"10115","country":"DE"},"payment":{"method":"card","last4":"4242"},"notes":"Leave at reception if absent, ring twice on delivery"}'

request = function()
  return wrk.format("POST", "/api/v1/checkout", {["Content-Type"] = "application/json"}, checkout_body)
end
