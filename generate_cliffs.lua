--[[ generate_cliffs.lua
  Port of the Stepped Mountain generator's cliff pipeline (index.html), 1:1 with
  the website's logic. Given the same configuration (the JSON from "Export
  settings"), it produces the same step grid and the same cliff-tile table.

  Requires Lua 5.3+ (uses integer bitwise operators & integer/float subtypes).
  (Factorio runs Lua 5.2 with `bit32` instead — ask for that variant if needed.)

  Usage:
    lua generate_cliffs.lua            -- runs the demo at the bottom
    local M = require("generate_cliffs")
    local cliffs, steps, R = M.generate(config)
      cliffs[y][x] = "east-to-south" | ... | nil   (1..R, nil = not a cliff tile)
      steps[y][x]  = elevation level 0..steps       (0 = base)
  `config` uses the same keys as the site's exported settings (see DEFAULTS).
]]

local floor, sqrt, abs = math.floor, math.sqrt, math.abs
local cos, sin, exp, pi = math.cos, math.sin, math.exp, math.pi
local hypot = function(a, b) return sqrt(a * a + b * b) end       -- matches Math.hypot for finite small values
local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 else return x end end
local function lerp(a, b, t) return a + (b - a) * t end
local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end

-- ===================================================================
-- 32-bit PRNG (mulberry32) — bit-identical to the JS version
-- ===================================================================
local MASK = 0xFFFFFFFF
local function imul(a, b)               -- low 32 bits of a*b, like JS Math.imul
  a = a & MASK; b = b & MASK
  local ahi, alo = a >> 16, a & 0xFFFF
  return (alo * b + (((ahi * b) & 0xFFFF) << 16)) & MASK
end
local function mulberry32(seed)
  local a = seed & MASK
  return function()
    a = (a + 0x6D2B79F5) & MASK
    local t = imul(a ~ (a >> 15), a | 1)
    t = ((t + imul(t ~ (t >> 7), t | 61)) & MASK) ~ t
    t = t & MASK
    return ((t ~ (t >> 14)) & MASK) / 4294967296.0
  end
end

-- ===================================================================
-- Noise
-- ===================================================================
local function makePerlin(seed)
  local rnd = mulberry32(seed)
  local perm = {}
  for i = 0, 255 do perm[i] = i end
  for i = 255, 1, -1 do
    local j = floor(rnd() * (i + 1))
    perm[i], perm[j] = perm[j], perm[i]
  end
  local p = {}
  for i = 0, 511 do p[i] = perm[i & 255] end
  local function grad(h, x, y)
    local hh = h & 7
    if hh == 0 then return x + y elseif hh == 1 then return -x + y
    elseif hh == 2 then return x - y elseif hh == 3 then return -x - y
    elseif hh == 4 then return x elseif hh == 5 then return -x
    elseif hh == 6 then return y else return -y end
  end
  return function(x, y)
    local fxp, fyp = floor(x), floor(y)
    local X, Y = fxp & 255, fyp & 255
    local xf, yf = x - fxp, y - fyp
    local u, v = fade(xf), fade(yf)
    local aa = p[p[X] + Y]
    local ab = p[p[X] + Y + 1]
    local ba = p[p[X + 1] + Y]
    local bb = p[p[X + 1] + Y + 1]
    local x1 = lerp(grad(aa, xf, yf), grad(ba, xf - 1, yf), u)
    local x2 = lerp(grad(ab, xf, yf - 1), grad(bb, xf - 1, yf - 1), u)
    return lerp(x1, x2, v)
  end
end

local function makeValue(seed)
  local rnd = mulberry32(seed)
  local size = 256
  local tab = {}
  for i = 0, size * size - 1 do tab[i] = rnd() * 2 - 1 end
  local function at(xi, yi) return tab[((yi & 255) * size) + (xi & 255)] end
  return function(x, y)
    local X, Y = floor(x), floor(y)
    local xf, yf = x - X, y - Y
    local u, v = fade(xf), fade(yf)
    local x1 = lerp(at(X, Y), at(X + 1, Y), u)
    local x2 = lerp(at(X, Y + 1), at(X + 1, Y + 1), u)
    return lerp(x1, x2, v)
  end
end

local function fbm(noise, x, y, oct, pers, lac)
  local amp, freq, sum, norm = 1, 1, 0, 0
  for _ = 1, oct do
    sum = sum + amp * noise(x * freq, y * freq)
    norm = norm + amp; amp = amp * pers; freq = freq * lac
  end
  return sum / norm
