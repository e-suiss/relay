local function fdiv(a, b)
  local q = math.floor(a / b)
  local r = a - q * b
  if r < 0 then
    q = q - 1
  elseif r >= b then
    q = q + 1
  end
  return q
end

local function cdiv(a, b)
  return -fdiv(-a, b)
end

local function num(n)
  return string.format('%.0f', n)
end

local now = tonumber(ARGV[#ARGV])
local emission = tonumber(ARGV[1])
local burst = tonumber(ARGV[2])
local cost = tonumber(ARGV[3])
local cap = tonumber(ARGV[4])
local limit = tonumber(ARGV[5])
local period = tonumber(ARGV[6])
local offset = tonumber(ARGV[7])

local stored = redis.call('HMGET', KEYS[1], 't', 'w', 'c', 'p')
local tat0 = tonumber(stored[1]) or now
local sw = tonumber(stored[2])
local cur = tonumber(stored[3]) or 0
local prev = tonumber(stored[4]) or 0

local w = fdiv(now + offset, period)
local pos = now + offset - w * period
if sw == nil then
  cur = 0
  prev = 0
elseif sw > w then
  w = sw
  pos = 0
elseif sw == w - 1 then
  prev = cur
  cur = 0
elseif sw < w - 1 then
  prev = 0
  cur = 0
end
local est = cdiv(prev * (period - pos), period) + cur

if cost > burst then
  return {3, 0, tat0, now, est}
end

local tat1 = math.max(tat0, now) + cost * emission
if tat1 - now > burst * emission then
  return {1, tat1 - now - burst * emission, tat0, now, est}
end

if cap >= 0 and est + cost > cap then
  return {2, math.max(emission, cdiv((est + cost - cap) * period, limit)), tat0, now, est}
end

redis.call('HSET', KEYS[1], 't', num(tat1), 'w', num(w), 'c', num(cur + cost), 'p', num(prev))
local ttl = cdiv(tat1 - now, 1000)
if cap >= 0 then
  ttl = math.max(ttl, 2 * cdiv(period, 1000))
end
redis.call('PEXPIRE', KEYS[1], num(ttl + 1000))
return {0, 0, tat1, now, est + cost}
