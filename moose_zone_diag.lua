--[[
MZ-DIAG: MOOSE + Zone initialization diagnostics

Usage (DCS Mission Editor):
- TRIGGER: MISSION START -> ACTION: DO SCRIPT FILE (load Moose.lua first)
- TRIGGER: TIME MORE (1)  -> ACTION: DO SCRIPT FILE (this file: DCS-CTLD-1.6.1/moose_zone_diag.lua)
- Optional: TRIGGER: TIME MORE (3) -> DO SCRIPT / DO SCRIPT FILE for your mission logic that relies on MOOSE

This script is safe to run even if MOOSE is not loaded yet. It will:
1) Print clear on-screen + log messages confirming it executed
2) Detect whether MOOSE core classes (ZONE/MESSAGE/SCHEDULER/BASE) are available
3) Verify Mission Editor trigger zones named: Alpha, Bravo, Charlie, Delta, Echo
4) Smoke each found ME zone center (DCS native API) so you can visually confirm
5) If MOOSE is present: also build ZONE objects, attempt MOOSE smoke/draw, and set up a basic BLUE detection scheduler (guarded for API differences)
6) If MOOSE is not present at load time: periodically re-check for it for ~30s and report when detected

Notes:
- This script avoids hard-failing if certain MOOSE methods are unavailable in your build.
- All diagnostics are prefixed with [MZ-DIAG] in both on-screen text and dcs.log (env.info).
]]

-- Toggleable smoke for diagnostics (disabled by default). Set global MZ_ENABLE_DIAG_SMOKE=true to enable at runtime.
local function _g(name) return rawget(_G, name) end
local ENABLE_SMOKE = false

local function _diagOut(msg, dur)
  dur = dur or 10
  if trigger and trigger.action and trigger.action.outText then
    trigger.action.outText("[MZ-DIAG] " .. tostring(msg), dur)
  end
  if env and env.info then
    env.info("[MZ-DIAG] " .. tostring(msg))
  end
end

local startTime = (timer and timer.getTime and timer.getTime()) or 0
_diagOut(string.format("Diagnostic script loaded (t=%.1fs)", startTime))

local hasZONE      = _g("ZONE")      ~= nil
local hasMESSAGE   = _g("MESSAGE")   ~= nil
local hasSCHEDULER = _g("SCHEDULER") ~= nil
local hasBASE      = _g("BASE")      ~= nil
local hasSET_UNIT  = _g("SET_UNIT")  ~= nil

if hasZONE or hasMESSAGE or hasSCHEDULER or hasBASE then
  _diagOut(string.format(
    "MOOSE core visibility — ZONE:%s MESSAGE:%s SCHEDULER:%s BASE:%s",
    tostring(hasZONE), tostring(hasMESSAGE), tostring(hasSCHEDULER), tostring(hasBASE)
  ))
else
  _diagOut("MOOSE core NOT detected at load time (expected if Moose.lua not yet loaded or load order is wrong)")
end

-- Verify and smoke Mission Editor zones by native DCS API (works without MOOSE)
local zoneNames = {"Alpha", "Bravo", "Charlie", "Delta", "Echo"}
local foundCount = 0

for _, zn in ipairs(zoneNames) do
  local z = (trigger and trigger.misc and trigger.misc.getZone) and trigger.misc.getZone(zn) or nil
  if z and z.point then
    foundCount = foundCount + 1
    -- DCS SmokeColor values: 0=Green, 1=Red, 2=White, 3=Orange, 4=Blue
    if (ENABLE_SMOKE or _g("MZ_ENABLE_DIAG_SMOKE")) and trigger and trigger.action and trigger.action.smoke then
      pcall(function() trigger.action.smoke(z.point, 4) end)
    end
    _diagOut(string.format("Found ME zone '%s'", zn), 8)
  else
    _diagOut(string.format("ME zone '%s' not found — check exact name spelling in the Mission Editor", zn), 8)
  end
end

_diagOut(string.format("ME zones found: %d/%d", foundCount, #zoneNames))

-- If MOOSE is available, also try MOOSE-based zone ops (guarded)
if hasZONE and hasMESSAGE then
  local mooseZones = {}
  for _, zn in ipairs(zoneNames) do
    local ok, zoOrErr = pcall(function() return ZONE:New(zn) end)
    if ok and zoOrErr then
      local zo = zoOrErr
      table.insert(mooseZones, zo)
      -- Try MOOSE smoke if available
      if zo.Smoke then pcall(function() zo:Smoke(SMOKECOLOR and SMOKECOLOR.Blue or 4) end) end
      -- On-screen confirmation via MOOSE MESSAGE if available
      pcall(function() MESSAGE:New("Zone " .. zo:GetName() .. " active (MOOSE)", 10):ToAll() end)
      -- Try to draw zone if this MOOSE method exists in your build
      if zo.DrawZone then
        pcall(function() zo:DrawZone(-1, {1, 0, 0}, 0.5, {1, 0, 0}, 0.2, 2) end)
      end
    else
      _diagOut(string.format("MOOSE ZONE:New('%s') failed: %s", zn, tostring(zoOrErr)))
    end
  end

  _diagOut(string.format("MOOSE constructed zones: %d", #mooseZones))

  -- Basic BLUE detection using MOOSE, if components are present
  if hasSET_UNIT and hasSCHEDULER then
    local BlueSet = nil
    pcall(function()
      BlueSet = SET_UNIT:New():FilterCoalitions("blue"):FilterStart()
    end)

    if BlueSet then
      pcall(function()
        SCHEDULER:New(nil, function()
          for _, zo in ipairs(mooseZones) do
            local any = false
            if type(zo.IsAnyInZone) == "function" then
              local okAny, res = pcall(function() return zo:IsAnyInZone(BlueSet) end)
              any = okAny and res or false
            elseif type(BlueSet.ForEachUnitInZone) == "function" then
              any = false
              BlueSet:ForEachUnitInZone(zo, function() any = true end)
            end
            if any then
              if hasBASE then
                pcall(function() BASE:E("Player detected in zone: " .. zo:GetName()) end)
              end
              _diagOut("Blue unit detected in " .. (zo.GetName and zo:GetName() or "<unknown zone>"), 5)
            end
          end
        end, {}, 5, 30)
      end)
    else
      _diagOut("Skipping MOOSE detection scheduler: could not create SET_UNIT for BLUE")
    end
  else
    _diagOut("Skipping MOOSE detection scheduler: SET_UNIT or SCHEDULER not available")
  end
else
  -- No MOOSE at load time — keep re-checking briefly and notify if/when it appears
  if timer and type(timer.scheduleFunction) == "function" and type(timer.getTime) == "function" then
    local t0 = timer.getTime()
    local function _waitMoose(checkTime)
      if _g("ZONE") and _g("MESSAGE") then
        local dt = timer.getTime() - t0
        _diagOut(string.format("MOOSE core detected after %.1fs. Ensure this diag file loads AFTER Moose.lua.", dt))
        return nil -- stop scheduling
      end
      return checkTime + 1 -- check again in 1 second
    end
    timer.scheduleFunction(_waitMoose, nil, timer.getTime() + 1)
  end
end

