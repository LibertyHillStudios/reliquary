-- Reliquary's clock: every movement in the /rq window runs on it (docs/DESIGN.md, section 2). A tween
-- moves one value of something (a number, or a list of numbers such as a colour) from where it is to
-- where it should be over a time, along an easing curve, through a setter. One ticker frame's OnUpdate
-- moves them all, and it runs only while something is moving: a tween on something hidden lands at
-- once, so nothing moves and nothing ticks while the window is shut. A new tween on the same thing and
-- channel takes over from where the old one is (a retarget), so nothing ever waits for a movement to
-- end. With animations off every tween lands on its end at once. The clock can be stepped by hand
-- (Motion.step), which is how the tests check where things end and how tools/film.sh films the window
-- a frame at a time.
--
--   Motion.to(obj, channel, to, opts)     move obj's channel to `to`; opts below
--   Motion.fade(region, alpha, opts)      its alpha
--   Motion.scale(frame, scale, opts)      its scale
--   Motion.slide(region, dx, dy, opts)    arrive at its anchors from dx, dy units away
--   Motion.arrive(region, i, opts)        fade in and rise from below, the i-th of a list (staggered)
--   Motion.count(fontString, n, opts)     count a number up in a text (opts.from, opts.format)
--   Motion.loop(obj, channel, a, b, period, set)   swing between a and b for as long as obj shows
--   Motion.every(obj, channel, fn)       call fn(obj, dt) every tick for as long as obj shows
--   Motion.finish(obj, channel)           land now (every channel of obj when channel is nil)
--   Motion.stop(obj, channel)             leave it where it is now
--   Motion.finishAll()                    land everything
--   Motion.value(obj, channel)            where a running tween is now, else nil
--   Motion.running(obj, channel)          whether one is running
--   Motion.step(dt)                       move the clock dt seconds
--   Motion.setEnabled(on), Motion.enabled()   animations on or off
--   Motion.ticking(), Motion.moving()     whether the ticker runs, and how many tweens are running
--   Motion.delay(i)                       the stagger delay of the i-th item of a list
--
-- Tokens (below): fast, base, slow, long, close, leave, drift, breathe (seconds); STAGGER and
-- STAGGER_MOST; ROWS_AFTER, HERO_AFTER, PAGE_AFTER (the opening's order); RISE, RISE_WINDOW,
-- SLIDE_PAGE, LEAN (units); OPEN_SCALE, CLOSE_SCALE, DRIFT_SCALE.
--
-- opts: dur (seconds, or a token name: "fast", "base", "slow", "long"), ease (a name in Motion.ease
-- or a function of 0..1), delay (seconds before it starts; it holds its start until then), from (the
-- start; else where the running tween is, else opts.get(obj)), set(obj, value) (how a value is shown;
-- required unless a helper above gives it), get(obj), done(obj) (once it lands; never for one that is
-- replaced or stopped), owner (the region whose visibility counts; obj itself when it is one).
local ADDON, ns = ...

local M = {}
ns.Motion = M

local type, pairs, ipairs, next, tostring = type, pairs, ipairs, next, tostring
local min, max, cos, pi = math.min, math.max, math.cos, math.pi

-- How long things take (DESIGN, section 2), and the stagger between the items of a list. The window
-- closes in close, an old page leaves in leave; the ambient effects swing over drift (the hero's
-- painting) and breathe (the moon in the crest), each way.
M.fast, M.base, M.slow, M.long = 0.10, 0.18, 0.28, 0.45
M.close, M.leave, M.drift, M.breathe = 0.12, 0.08, 24, 4
M.STAGGER, M.STAGGER_MOST = 0.025, 10
-- The opening's order (DESIGN, section 2, moment 1): after the window has begun to open, its list's
-- rows arrive, then the hero's lines, then the page, each this long after the window began.
M.ROWS_AFTER, M.HERO_AFTER, M.PAGE_AFTER = 0.10, 0.16, 0.22
-- Distances things arrive from, in units; the window grows from OPEN_SCALE and shrinks to CLOSE_SCALE;
-- the hero's painting drifts to DRIFT_SCALE and leans up to LEAN units toward the cursor.
M.RISE, M.RISE_WINDOW, M.SLIDE_PAGE = 8, 12, 16
M.OPEN_SCALE, M.CLOSE_SCALE, M.DRIFT_SCALE, M.LEAN = 0.96, 0.98, 1.04, 6

-- Easing curves, each from 0 at t = 0 to 1 at t = 1.
local ease = {}
function ease.linear(t) return t end
function ease.out(t) local u = 1 - t return 1 - u * u * u end                -- cubic out: the default
function ease.enter(t) local u = 1 - t return 1 - u * u * u * u end          -- quart out: arriving
function ease.ambient(t) return 0.5 - 0.5 * cos(pi * t) end                  -- sine in-out: loops
function ease.pop(t) local s, u = 1.4, t - 1 return u * u * ((s + 1) * u + s) + 1 end -- back out, overshoot 1.4
M.ease = ease

local on = true
local tweens = {}                                    -- running, in the order they started
local byObj = setmetatable({}, { __mode = "k" })     -- obj -> { channel -> tween }
-- The ticker: named, as the game's own frames are, so /fstack and the film tool can find it.
local ticker = CreateFrame("Frame", "ReliquaryMotion")
ticker:Hide()

local function duration(d)
    if type(d) == "string" then return M[d] or M.base end
    return type(d) == "number" and d or M.base
end

-- A value between a and b at u (0..1): numbers, or lists of numbers entry by entry.
local function mix(a, b, u, into)
    if type(a) ~= "table" then return a + (b - a) * u end
    into = into or {}
    for i = 1, #b do into[i] = (a[i] or b[i]) + (b[i] - (a[i] or b[i])) * u end
    return into
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for i = 1, #v do c[i] = v[i] end
    return c
end

local function shown(tw)
    local o = tw.owner
    return type(o) ~= "table" or type(o.IsVisible) ~= "function" or o:IsVisible()
end

local function remove(tw)
    tw.dead = true
    local mine = byObj[tw.obj]
    if mine and mine[tw.channel] == tw then mine[tw.channel] = nil end
end

local function land(tw)
    remove(tw)
    if tw.tick then return end
    tw.set(tw.obj, tw.loop and tw.home or tw.to)
    if tw.done and not tw.loop then tw.done(tw.obj) end
end

local function wake()
    if not ticker:IsShown() and #tweens > 0 then ticker:Show() end
end

-- How deep in a step the clock is. An ending may step it again from inside one (the window's closing
-- ends by hiding it, and a hidden window lands everything, M.finishAll): only the outermost step takes
-- what has landed out of the list, so the list is never shortened under a step still walking it.
local depth = 0
function M.step(dt)
    dt = max(0, dt or 0)
    depth = depth + 1
    local n = #tweens
    for i = 1, n do
        local tw = tweens[i]
        if not tw.dead then
            if not shown(tw) then
                land(tw) -- hidden: nothing moves where nobody sees it
            elseif tw.tick then
                tw.tick(tw.obj, dt)
            else
                tw.t = tw.t + dt
                local t = tw.t - tw.delay
                if t >= 0 then
                    local u = tw.dur > 0 and min(1, t / tw.dur) or 1
                    if u >= 1 and tw.loop then
                        -- A loop swings back: the far end is where it starts next.
                        tw.from, tw.to = tw.to, tw.from
                        tw.t, tw.delay = t - tw.dur, 0
                        u = min(1, tw.t / tw.dur)
                    end
                    if u >= 1 then
                        land(tw)
                    else
                        tw.cur = mix(tw.from, tw.to, tw.ease(u), tw.cur)
                        tw.set(tw.obj, tw.cur)
                    end
                end
            end
        end
    end
    depth = depth - 1
    if depth > 0 then return end
    -- What landed or was replaced leaves the list.
    local k = 0
    for i = 1, #tweens do
        local tw = tweens[i]
        if not tw.dead then k = k + 1 tweens[k] = tw end
    end
    for i = #tweens, k + 1, -1 do tweens[i] = nil end
    if #tweens == 0 then ticker:Hide() end
end
-- The game's own tick is always the outermost step: it starts the count afresh, so an error in one
-- movement's ending can't leave the clock thinking it is still inside a step.
ticker:SetScript("OnUpdate", function(_, elapsed)
    depth = 0
    M.step(elapsed)
end)

function M.value(obj, channel)
    local mine = byObj[obj]
    local tw = mine and mine[channel]
    return tw and copy(tw.cur or tw.from) or nil
end

function M.running(obj, channel)
    local mine = byObj[obj]
    if not mine then return false end
    if channel then return mine[channel] ~= nil end
    return next(mine) ~= nil
end

function M.to(obj, channel, to, opts)
    opts = opts or {}
    local set = assert(opts.set, "Motion.to needs a setter")
    local mine = byObj[obj]
    local old = mine and mine[channel]
    local from = opts.from
    if from == nil and old then from = old.cur or old.from end
    if from == nil and opts.get then from = opts.get(obj) end
    if old then remove(old) end
    local dur, delay = duration(opts.dur), opts.delay or 0
    if not on or from == nil or (dur <= 0 and delay <= 0) then
        set(obj, to)
        if opts.done then opts.done(obj) end
        return nil
    end
    local tw = { obj = obj, channel = channel, from = copy(from), to = copy(to), dur = dur, delay = delay, t = 0,
        ease = type(opts.ease) == "function" and opts.ease or ease[opts.ease or "out"] or ease.out,
        set = set, done = opts.done, owner = opts.owner or obj, loop = opts.loop, home = opts.loop and copy(from) or nil }
    if not shown(tw) then
        set(obj, to)
        if opts.done then opts.done(obj) end
        return nil
    end
    tw.cur = copy(tw.from)
    set(obj, tw.cur)
    if not mine then mine = {} byObj[obj] = mine end
    mine[channel] = tw
    tweens[#tweens + 1] = tw
    wake()
    return tw
end

function M.finish(obj, channel)
    local mine = byObj[obj]
    if not mine then return end
    if channel then
        if mine[channel] then land(mine[channel]) end
        return
    end
    for _, tw in pairs(mine) do land(tw) end
end

function M.stop(obj, channel)
    local mine = byObj[obj]
    if not mine then return end
    if channel then
        if mine[channel] then remove(mine[channel]) end
        return
    end
    for _, tw in pairs(mine) do remove(tw) end
end

function M.finishAll()
    for _, tw in ipairs(tweens) do if not tw.dead then land(tw) end end
    M.step(0)
end

function M.setEnabled(v)
    on = v and true or false
    if not on then M.finishAll() end
end
function M.enabled() return on end
function M.ticking() return ticker:IsShown() end

function M.delay(i)
    return M.STAGGER * min(max((i or 1) - 1, 0), M.STAGGER_MOST - 1)
end

---------------------------------------------------------------------------
-- The usual channels
---------------------------------------------------------------------------
local function setAlpha(r, a) r:SetAlpha(a) end
local function getAlpha(r) return r:GetAlpha() end
function M.fade(region, alpha, opts)
    opts = opts or {}
    opts.set, opts.get = opts.set or setAlpha, opts.get or getAlpha
    return M.to(region, "alpha", alpha, opts)
end

local function setScale(f, s) f:SetScale(s) end
local function getScale(f) return f:GetScale() end
function M.scale(frame, scale, opts)
    opts = opts or {}
    opts.set, opts.get = opts.set or setScale, opts.get or getScale
    return M.to(frame, "scale", scale, opts)
end

-- Where a region rests, read once: every anchor it has, so a slide moves them all together and puts
-- them back exactly.
local rest = setmetatable({}, { __mode = "k" })
local function restOf(region)
    local r = rest[region]
    if r then return r end
    r = {}
    for i = 1, region:GetNumPoints() do r[i] = { region:GetPoint(i) } end
    rest[region] = r
    return r
end
local function place(region, dx, dy)
    for _, p in ipairs(restOf(region)) do region:SetPoint(p[1], p[2], p[3], (p[4] or 0) + dx, (p[5] or 0) + dy) end
end

-- Arrives at its own anchors from dx, dy units away. Anchors set while it slides are its new rest.
function M.slide(region, dx, dy, opts)
    opts = opts or {}
    if not M.running(region, "slide") then rest[region] = nil end
    local done = opts.done
    opts.set = function(r, v) place(r, v[1], v[2]) end
    opts.done = function(r)
        rest[r] = nil
        if done then done(r) end
    end
    if opts.from == nil then opts.from = M.value(region, "slide") or { dx, dy } end
    return M.to(region, "slide", opts.to or { 0, 0 }, opts)
end

-- The i-th item of a list arriving: it fades in and rises into place, after the ones before it.
function M.arrive(region, i, opts)
    opts = opts or {}
    local dur, delay = opts.dur or "base", (opts.delay or 0) + M.delay(i)
    M.fade(region, 1, { from = 0, dur = dur, delay = delay, ease = "enter" })
    M.slide(region, 0, -(opts.rise or M.RISE), { dur = dur, delay = delay, ease = "enter" })
end

-- A number counted in a text: from opts.from (0 when the page arrives), shown by opts.format (whole
-- numbers by default).
function M.count(fs, n, opts)
    opts = opts or {}
    local fmt = opts.format or function(v) return tostring(math.floor(v + 0.5)) end
    return M.to(fs, "count", n, { from = opts.from, dur = opts.dur or "long", delay = opts.delay, ease = opts.ease or "out",
        set = function(f, v) f:SetText(fmt(v)) end, get = opts.get, owner = opts.owner })
end

-- An ambient swing between a and b over period seconds each way, for as long as obj shows; hidden, it
-- stops at a. Shown again, its owner starts it again.
function M.loop(obj, channel, a, b, period, set, owner)
    if not on then
        set(obj, a)
        return nil
    end
    return M.to(obj, channel, b, { from = a, dur = period, ease = "ambient", set = set, loop = true, owner = owner })
end

-- Something done every tick while obj shows (the hero leaning toward the cursor): fn(obj, dt). Hidden,
-- it stops; its owner starts it again when shown. Nothing, with animations off.
function M.every(obj, channel, fn, owner)
    if not on then return nil end
    local mine = byObj[obj]
    if mine and mine[channel] then remove(mine[channel]) end
    local tw = { obj = obj, channel = channel, tick = fn, owner = owner or obj, t = 0, delay = 0, dur = 0 }
    if not shown(tw) then return nil end
    if not mine then mine = {} byObj[obj] = mine end
    mine[channel] = tw
    tweens[#tweens + 1] = tw
    wake()
    return tw
end

-- How many tweens are running now.
function M.moving()
    local n = 0
    for _, tw in ipairs(tweens) do if not tw.dead then n = n + 1 end end
    return n
end
