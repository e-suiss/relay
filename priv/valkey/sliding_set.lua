local function num(n)
  return string.format('%.0f', n)
end

local now = (function() local t = redis.call('TIME') return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000) end)()
local op = ARGV[1]
local window = tonumber(ARGV[2])
local member = ARGV[3]
local limit = tonumber(ARGV[4])
local from = now - window

if op == 'add' then
  redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', num(from))
  redis.call('ZADD', KEYS[1], 'NX', num(now), member)
  redis.call('PEXPIRE', KEYS[1], num(window + 1000))
  return {redis.call('ZCARD', KEYS[1]), 0, now}
end

local start = redis.call('ZCOUNT', KEYS[1], '-inf', num(from))
local count = redis.call('ZCARD', KEYS[1]) - start
local own = redis.call('ZSCORE', KEYS[1], member)
local own_rank = -1
if own and tonumber(own) > from then
  count = count - 1
  own_rank = redis.call('ZRANK', KEYS[1], member) - start
end
if count < limit then
  return {count, 0, now}
end
local pos = count - limit
if own_rank >= 0 and own_rank <= pos then
  pos = pos + 1
end
local entry = redis.call('ZRANGE', KEYS[1], start + pos, start + pos, 'WITHSCORES')
return {count, tonumber(entry[2]) + window, now}
