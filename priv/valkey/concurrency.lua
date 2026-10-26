local function num(n)
  return string.format('%.0f', n)
end

local now = (function() local t = redis.call('TIME') return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000) end)()
local op = ARGV[1]
local holder = ARGV[2]
local limit = tonumber(ARGV[3])
local lease = tonumber(ARGV[4])

if op == 'release' then
  local removed = redis.call('ZREM', KEYS[1], holder)
  local n = redis.call('ZCARD', KEYS[1])
  if removed == 1 then
    if n > 0 then
      redis.call('PEXPIRE', KEYS[1], num(2 * lease))
    end
    return {1, n, 0}
  end
  return {0, n, 0}
end

redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', num(now))
local n = redis.call('ZCARD', KEYS[1])
if redis.call('ZSCORE', KEYS[1], holder) then
  redis.call('ZADD', KEYS[1], num(now + lease), holder)
  redis.call('PEXPIRE', KEYS[1], num(2 * lease))
  return {1, n, 0}
end
if n < limit then
  redis.call('ZADD', KEYS[1], num(now + lease), holder)
  redis.call('PEXPIRE', KEYS[1], num(2 * lease))
  return {1, n + 1, 0}
end
local first = redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')
return {0, n, tonumber(first[2]) - now}