end
local function ridged(noise, x, y, oct, pers, lac)
  local amp, freq, sum, norm = 1, 1, 0, 0
  for _ = 1, oct do
    local n = 1 - abs(noise(x * freq, y * freq))
    sum = sum + amp * n * n
    norm = norm + amp; amp = amp * pers; freq = freq * lac
  end
  return (sum / norm) * 2 - 1
end

local function makeDiamondSquare(seed, roughness)
  local n = 8
  local size = (1 << n) + 1
  local g = {}
  local rnd = mulberry32(seed)
  local function idx(x, y) return y * size + x end
  local function jitter(s) return (rnd() * 2 - 1) * s end
  g[idx(0, 0)] = jitter(1); g[idx(size - 1, 0)] = jitter(1)
  g[idx(0, size - 1)] = jitter(1); g[idx(size - 1, size - 1)] = jitter(1)
  local step, scale = size - 1, 1
  while step > 1 do
    local half = step >> 1
    local y = half
    while y < size do
      local x = half
      while x < size do
        local a = g[idx(x - half, y - half)]; local b = g[idx(x + half, y - half)]
        local c = g[idx(x - half, y + half)]; local d = g[idx(x + half, y + half)]
        g[idx(x, y)] = (a + b + c + d) / 4 + jitter(scale)
        x = x + step
      end
      y = y + step
    end
    y = 0
    while y < size do
      local x = (y + half) % step
      while x < size do
        local sum, cnt = 0, 0
        if x - half >= 0   then sum = sum + g[idx(x - half, y)]; cnt = cnt + 1 end
        if x + half < size then sum = sum + g[idx(x + half, y)]; cnt = cnt + 1 end
        if y - half >= 0   then sum = sum + g[idx(x, y - half)]; cnt = cnt + 1 end
        if y + half < size then sum = sum + g[idx(x, y + half)]; cnt = cnt + 1 end
        g[idx(x, y)] = sum / cnt + jitter(scale)
        x = x + step
      end
      y = y + half
    end
    step = half; scale = scale * roughness
  end
  return function(u, v)
    local fx, fy = clamp01(u) * (size - 1), clamp01(v) * (size - 1)
    local x0, y0 = floor(fx), floor(fy)
    local x1 = math.min(x0 + 1, size - 1); local y1 = math.min(y0 + 1, size - 1)
    local tx, ty = fx - x0, fy - y0
    local a = lerp(g[idx(x0, y0)], g[idx(x1, y0)], tx)
    local b = lerp(g[idx(x0, y1)], g[idx(x1, y1)], tx)
    return lerp(a, b, ty)
  end
end

