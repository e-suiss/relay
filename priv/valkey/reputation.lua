local function num(n)
  return string.format('%.0f', n)
end

local now = (function() local t = redis.call('TIME') return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000) end)()
local event = tonumber(ARGV[1])
local count = tonumber(ARGV[2])
local bucket_ms = tonumber(ARGV[3])
local buckets = tonumber(ARGV[4])
local index = math.floor(now / bucket_ms)

local totals = {0, 0, 0, 0}
local fields = redis.call('HGETALL', KEYS[1])
for i = 1, #fields, 2 do
  local b, e = string.match(fields[i], '^(%d+):(%d)$')
  b = tonumber(b)
  e = tonumber(e)
  if b == nil or e == nil or e < 1 or e > 4 or b <= index - buckets then
    redis.call('HDEL', KEYS[1], fields[i])
  else
    totals[e] = totals[e] + tonumber(fields[i + 1])
  end
end

if event >= 1 and event <= 4 and count > 0 then
  redis.call('HINCRBY', KEYS[1], num(index) .. ':' .. num(event), num(count))
  redis.call('PEXPIRE', KEYS[1], num(bucket_ms * buckets + 60000))
end

return {now, totals[1], totals[2], totals[3], totals[4]}
