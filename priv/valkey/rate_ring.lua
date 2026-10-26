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

local function num(n)
  return string.format('%.0f', n)
end

local now = (function() local t = redis.call('TIME') return tonumber(t[1]) * 1000000 + tonumber(t[2]) end)()
local cost = tonumber(ARGV[1])
local current = tonumber(ARGV[2])
local baseline = tonumber(ARGV[3])

local minute = fdiv(now, 60000000)
local fields = redis.call('HGETALL', KEYS[1])
for i = 1, #fields, 2 do
  local f = tonumber(fields[i])
  if f > minute then
    minute = f
  end
end

local counts = {}
for i = 1, #fields, 2 do
  local f = tonumber(fields[i])
  if f <= minute - 120 then
    redis.call('HDEL', KEYS[1], fields[i])
  else
    counts[f] = tonumber(fields[i + 1])
  end
end

redis.call('HINCRBY', KEYS[1], num(minute), num(cost))
counts[minute] = (counts[minute] or 0) + cost
redis.call('PEXPIRE', KEYS[1], 7200000)

local current_sum = 0
local baseline_sum = 0
for f, c in pairs(counts) do
  if f > minute - current then
    current_sum = current_sum + c
  elseif f > minute - current - baseline then
    baseline_sum = baseline_sum + c
  end
end
return {current_sum, baseline_sum}
