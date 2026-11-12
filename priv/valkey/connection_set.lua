local function num(n)
  return string.format('%.0f', n)
end

local now = (function() local t = redis.call('TIME') return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000) end)()
local op = ARGV[1]
local member = ARGV[2]
local ttl = tonumber(ARGV[3])
local max = tonumber(ARGV[4])

redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', num(now - ttl))

if op == 'join' then
  redis.call('ZADD', KEYS[1], num(now), member)
  redis.call('PEXPIRE', KEYS[1], num(ttl))
  local members = redis.call('ZRANGE', KEYS[1], 0, -1)
  local evicted = 0
  if #members > max then
    table.sort(members)
    for i = 1, #members - max do
      redis.call('ZREM', KEYS[1], members[i])
      evicted = evicted + 1
    end
  end
  return {redis.call('ZCARD', KEYS[1]), evicted}
end

if op == 'touch' then
  if redis.call('ZSCORE', KEYS[1], member) then
    redis.call('ZADD', KEYS[1], 'XX', num(now), member)
    redis.call('PEXPIRE', KEYS[1], num(ttl))
    return {1, 0}
  end
  return {0, 0}
end

if op == 'leave' then
  return {redis.call('ZREM', KEYS[1], member), 0}
end

local members = redis.call('ZRANGE', KEYS[1], 0, -1)
for _, m in ipairs(members) do
  if string.len(m) >= string.len(member) and string.sub(m, -string.len(member)) == member then
    return {1, 0}
  end
end
return {0, 0}
