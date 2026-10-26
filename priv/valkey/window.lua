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

local now = (function() local t = redis.call('TIME') return tonumber(t[1]) * 1000000 + tonumber(t[2]) end)()
local op = ARGV[1]
local algorithm = ARGV[2]
local limit = tonumber(ARGV[3])
local window = tonumber(ARGV[4]) * 1000
local offset = tonumber(ARGV[5]) * 1000
local cost = tonumber(ARGV[6])

if algorithm == 'l' then
  redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', num(now - window))
  local count = redis.call('ZCARD', KEYS[1])
  if count + cost <= limit then
    for i = 1, cost do
      redis.call('ZADD', KEYS[1], num(now), num(now) .. ':' .. num(count + i))
    end
    redis.call('PEXPIRE', KEYS[1], num(cdiv(window, 1000) + 1000))
    return {0, count + cost, 0}
  end
  if cost > limit then
    return {1, count, cdiv(window, 1000)}
  end
  local idx = count + cost - limit
  local first = redis.call('ZRANGE', KEYS[1], idx - 1, idx - 1, 'WITHSCORES')
  return {1, count, cdiv(tonumber(first[2]) + window - now, 1000)}
end

local stored = redis.call('HMGET', KEYS[1], 'w', 'c', 'p')
local sw = tonumber(stored[1])
local cur = tonumber(stored[2]) or 0
local prev = tonumber(stored[3]) or 0
local w = fdiv(now + offset, window)
local pos = now + offset - w * window
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
local window_end = (w + 1) * window - offset

if algorithm == 'f' then
  if cur + cost <= limit then
    redis.call('HSET', KEYS[1], 'w', num(w), 'c', num(cur + cost), 'p', '0')
    redis.call('PEXPIRE', KEYS[1], num(cdiv(window_end - now, 1000) + 1000))
    return {0, cur + cost, 0}
  end
  return {1, cur, cdiv(window_end - now, 1000)}
end

local est = cdiv(prev * (window - pos), window) + cur

if op == 'read' then
  return {0, est, 0}
end

if op == 'incr' then
  redis.call('HSET', KEYS[1], 'w', num(w), 'c', num(cur + cost), 'p', num(prev))
  redis.call('PEXPIRE', KEYS[1], num(2 * cdiv(window, 1000) + 1000))
  return {0, est + cost, 0}
end

local effective = fdiv(9 * limit, 10)
if est + cost <= effective then
  redis.call('HSET', KEYS[1], 'w', num(w), 'c', num(cur + cost), 'p', num(prev))
  redis.call('PEXPIRE', KEYS[1], num(2 * cdiv(window, 1000) + 1000))
  return {0, est + cost, 0}
end
if cur + cost > effective then
  return {1, est, cdiv(window_end - now, 1000)}
end
local first = w * window - offset + window - fdiv((effective - cur - cost) * window, prev)
return {1, est, cdiv(first - now, 1000)}