local function distToSegment(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  if len2 == 0 then return hypot(px - ax, py - ay) end
  local t = ((px - ax) * dx + (py - ay) * dy) / len2
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return hypot(px - (ax + t * dx), py - (ay + t * dy))
end

-- ===================================================================
-- Heightfield -> step grid (flat 0-based array, index = y*R + x)
-- ===================================================================
local function buildField(P)
  local R = P.res
  local field = {}
  local gen
  if P.algo == "perlin" then
    local noise = makePerlin(P.seed)
    gen = function(u, v) return fbm(noise, u * P.freq, v * P.freq, P.oct, P.pers, P.lac) end
  elseif P.algo == "value" then
    local noise = makeValue(P.seed)
    gen = function(u, v) return fbm(noise, u * P.freq, v * P.freq, P.oct, P.pers, P.lac) end
  elseif P.algo == "ridged" then
    local noise = makePerlin(P.seed)
    gen = function(u, v) return ridged(noise, u * P.freq, v * P.freq, P.oct, P.pers, P.lac) end
  elseif P.algo == "diamond" then
    local ds = makeDiamondSquare(P.seed, P.rough)
    gen = function(u, v) return ds(u, v) end
  elseif P.algo == "cone" then
    gen = function(u, v) local d = hypot(u - 0.5, v - 0.5) / 0.5; return (1 - d) * 2 - 1 end
  else
    gen = function(u, v) local d2 = (u - 0.5) ^ 2 + (v - 0.5) ^ 2; return exp(-d2 / (2 * 0.10)) * 2 - 1 end
  end

  local warpX = makePerlin((P.seed ~ 0x9e3779b1) & MASK)
  local warpY = makePerlin((P.seed ~ 0x85ebca77) & MASK)
  local edgeN = makePerlin((P.seed ~ 0xc2b2ae3d) & MASK)

  local ang = P.rot * pi
  local ca, sa = cos(ang), sin(ang)
  local fx = math.max(0.3, 1 + P.stretch)
  local fy = math.max(0.3, 1 - P.stretch)

  local spinePts, spineWn = nil, 0
  if P.mode == "range" and P.fall > 0 then
    local hl = P.rad * 0.45
    local x1, y1 = 0.5 - hl * ca, 0.5 - hl * sa
    local x2, y2 = 0.5 + hl * ca, 0.5 + hl * sa
    spineWn = P.rangeWidth / P.res
    local N = 24
    spinePts = {}
    for k = 0, N do
      local t = k / N
      local bx = x1 + t * (x2 - x1)
      local by = y1 + t * (y2 - y1)
      if P.spineWarp > 0 then
        local disp = P.spineWarp * sin(t * pi * P.spineWarpScale)
        bx = bx + disp * (-sa)
        by = by + disp * ca
      end
      spinePts[k * 2] = bx
      spinePts[k * 2 + 1] = by
    end
  end

  local min, max = math.huge, -math.huge
  for j = 0, R - 1 do
    local v = j / (R - 1)
    for i = 0, R - 1 do
      local u = i / (R - 1)
      local su, sv = u, v
      if P.warp > 0 then
        su = u + P.warp * warpX(u * P.warpScale, v * P.warpScale)
        sv = v + P.warp * warpY(u * P.warpScale + 5.2, v * P.warpScale + 1.7)
      end
      local h = gen(su, sv)
      h = (h + 1) * 0.5
      if P.fall > 0 then
        local d
        if P.mode == "range" then
          local minD = math.huge
          for k = 0, 23 do                                -- N = 24 segments (points 0..24)
            local dd = distToSegment(u, v, spinePts[k * 2], spinePts[k * 2 + 1], spinePts[k * 2 + 2], spinePts[k * 2 + 3])
            if dd < minD then minD = dd end
          end
          d = minD / math.max(spineWn, 0.001)
        else
          local rx = ((u - 0.5) * ca + (v - 0.5) * sa) / fx
          local ry = (-(u - 0.5) * sa + (v - 0.5) * ca) / fy
          d = hypot(rx, ry) / 0.5 / P.rad
        end
        if P.edge > 0 then
          d = d * (1 + P.edge * edgeN(u * P.edgeScale + 3.1, v * P.edgeScale + 9.4))
        end
        local mask = clamp01(1 - clamp01(d) ^ P.fall)
        h = h * mask
      end
      field[j * R + i] = h
      if h < min then min = h end
      if h > max then max = h end
    end
  end

  local span = (max - min)
  if span == 0 then span = 1 end
  for k = 0, R * R - 1 do
    local h = (field[k] - min) / span
    if P.sharp ~= 1 then h = h ^ P.sharp end
    field[k] = h
  end
  return field
end

local function levelsFor(P)
  local out = {}
  for s = 1, P.steps do
    local t = s / (P.steps + 1)
    if P.spacing == "ease" then t = 1 - (1 - t) ^ 2
    elseif P.spacing == "easein" then t = t ^ 2 end
    out[s - 1] = t           -- 0-based to match JS
  end
  return out, P.steps
end

-- ===================================================================
-- Cleanup (erode + raise), identical to cleanCliffs()
-- ===================================================================
local ONE_WIDE = { [5] = true, [10] = true, [7] = true, [11] = true, [13] = true, [14] = true, [15] = true }
local function clampIdx(v, R) if v < 0 then return 0 elseif v > R - 1 then return R - 1 else return v end end

local function cleanCliffs(grid, R)
  local function sAt(x, y) return grid[clampIdx(y, R) * R + clampIdx(x, R)] end
  local function idx(x, y) return y * R + x end

  local function erode()
    local ch = false
    for y = 0, R - 1 do for x = 0, R - 1 do
      local s = grid[idx(x, y)]
      if s ~= 0 then
        local n, e, so, w = sAt(x, y - 1), sAt(x + 1, y), sAt(x, y + 1), sAt(x - 1, y)
        if math.max(n, e, so, w) <= s then
          local mask = (n < s and 1 or 0) | (e < s and 2 or 0) | (so < s and 4 or 0) | (w < s and 8 or 0)
          if ONE_WIDE[mask] then
            grid[idx(x, y)] = math.max(n < s and n or 0, e < s and e or 0, so < s and so or 0, w < s and w or 0)
            ch = true
          end
        end
      end
    end end
    return ch
  end

  local function raise()
    local ch = false
    for y = 0, R - 1 do for x = 0, R - 1 do
      local m = 0
      for dy = -1, 1 do for dx = -1, 1 do
        if dx ~= 0 or dy ~= 0 then local nv = sAt(x + dx, y + dy); if nv > m then m = nv end end
      end end
      if grid[idx(x, y)] < m - 1 then grid[idx(x, y)] = m - 1; ch = true end
    end end
    for y = 0, R - 2 do for x = 0, R - 2 do
      local a, b = grid[idx(x, y)], grid[idx(x + 1, y)]
      local c, d = grid[idx(x, y + 1)], grid[idx(x + 1, y + 1)]
      if math.min(a, d) > math.max(b, c) then grid[idx(x + 1, y)] = math.min(a, d); ch = true
      elseif math.min(b, c) > math.max(a, d) then grid[idx(x, y)] = math.min(b, c); ch = true
      elseif b == c and a ~= b and d ~= b then
        if a < b then grid[idx(x, y)] = b; ch = true elseif d < b then grid[idx(x + 1, y + 1)] = b; ch = true end
      elseif a == d and b ~= a and c ~= a then
        if b < a then grid[idx(x + 1, y)] = a; ch = true elseif c < a then grid[idx(x, y + 1)] = a; ch = true end
      end
    end end
    for y = 0, R - 1 do for x = 0, R - 1 do
      local s = grid[idx(x, y)]
      local n, e, so, w = sAt(x, y - 1), sAt(x + 1, y), sAt(x, y + 1), sAt(x - 1, y)
      if not (n < s or e < s or so < s or w < s) then
        if sAt(x - 1, y - 1) < s and sAt(x + 1, y + 1) < s then grid[idx(x - 1, y - 1)] = math.min(n, w); ch = true
        elseif sAt(x + 1, y - 1) < s and sAt(x - 1, y + 1) < s then grid[idx(x + 1, y - 1)] = math.min(n, e); ch = true end
      end
    end end
    return ch
  end

  for _ = 1, 16 do
    local any = false
    local g = 0; while erode() and g < 256 do any = true; g = g + 1 end
    g = 0; while raise() and g < 256 do any = true; g = g + 1 end
    if not any then break end
  end
end

-- ===================================================================
-- Ring tracer -> per-tile cliff name (identical to ringCliffs())
-- ===================================================================
local RING_DIRS = { N = { 0, -1 }, E = { 1, 0 }, S = { 0, 1 }, W = { -1, 0 } }
local RING_LEFT = { E = "N", N = "W", W = "S", S = "E" }
local RING_RIGHT = { E = "S", S = "W", W = "N", N = "E" }
local RING_BACK = { E = "W", W = "E", N = "S", S = "N" }
local ORDER = { "E", "N", "W", "S" }
local function dirName(dx, dy)
  if dx == 1 then return "east" elseif dx == -1 then return "west"
  elseif dy == 1 then return "south" else return "north" end
end
local function leftCellOf(cx, cy, d)
  if d == "E" then return cx, cy - 1 elseif d == "N" then return cx - 1, cy - 1
  elseif d == "W" then return cx - 1, cy else return cx, cy end
end
local function rightCellOf(cx, cy, d)
  if d == "E" then return cx, cy elseif d == "N" then return cx, cy - 1
  elseif d == "W" then return cx - 1, cy - 1 else return cx - 1, cy end
end

local VALID = {
  ["east-to-west"] = true, ["west-to-east"] = true, ["north-to-south"] = true, ["south-to-north"] = true,
  ["east-to-south"] = true, ["south-to-west"] = true, ["west-to-north"] = true, ["north-to-east"] = true,
  ["east-to-north"] = true, ["south-to-east"] = true, ["west-to-south"] = true, ["north-to-west"] = true,
}

local function traceRingLoops(inA, R)
  local function ok(cx, cy, d)
    local lx, ly = leftCellOf(cx, cy, d)
    local rx, ry = rightCellOf(cx, cy, d)
    return inA(lx, ly) and not inA(rx, ry)
  end
  local seen = {}
  local function key(cx, cy, d) return cx .. "," .. cy .. "," .. d end
  local loops = {}
  for sy = 0, R do for sx = 0, R do for _, d0 in ipairs(ORDER) do
    if ok(sx, sy, d0) and not seen[key(sx, sy, d0)] then
      local owners = {}
      local cx, cy, d = sx, sy, d0
      local guard = 0
      while guard < R * R * 8 do
        if seen[key(cx, cy, d)] then break end
        seen[key(cx, cy, d)] = true
        local lx, ly = leftCellOf(cx, cy, d)
        owners[#owners + 1] = { x = lx, y = ly }
        local nx, ny = cx + RING_DIRS[d][1], cy + RING_DIRS[d][2]
        local pick = nil
        for _, t in ipairs({ RING_LEFT[d], d, RING_RIGHT[d], RING_BACK[d] }) do
          if ok(nx, ny, t) then pick = t; break end
        end
        if not pick then break end
        cx, cy, d = nx, ny, pick
        guard = guard + 1
      end
      if #owners > 0 then loops[#loops + 1] = owners end
    end
  end end end
  return loops
end

local function nameRingLoop(loop, inA)
  local function dedup(arr)
    local s = {}
    for _, c in ipairs(arr) do
      local l = s[#s]
      if not l or l.x ~= c.x or l.y ~= c.y then s[#s + 1] = c end
    end
    if #s > 1 then local a, b = s[1], s[#s]; if a.x == b.x and a.y == b.y then s[#s] = nil end end
    return s
  end
  local seq = dedup(loop)
  local exp = {}
  for i = 1, #seq do
    local c = seq[i]
    local q = seq[(i % #seq) + 1]
    exp[#exp + 1] = c
    if abs(q.x - c.x) == 1 and abs(q.y - c.y) == 1 then
      local o1x, o1y = c.x, q.y
      local o2x, o2y = q.x, c.y
      if inA(o1x, o1y) then exp[#exp + 1] = { x = o1x, y = o1y }
      else exp[#exp + 1] = { x = o2x, y = o2y } end
    end
  end
  seq = dedup(exp)
  local out, n = {}, #seq
  for i = 1, n do
    local c = seq[i]
    local p = seq[((i - 2) % n) + 1]
    local q = seq[(i % n) + 1]
    out[#out + 1] = {
      x = c.x, y = c.y,
      name = dirName(p.x - c.x, p.y - c.y) .. "-to-" .. dirName(q.x - c.x, q.y - c.y),
    }
  end
  return out
end

local function ringCliffs(stepGrid, R)
  local maxL = 0
  for i = 0, R * R - 1 do if stepGrid[i] > maxL then maxL = stepGrid[i] end end
  local cliff = {}   -- key = y*R+x -> name
  for L = maxL, 1, -1 do
    local function inA(x, y) return x >= 0 and y >= 0 and x < R and y < R and stepGrid[y * R + x] >= L end
    for _, loop in ipairs(traceRingLoops(inA, R)) do
      for _, cell in ipairs(nameRingLoop(loop, inA)) do
        local k = cell.y * R + cell.x
        if VALID[cell.name] and cliff[k] == nil then cliff[k] = cell.name end
      end
    end
  end
  return cliff
end

-- ===================================================================
-- Public: generate(config) -> cliffs[y][x], steps[y][x], R   (1-based)
-- ===================================================================
local function computeStepGrid(P)
  local R = P.res
  local field = buildField(P)
  local levels, nSteps = levelsFor(P)
  local stepGrid = {}
  for y = 0, R - 1 do
    for x = 0, R - 1 do
      local h = field[y * R + x]
      local s = 0
      while s < nSteps and h > levels[s] do s = s + 1 end
      stepGrid[y * R + x] = s
    end
  end
  if P.clean then cleanCliffs(stepGrid, R) end
  return stepGrid, R, nSteps
end

local function generate(config)
  local P = {}
  for k, v in pairs(config) do P[k] = v end
  P.res = math.floor(P.res)
  P.steps = math.floor(P.steps)
  P.oct = math.floor(P.oct)
  P.seed = math.floor(P.seed) & MASK
  if P.mode == nil then P.mode = "single" end
  if P.clean == nil then P.clean = true end

  local stepGrid, R = computeStepGrid(P)
  local cliffMap = ringCliffs(stepGrid, R)

  local cliffs, steps = {}, {}
  for y = 0, R - 1 do
    local rowC, rowS = {}, {}
    for x = 0, R - 1 do
      rowS[x + 1] = stepGrid[y * R + x]
      rowC[x + 1] = cliffMap[y * R + x]   -- string or nil
    end
    cliffs[y + 1] = rowC
    steps[y + 1] = rowS
  end
  return cliffs, steps, R
end

-- Full pipeline snapshot for the website backend: every stage the UI can show.
-- cliffs cells are the name string or NULL sentinel (so JSON arrays stay dense).
local NULL = setmetatable({}, { __name = "json-null" })
-- Returns (result, timings). `clock` is an optional high-res now() function
-- (e.g. socket.gettime); falls back to os.clock. timings are in milliseconds.
local function pipeline(config, clock)
  clock = clock or os.clock
  local timings = {}
  local function mark(name, t0) timings[name] = (clock() - t0) * 1000 end

  local P = {}
  for k, v in pairs(config) do P[k] = v end
  P.res = math.floor(P.res); P.steps = math.floor(P.steps); P.oct = math.floor(P.oct)
  P.seed = math.floor(P.seed) & MASK
  if P.mode == nil then P.mode = "single" end
  if P.clean == nil then P.clean = true end
  local R = P.res

  local t = clock()
  local Praw = {}; for k, v in pairs(P) do Praw[k] = v end; Praw.fall = 0
  local rawF = buildField(Praw); mark("rawField", t)

  t = clock(); local shF = buildField(P); mark("shapedField", t)

  t = clock()
  local levels, nSteps = levelsFor(P)
  local preclean = {}
  for y = 0, R - 1 do for x = 0, R - 1 do
    local h = shF[y * R + x]; local s = 0
    while s < nSteps and h > levels[s] do s = s + 1 end
    preclean[y * R + x] = s
  end end
  mark("quantize", t)

  t = clock()
  local cleaned = {}; for i = 0, R * R - 1 do cleaned[i] = preclean[i] end
  cleanCliffs(cleaned, R)
  mark("clean", t)

  t = clock()
  local active = P.clean and cleaned or preclean
  local cliffMap = ringCliffs(active, R)
  mark("trace", t)

  t = clock()
  local function to2D(flat)
    local tt = {}
    for y = 0, R - 1 do local r = {}; for x = 0, R - 1 do r[x + 1] = flat[y * R + x] end; tt[y + 1] = r end
    return tt
  end
  local cliffs2D = {}
  for y = 0, R - 1 do
    local r = {}
    for x = 0, R - 1 do r[x + 1] = cliffMap[y * R + x] or NULL end
    cliffs2D[y + 1] = r
  end
  local result = {
    R = R, nSteps = nSteps,
    rawField = to2D(rawF), shapedField = to2D(shF),
    stepGrid = to2D(preclean), cleanGrid = to2D(cleaned),
    cliffs = cliffs2D,
  }
  mark("format", t)
  return result, timings
end

local M = {
  generate = generate,
  computeStepGrid = computeStepGrid,
  pipeline = pipeline,
  buildField = buildField,
  levelsFor = levelsFor,
  cleanCliffs = cleanCliffs,
  ringCliffs = ringCliffs,
  NULL = NULL,
}

-- ===================================================================
-- Example config (same keys as the site's exported settings) + demo
-- ===================================================================
M.DEFAULTS = {
  res = 64, clean = true, steps = 8, spacing = "linear",
  algo = "perlin", seed = 1337,
  freq = 3, oct = 5, pers = 0.5, lac = 2, rough = 0.55,
  fall = 2.2, rad = 0.85, sharp = 1,
  stretch = 0, rot = 0, edge = 0.35, edgeScale = 1.6, warp = 0.18, warpScale = 2,
  mode = "single", rangeWidth = 15, spineWarp = 0, spineWarpScale = 1,
}

if arg then   -- run standalone: `lua generate_cliffs.lua`
  local cliffs, steps, R = generate(M.DEFAULTS)
  local count = 0
  for y = 1, R do for x = 1, R do if cliffs[y][x] then count = count + 1 end end end
  io.write(("Generated %dx%d map, %d cliff tiles.\n"):format(R, R, count))
  local abbr = {
    ["east-to-west"] = "-", ["west-to-east"] = "-", ["north-to-south"] = "|", ["south-to-north"] = "|",
    ["east-to-south"] = "7", ["south-to-west"] = "J", ["west-to-north"] = "L", ["north-to-east"] = "r",
    ["east-to-north"] = "b", ["south-to-east"] = "F", ["west-to-south"] = "T", ["north-to-west"] = "d",
  }
  local stepi = math.max(1, R // 48)
  for y = 1, R, stepi do
    local line = {}
    for x = 1, R, stepi do
      local c = cliffs[y][x]
      line[#line + 1] = c and (abbr[c] or "?") or (steps[y][x] > 0 and "." or " ")
    end
    print(table.concat(line))
  end
end

return M
