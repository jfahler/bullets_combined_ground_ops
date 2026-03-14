--[[
MOOSE Zone Initializer (robust, load-order safe)

Purpose:
- Waits until MOOSE core is actually available AND your Mission Editor trigger zones exist
- Then constructs MOOSE ZONE objects for your map capture points (Alpha..Echo by default)
- Optionally smokes and draws each zone for quick visual validation
- Starts a periodic BLUE unit detection over the defined zones (guarded across MOOSE versions)
- Spawns BLUE and RED ground forces that advance toward capture zones with waypoint routes
- Enforces unit quotas: only N of each vehicle type alive at any time
- Sequential zone attack: all groups attack the first uncaptured zone, then advance
- Multiple route support: groups take different paths via waypoint zones
- Tactical formations: groups deploy into line abreast (Rank) when approaching zones
- Enemy C2 destruction: destroying named static objects cuts off RED reinforcements
- ZONE_CAPTURE_COALITION: automatic capture detection with FSM events (Foothold-inspired)
- DCS Markup API zone coloring: zones change color on capture (Foothold-style)
- Persistence: save/load zone state across server restarts
- Player Credits: earn credits for kills, zone captures (Foothold-inspired economy)

Mission Editor Setup (recommended):
1) TRIGGER: MISSION START
   ACTION: DO SCRIPT FILE -> Moose.lua (load the MOOSE core library)

  2) TRIGGER: TIME MORE (1)
    ACTION: DO SCRIPT FILE -> scripts/moose_zone_init.lua (this file)

Notes:
- This script self-defers until MOOSE classes and Mission Editor zones are present.
- Ensure your Mission Editor trigger zones are named exactly: Alpha, Bravo, Charlie, Delta, Echo.
- For multiple routes, create waypoint trigger zones (e.g. wpBN1, wpBN2, wpBS1, wpBS2).
- Compatible with CTLD and MIST; no hard dependency.

Diagnostics:
- All on-screen messages are prefixed with [MZ-INIT] and also written to dcs.log via env.info
]]

-- =====================
-- RE-ENTRY GUARD (must be first executable line)
-- =====================
if _G.MZ_INIT_LOADED then return end
_G.MZ_INIT_LOADED = true

-- =====================
-- CONFIGURATION
-- =====================
local CONFIG = {
  zoneNames        = { "Alpha", "Bravo", "Charlie", "Delta", "Echo" },
  coalitionFilter  = "blue",
  smokeZones       = false,
  mooseSmokeZones  = false,
  drawZones        = true,
  drawLineColor    = {1, 0, 0},
  drawFillColor    = {1, 0, 0},
  drawFillAlpha    = 0.2,
  drawLineAlpha    = 0.5,
  drawLineWidth    = 2,
  smokeColor       = "blue",
  requireAllZones  = true,
  readyTimeout     = 60,
  pollInterval     = 1,
  detectStartDelay = 5,
  detectInterval   = 30,

  -- Spawn/Capture Manager
  enableSpawnManager = true,
  spawnZones = {
    north  = "groundSpawnN",
    middle = "groundSpawnM",
    south  = "groundSpawnS",
  },
  captureHoldTime = 10,
  spawnOnStart    = true,
  firstSpawnIntervalBlue = 30,
  firstSpawnIntervalRed  = 90,
  spawnInterval   = 300,
  spawnAlternating = true,
  useUSAForBlue    = true,
  spawnCooldown    = 15,

  -- UNIT QUOTAS (max alive at any time per side)
  blueQuota = {
    MBT  = 8,   -- M-1 Abrams
    IFV  = 4,   -- M-2 Bradley
    APC  = 4,   -- M-113 + M1126 Stryker ICV combined
  },
  redQuota = {
    MBT  = 8,   -- T-72B
    IFV  = 4,   -- BMP-2
    APC  = 4,   -- BTR-80
  },

  -- SEQUENTIAL ZONE ATTACK
  -- Groups attack the first uncaptured zone; when captured they advance to the next
  blueAdvanceRoute = { "Alpha", "Bravo", "Charlie", "Delta", "Echo" },
  redAdvanceRoute  = { "Echo", "Delta", "Charlie", "Bravo", "Alpha" },

  -- HUB ADVANCEMENT: when a zone is captured, advance the spawn hub.
  -- Maps zone name -> { side = "blue"|"red", hub = "hubKey" }
  -- BLUE hub keys correspond to CONFIG.spawnZones keys.
  -- RED hub keys correspond to CONFIG.redSpawnHubs keys.
  blueHubAdvance = {
    Charlie = "middle",   -- capturing Charlie moves BLUE hub to "middle"
    Delta   = "south",    -- capturing Delta moves BLUE hub to "south"
  },
  redHubAdvance = {
    Charlie = "middle",   -- RED capturing Charlie moves RED hub to "middle"
    Delta   = "middle",   -- RED capturing Delta moves RED hub to "middle"
  },

  -- RED spawn hub zone names (analogous to CONFIG.spawnZones for BLUE)
  redSpawnHubs = {
    start  = "redSpawnE",
    middle = "redSpawnM",
  },

  -- MULTIPLE ROUTES (waypoint zones)
  -- Each sub-table is a list of intermediate waypoint zone names.
  -- Groups cycle through these routes so they take different paths.
  -- Create these trigger zones in the Mission Editor.
  -- Set to nil or {} to disable (all groups go direct to target).
  blueRoutes = {
    { "wpBN1", "wpBN2" },   -- Route A: e.g. northern approach
    { "wpBS1", "wpBS2" },   -- Route B: e.g. southern approach
  },
  redRoutes = {
    { "wpRN1", "wpRN2" },   -- Route A
    { "wpRS1", "wpRS2" },   -- Route B
  },

  -- TACTICAL FORMATIONS
  -- When approaching target zones, groups switch from free off-road movement
  -- to a tactical formation for a more realistic assault posture.
  -- Valid formations: "Rank" (line abreast), "Vee", "EchelonL", "EchelonR",
  --                   "Diamond", "Cone", "Off Road" (no formation / free)
  tacticalFormation    = "Rank",    -- Formation to adopt near target zones
  tacticalApproachDist = 800,       -- Distance (meters) from zone center to deploy into formation
  tacticalApproachSpeed = 6,        -- Speed (m/s) when in tactical formation (~22 km/h)
  transitSpeed         = 10,        -- Speed (m/s) during transit waypoints (~36 km/h)

  -- ENEMY C2 (Command & Control) DESTRUCTION
  -- When ALL listed static objects are destroyed, RED reinforcements cease spawning.
  -- Set to nil or {} to disable this feature.
  redC2StaticNames = { "enemyc2-1", "enemyc2-2" },
  redC2CheckInterval = 15,          -- How often (seconds) to check C2 status

  -- =====================
  -- MOOSE Ops.CTLD INTEGRATION
  -- =====================
  -- Set to true to enable MOOSE CTLD (helicopter troop/cargo transport).
  -- Requires: MOOSE with Ops.CTLD module loaded, late-activated template groups
  -- in the ME, and CTLD zones (LOAD/DROP/MOVE) as trigger zones.
  enableCTLD = true,

  -- Transport GROUP name prefixes: any group whose name starts with one of
  -- these strings will get the CTLD F10 menu.  MOOSE prefix matching is on
  -- the GROUP name (not the unit/pilot name) and is CASE-SENSITIVE.
  -- Example: GROUP "JOLLY1" with unit "helicargo1" → prefix must match "JOLLY".
  ctldHeloPrefixes = {
    "JOLLY",      -- UH-60 transport
    "PEDRO",      -- UH-60 CSAR/transport
    "FORD",       -- CH-47 heavy lift
    "FATCOW",     -- CH-47 heavy lift (alternate callsign)
    "C-130",      -- C-130 fixed-wing transport
    "C130",       -- alternate C-130 naming
    "Hercules",   -- Hercules mod
    "helicargo",  -- fallback / legacy naming
    "Helicargo",  -- fallback / legacy naming
    "CTLD",       -- generic CTLD prefix
  },

  -- CTLD alias (shows in logs)
  ctldAlias = "Blue CTLD",

  -- CTLD LOAD zones: trigger zones where pilots can pick up troops/crates.
  -- Create round trigger zones in the ME with these names.
  ctldLoadZones = { "CTLDLoad_North", "CTLDLoad_South" },

  -- CTLD DROP zones: trigger zones where pilots can drop crates to be built.
  -- Troops can be unloaded anywhere, but crates need a DROP zone.
  ctldDropZones = { "CTLDDrop_Alpha", "CTLDDrop_Bravo" },

  -- CTLD MOVE zones: dropped troops/vehicles will move toward the nearest MOVE zone.
  -- We reuse the capture zones so deployed units advance toward objectives.
  ctldMoveZones = { "Alpha", "Bravo", "Charlie", "Delta", "Echo" },

  -- Late-activated template group names in the ME for CTLD cargo.
  -- Create these as late-activated groups in the Mission Editor:
  --   "CTLD_INF_RIFLE"  = 8-man rifle squad (Soldier M4 x6, Soldier M249 x1, Soldier RPG x1)
  --   "CTLD_INF_AT"     = 4-man AT team (Soldier RPG x4)
  --   "CTLD_INF_AA"     = 2-man AA team (e.g. Stinger MANPADS)
  --   "CTLD_VEH_HUMVEE" = HMMWV TOW
  --   "CTLD_VEH_STRYKER"= M1126 Stryker ICV
  --   "CTLD_VEH_BRADLEY"= M-2 Bradley
  --   "CTLD_ENGINEERS"   = 2-man engineer team (for building crates)
   ctldTroops = {
     { name = "Rifle Squad",   templates = {"CTLD_INF_RIFLE"},   size = 8 },
     { name = "AT Team",       templates = {"CTLD_INF_AT"},     size = 4 },
     { name = "AA Team",       templates = {"CTLD_INF_AA"},     size = 2 },
   },
  ctldVehicleCrates = {
    { name = "HMMWV TOW",     templates = {"CTLD_VEH_HUMVEE"},  crates = 2 },
    { name = "Stryker ICV",   templates = {"CTLD_VEH_STRYKER"}, crates = 2 },
    { name = "Bradley IFV",   templates = {"CTLD_VEH_BRADLEY"}, crates = 3 },
  },
   ctldEngineers = {
     name = "Engineers",
     templates = {"CTLD_ENGINEERS"},
     size = 2,
   },
   ctldFarpCrates = {
     { name = "FARP Crate",    templates = {"CTLD_FARP_CRATE"}, crates = 1 },
   },

   -- CTLD options (SMOKECOLOR/FLARECOLOR resolved at runtime, not at parse time)
   ctldSmokeColor       = nil,    -- resolved in startCTLD(); nil = SMOKECOLOR.Blue
   ctldFlareColor       = nil,    -- resolved in startCTLD(); nil = FLARECOLOR.White
   ctldMoveToZone       = true,   -- Troops/vehicles move to nearest MOVE zone after drop
   ctldMoveDistance      = 5000,   -- Max distance to search for MOVE zone (meters)
   ctldEngineerSearch    = 2000,   -- Engineer search radius for crates (meters)
   ctldRepairTime        = 300,    -- Seconds to repair a unit
   ctldBuildTime         = 300,    -- Seconds to build from crates (0 = instant)
   ctldUseSubcats        = true,   -- Enable subcategory menus for better organization
   ctldHoverPickup       = true,   -- Allow pickup when hovering (Foothold feature)
   ctldEnableSmokeDrop   = true,   -- Enable smoke marker drops
   ctldEnableSmokeRelease= true,   -- Enable smoke release on pickup

  -- =====================
  -- MODDED HELICOPTER SUPPORT
  -- =====================
  -- Modded UH-60 and CH-47 variants may use different DCS type names than the
  -- stock entries in MOOSE's CTLD.UnitTypeCapabilities table.  List every modded
  -- type string here so we can register them with SetUnitCapabilities().
  -- The DCS type name is what you see in the ME unit properties (e.g. "UH-60L",
  -- "CH-47Fbl1").  If your mod uses a different string, add/change it below.
  --
  -- IMPORTANT: MOOSE CTLD also filters pilot groups with
  --   FilterCategories("helicopter").  Some mods register their aircraft under
  --   a different DCS category.  If the F10 CTLD menu never appears, set
  --   ctldUseOwnPilotSet = true below -- this bypasses the category filter and
  --   uses only prefix + coalition matching.
  ctldUseOwnPilotSet = true,   -- true = bypass FilterCategories("helicopter")
                                -- (recommended for modded helos)

  -- Extra unit-type capabilities for modded helicopters.
  -- Each entry: { type = "DCS type name", crates = bool, troops = bool,
  --               cratelimit = N, trooplimit = N, length = N, cargoweightlimit = N }
  -- These are merged into MOOSE's UnitTypeCapabilities table at CTLD start.
  ctldExtraUnitCaps = {
    -- Modded UH-60 variants (add/remove as needed for your mod pack)
    { type = "UH-60L",       crates = true,  troops = true,  cratelimit = 2, trooplimit = 20, length = 16, cargoweightlimit = 3500 },
    { type = "UH-60L_DAP",   crates = false, troops = true,  cratelimit = 0, trooplimit = 2,  length = 16, cargoweightlimit = 500  },
    { type = "MH-60R",       crates = true,  troops = true,  cratelimit = 2, trooplimit = 20, length = 16, cargoweightlimit = 3500 },
    { type = "SH-60B",       crates = true,  troops = true,  cratelimit = 2, trooplimit = 20, length = 16, cargoweightlimit = 3500 },
    -- Modded CH-47 variants
    { type = "CH-47Fbl1",    crates = true,  troops = true,  cratelimit = 4, trooplimit = 31, length = 20, cargoweightlimit = 10800 },
    { type = "CH-47F",       crates = true,  troops = true,  cratelimit = 4, trooplimit = 31, length = 20, cargoweightlimit = 10800 },
    -- C-130 variants (fixed-wing transport)
    { type = "Hercules",     crates = true,  troops = true,  cratelimit = 7, trooplimit = 64, length = 25, cargoweightlimit = 19000 },
    { type = "C-130J-30",    crates = true,  troops = true,  cratelimit = 7, trooplimit = 64, length = 35, cargoweightlimit = 21500 },
    -- Add more modded types here as needed:
    -- { type = "YourModType", crates = true, troops = true, cratelimit = 2, trooplimit = 12, length = 18, cargoweightlimit = 4000 },
  },

  -- =====================
  -- CTLD LOGGING CONTROL (ciribob CTLD only)
  -- =====================
  -- When using ciribob standalone CTLD, the ctld.p() function can crash on
  -- deeply nested or circular-reference objects (MOOSE/DCS unit tables).
  -- These options let the ground ops script monkey-patch CTLD at runtime
  -- so you can use an UNMODIFIED ciribob CTLD.lua.
  ctldPatchLogging     = true,   -- Patch ctld.p() to handle circular refs safely
  ctldMaxLogDepth      = 10,     -- Max table nesting depth for ctld.p() serialization
  ctldSuppressInfoLogs = false,  -- Suppress ctld.logInfo() messages (errors/warnings kept)

  -- =====================
  -- ZONE_CAPTURE_COALITION SETTINGS
  -- =====================
  -- Use MOOSE ZONE_CAPTURE_COALITION for capture detection (replaces manual polling).
  -- This provides FSM events: OnAfterCaptured, OnAfterAttacked, OnAfterGuarded, OnAfterEmpty.
  useCaptureCoalition  = true,
  captureCheckInterval = 15,     -- How often (seconds) to check zone ownership
  -- Initial zone ownership: 1 = RED, 2 = BLUE, 0 = NEUTRAL
  initialZoneSides = {
    Alpha   = 1,  -- RED starts with Alpha
    Bravo   = 1,
    Charlie = 1,  -- Neutral
    Delta   = 1,
    Echo    = 1,
  },

  -- =====================
  -- DCS MARKUP ZONE DRAWING (Foothold-style)
  -- =====================
  -- Uses DCS trigger.action markup API instead of MOOSE DrawZone for more reliable
  -- zone coloring that updates on capture. Each zone gets a unique markup ID.
  useMarkupDraw     = true,
  markupIdBase      = 80000,     -- Base markup ID (zone circle = base + index, label = base + 100 + index)
  zoneColors = {
    red     = { line = {1, 0, 0, 0.5},    fill = {1, 0, 0, 0.2},    text = {0.7, 0, 0, 0.8} },
    blue    = { line = {0, 0, 1, 0.5},    fill = {0, 0, 1, 0.2},    text = {0, 0, 0.7, 0.8} },
    neutral = { line = {0.7, 0.7, 0.7, 0.5}, fill = {0.7, 0.7, 0.7, 0.2}, text = {0.3, 0.3, 0.3, 1} },
  },

   -- =====================
   -- PERSISTENCE (save/load zone state across restarts)
   -- =====================
   enablePersistence  = false,     -- Set true to enable (requires lfs + io in DCS env)
   saveInterval       = 60,        -- Auto-save every N seconds
   saveFile           = "mz_state.lua",  -- Saved to lfs.writedir() .. "Missions/Saves/"

   -- =====================
   -- SHOP PRICES (for credit system)
   -- =====================
   shopPrices = {
     reinforcementWave = 500,    -- Additional AI spawn wave
     smokeMarker       = 10,    -- Smoke marker for zone identification
     ctldRifleSquad    = 0,    -- 8-man rifle squad
     ctldATTeam        = 0,    -- 4-man AT team
     ctldAATeam        = 0,    -- 2-man AA team
     ctldHumvee        = 250,    -- HMMWV TOW
     ctldStryker       = 300,    -- Stryker ICV
     ctldBradley       = 350,    -- Bradley IFV
     ctldEngineers     = 10,    -- 2-man engineer team
     ctldFARPCrate     = 400,    -- FARP crate
   },

   -- =====================
   -- PLAYER CREDITS (Foothold-inspired economy)
   -- =====================
   enableCredits      = false,     -- Set true to enable credit system
   rewards = {
     infantry   = 0,    -- Increased from 5 for better balance
     ground     = 20,    -- Increased from 10 for better balance
     sam        = 50,    -- Increased from 30 for better balance
     airplane   = 75,    -- Increased from 50 for better balance
     helicopter = 75,    -- Increased from 50 for better balance
     ship       = 300,   -- Increased from 200 for better balance
     capture    = 300,   -- Increased from 200 for better balance
   },
   startingCredits    = 0,
}

-- Test-mode overrides
CONFIG.testMode = false
if CONFIG.testMode then
  CONFIG.detectStartDelay       = 1
  CONFIG.detectInterval         = 5
  CONFIG.firstSpawnIntervalBlue = 30
  CONFIG.firstSpawnIntervalRed  = 45
  CONFIG.spawnInterval          = 60
  CONFIG.captureHoldTime        = 5
  CONFIG.spawnCooldown          = 20
  CONFIG.drawZones              = true
  CONFIG.smokeZones             = false
  CONFIG.mooseSmokeZones        = false
end

-- =====================
-- INTERNALS
-- =====================
local PREFIX = "[MZ-INIT] "

--- Output a diagnostic message to both the in-game screen and dcs.log.
-- @param msg  string|any  message to display (auto-coerced via tostring)
-- @param dur  number      on-screen duration in seconds (default 10)
local function out(msg, dur)
  dur = dur or 10
  local text = PREFIX .. tostring(msg)
  if trigger and trigger.action and trigger.action.outText then
    trigger.action.outText(text, dur)
  end
  if env and env.info then
    env.info(text)
  end
end

--- Output a diagnostic message to dcs.log ONLY (no on-screen text).
-- Use for verbose/detail messages that would clutter the screen.
-- @param msg  string|any  message to log
local function logOnly(msg)
  local text = PREFIX .. tostring(msg)
  if env and env.info then
    env.info(text)
  end
end

--- Safely retrieve a global variable without triggering __index metamethods.
-- @param name  string  global variable name
-- @return any|nil  the value, or nil if not set
local function getGlobal(name)
  return rawget(_G, name)
end

--- Get the current mission time, with a safe fallback.
-- @return number  mission elapsed time in seconds
local function now()
  return (timer and timer.getTime and timer.getTime()) or 0
end

local SMOKE_COLOR_MAP = { green = 0, red = 1, white = 2, orange = 3, blue = 4 }

local function resolveSmokeColor(value)
  local t = type(value)
  if t == "string" then
    local k = string.lower(value)
    return SMOKE_COLOR_MAP[k] or 4
  elseif t == "number" then
    if value >= 0 and value <= 4 then return value end
    return 4
  end
  return 4
end

local function listToString(list)
  local parts = {}
  for i = 1, #list do parts[i] = tostring(list[i]) end
  return table.concat(parts, ", ")
end

--- Map coalition side number to human-readable name.
-- @param side  number  0=NEUTRAL, 1=RED, 2=BLUE
-- @return string
local SIDE_NAMES = { [0] = "NEUTRAL", [1] = "RED", [2] = "BLUE" }
local function sideName(side)
  return SIDE_NAMES[side] or "UNKNOWN"
end

--- Check if a Mission Editor trigger zone exists.
-- @param name  string  trigger zone name
-- @return boolean
local function zoneExists(name)
  if trigger and trigger.misc and trigger.misc.getZone then
    local z = trigger.misc.getZone(name)
    return z and z.point and true or false
  end
  return false
end

local function validateConfig()
  local seen, invalid, uniq = {}, {}, {}
  if type(CONFIG.zoneNames) ~= "table" or #CONFIG.zoneNames == 0 then
    out("CONFIG.zoneNames must be a non-empty list", 10)
    return false
  end
  for _, n in ipairs(CONFIG.zoneNames) do
    if type(n) ~= "string" or n == "" then table.insert(invalid, tostring(n)) end
    if seen[n] then table.insert(uniq, n) else seen[n] = true end
  end
  if #invalid > 0 then out("Invalid zone names: " .. listToString(invalid), 10) end
  if #uniq > 0 then out("Duplicate zone names: " .. listToString(uniq), 10) end
  local c = tostring(CONFIG.coalitionFilter or "blue"):lower()
  if c ~= "blue" and c ~= "red" then
    out("CONFIG.coalitionFilter must be 'blue' or 'red' (got '" .. tostring(CONFIG.coalitionFilter) .. "'), defaulting to 'blue'", 10)
    CONFIG.coalitionFilter = "blue"
  else
    CONFIG.coalitionFilter = c
  end
  CONFIG._smokeColorResolved = resolveSmokeColor(CONFIG.smokeColor)
  return #invalid == 0 and #uniq == 0
end

local function mooseVisible()
  local hasZone      = getGlobal("ZONE") ~= nil
  local hasScheduler = getGlobal("SCHEDULER") ~= nil
  local hasSet       = getGlobal("SET_UNIT") ~= nil or getGlobal("SET_GROUP") ~= nil
  return hasZone and hasScheduler and hasSet
end

local function getMissingZones(names)
  local missing = {}
  if not (trigger and trigger.misc and trigger.misc.getZone) then
    for _, n in ipairs(names) do table.insert(missing, n) end
    return missing
  end
  for _, n in ipairs(names) do
    local z = trigger.misc.getZone(n)
    if not (z and z.point) then table.insert(missing, n) end
  end
  return missing
end

local function allZonesPresent(names)
  return #getMissingZones(names) == 0
end

local function nativeSmoke(name)
  if not (trigger and trigger.misc and trigger.misc.getZone) then return end
  local z = trigger.misc.getZone(name)
  if z and z.point and trigger and trigger.action and trigger.action.smoke then
    local color = CONFIG._smokeColorResolved or 4
    pcall(function() trigger.action.smoke(z.point, color) end)
  end
end

local function safeDrawZone(zo)
  if CONFIG.drawZones and type(zo.DrawZone) == "function" then
    pcall(function()
      zo:DrawZone(
        -1,
        CONFIG.drawLineColor or {1, 0, 0},
        CONFIG.drawLineAlpha or 0.5,
        CONFIG.drawFillColor or {1, 0, 0},
        CONFIG.drawFillAlpha or 0.2,
        CONFIG.drawLineWidth or 2
      )
    end)
  end
end

--- Redraw a zone with a specific coalition color (called on capture).
-- Removes the old drawing first, then redraws with the new color.
-- @param zo  MOOSE ZONE object
-- @param lineColor  {r, g, b} table for the outline
-- @param fillColor  {r, g, b} table for the fill
local function redrawZoneColor(zo, lineColor, fillColor)
  if not CONFIG.drawZones then return end
  if not zo or type(zo.DrawZone) ~= "function" then return end
  -- Remove the previous drawing if the MOOSE method exists
  if type(zo.UndrawZone) == "function" then
    pcall(function() zo:UndrawZone() end)
  end
  pcall(function()
    zo:DrawZone(
      -1,
      lineColor  or {1, 1, 1},
      CONFIG.drawLineAlpha or 0.5,
      fillColor  or {1, 1, 1},
      CONFIG.drawFillAlpha or 0.2,
      CONFIG.drawLineWidth or 2
    )
  end)
end

local function safeMooseSmoke(zo)
  if CONFIG.mooseSmokeZones and type(zo.Smoke) == "function" then
    pcall(function()
      local BLUE = (getGlobal("SMOKECOLOR") and SMOKECOLOR.Blue) or resolveSmokeColor(CONFIG.smokeColor)
      zo:Smoke(BLUE)
    end)
  end
end

local function msgAll(text, dur)
  if getGlobal("MESSAGE") then
    pcall(function() MESSAGE:New(text, dur or 10):ToAll() end)
  else
    out(text, dur)
  end
end

-- =====================
-- DCS MARKUP ZONE DRAWING (Foothold-style)
-- =====================
-- Uses DCS trigger.action markup API for zone circles and labels.
-- Each zone gets a unique markup ID so colors can be updated on capture.

--- Map zone index (1-based) to markup IDs.
local function zoneMarkupId(zoneIdx)
  return (CONFIG.markupIdBase or 80000) + zoneIdx
end
local function zoneLabelId(zoneIdx)
  return (CONFIG.markupIdBase or 80000) + 100 + zoneIdx
end

--- Get the color set for a coalition side (1=RED, 2=BLUE, 0=NEUTRAL).
local function getZoneColorSet(side)
  local colors = CONFIG.zoneColors or {}
  if side == 2 then return colors.blue or { line={0,0,1,0.5}, fill={0,0,1,0.2}, text={0,0,0.7,0.8} }
  elseif side == 1 then return colors.red or { line={1,0,0,0.5}, fill={1,0,0,0.2}, text={0.7,0,0,0.8} }
  else return colors.neutral or { line={0.7,0.7,0.7,0.5}, fill={0.7,0.7,0.7,0.2}, text={0.3,0.3,0.3,1} }
  end
end

--- Draw a zone circle + label using DCS markup API (Foothold-style).
-- @param zoneName  string - ME trigger zone name
-- @param zoneIdx   number - 1-based index for markup ID
-- @param side      number - coalition side (0/1/2)
local function drawZoneMarkup(zoneName, zoneIdx, side)
  if not CONFIG.useMarkupDraw then return end
  if not (trigger and trigger.action and trigger.action.circleToAll) then return end
  local z = trigger.misc.getZone(zoneName)
  if not z or not z.point then return end

  local cs = getZoneColorSet(side)
  local circleId = zoneMarkupId(zoneIdx)
  local labelId  = zoneLabelId(zoneIdx)
  local radius   = z.radius or 3000

  -- Remove existing markup first (in case of redraw)
  pcall(function() trigger.action.removeMark(circleId) end)
  pcall(function() trigger.action.removeMark(labelId) end)

  pcall(function()
    trigger.action.circleToAll(-1, circleId, z.point, radius, cs.line, cs.fill, 2)
  end)

  -- Label above the zone
  local labelPoint = { x = z.point.x, y = z.point.y, z = z.point.z + radius + 200 }
  local labelText = zoneName .. " [" .. sideName(side) .. "]"
  local bgColor = {0.1, 0.1, 0.1, 0.6}
  pcall(function()
    trigger.action.textToAll(-1, labelId, labelPoint, cs.text, bgColor, 16, true, labelText)
  end)
end

--- Update zone markup colors on capture (Foothold-style setMarkupColor).
-- Uses setMarkupColor/setMarkupColorFill if available (DCS 2.8+), otherwise
-- falls back to remove-and-redraw for older DCS versions.
-- @param zoneIdx  number - 1-based index
-- @param newSide  number - new coalition side (0/1/2)
-- @param zoneName string - zone name for label update
local function updateZoneMarkup(zoneIdx, newSide, zoneName)
  if not CONFIG.useMarkupDraw then return end
  if not (trigger and trigger.action) then return end

  local cs = getZoneColorSet(newSide)
  local circleId = zoneMarkupId(zoneIdx)
  local labelId  = zoneLabelId(zoneIdx)

  -- Try the in-place color update API first (DCS 2.8+)
  local hasSetColor = type(trigger.action.setMarkupColor) == "function"
  local hasSetFill  = type(trigger.action.setMarkupColorFill) == "function"
  local hasSetText  = type(trigger.action.setMarkupText) == "function"

  if hasSetColor and hasSetFill and hasSetText then
    pcall(function()
      trigger.action.setMarkupColorFill(circleId, cs.fill)
      trigger.action.setMarkupColor(circleId, cs.line)
    end)

    local labelText = zoneName .. " [" .. sideName(newSide) .. "]"
    pcall(function()
      trigger.action.setMarkupColor(labelId, cs.text)
      trigger.action.setMarkupText(labelId, labelText)
    end)
  else
    -- Fallback: remove old markup and redraw with new colors
    logOnly(string.format("updateZoneMarkup: setMarkupColor not available, using remove+redraw for %s", zoneName))
    drawZoneMarkup(zoneName, zoneIdx, newSide)
  end
end

-- =====================
-- PERSISTENCE MODULE
-- =====================
-- Saves/loads zone capture state to disk (requires lfs + io in DCS env).
-- Inspired by Foothold's Utils.saveTable/loadTable pattern.

local MZ_Persistence = {}

function MZ_Persistence.getSavePath()
  if not (lfs and lfs.writedir) then return nil end
  local dir = lfs.writedir() .. "Missions\\Saves\\"
  pcall(function() lfs.mkdir(dir) end)
  return dir .. (CONFIG.saveFile or "mz_state.lua")
end

function MZ_Persistence.serializeValue(value, indent)
  indent = indent or 0
  local t = type(value)
  if t == "string" then
    return string.format("%q", value)
  elseif t == "number" or t == "boolean" then
    return tostring(value)
  elseif t == "table" then
    local pad = string.rep("  ", indent + 1)
    local pad2 = string.rep("  ", indent)
    local parts = { "{\n" }
    for k, v in pairs(value) do
      local keyStr
      if type(k) == "string" then
        keyStr = "[" .. string.format("%q", k) .. "] = "
      else
        keyStr = "[" .. tostring(k) .. "] = "
      end
      table.insert(parts, pad .. keyStr .. MZ_Persistence.serializeValue(v, indent + 1) .. ",\n")
    end
    table.insert(parts, pad2 .. "}")
    return table.concat(parts)
  end
  return "nil"
end

function MZ_Persistence.save(state)
  if not CONFIG.enablePersistence then return false end
  local path = MZ_Persistence.getSavePath()
  if not path then
    out("Persistence: cannot save (lfs not available)", 5)
    return false
  end
  -- Use explicit file handle management to guarantee close on error
  local f, openErr = io.open(path, "w")
  if not f then
    out("Persistence save failed: cannot open " .. path .. " (" .. tostring(openErr) .. ")", 10)
    return false
  end
  local ok, writeErr = pcall(function()
    f:write("-- MZ State (auto-generated, do not edit)\n")
    f:write("MZ_SavedState = " .. MZ_Persistence.serializeValue(state) .. "\n")
  end)
  f:close()  -- always close, even if write failed
  if ok then
    if CONFIG.testMode then out("State saved to " .. path, 3) end
  else
    out("Persistence save failed: " .. tostring(writeErr), 10)
  end
  return ok
end

function MZ_Persistence.load()
  if not CONFIG.enablePersistence then return nil end
  local path = MZ_Persistence.getSavePath()
  if not path then return nil end
  local ok, err = pcall(function()
    local chunk, loadErr = loadfile(path)
    if chunk then
      -- Sandbox: execute in a restricted environment that only exposes
      -- safe primitives.  The chunk can only set MZ_SavedState in the
      -- sandbox table, preventing arbitrary code from touching _G.
      local sandbox = { tostring = tostring, tonumber = tonumber, type = type,
                        pairs = pairs, ipairs = ipairs, next = next,
                        string = string, table = table, math = math }
      if setfenv then
        setfenv(chunk, sandbox)  -- Lua 5.1 / LuaJIT (DCS uses LuaJIT)
      end
      chunk()
      -- Pull MZ_SavedState from the sandbox (or _G as fallback for Lua 5.2+)
      if sandbox.MZ_SavedState then
        rawset(_G, "MZ_SavedState", sandbox.MZ_SavedState)
      end
    elseif loadErr then
      out("Persistence: failed to parse " .. path .. ": " .. tostring(loadErr), 8)
    end
  end)
  if not ok then
    out("Persistence load error: " .. tostring(err), 8)
    return nil
  end
  if rawget(_G, "MZ_SavedState") then
    local saved = MZ_SavedState
    _G.MZ_SavedState = nil  -- clean up global after reading
    out("Persistence: loaded state from " .. path, 8)
    return saved
  end
  return nil
end

-- =====================
-- PLAYER CREDIT SYSTEM
-- =====================
-- Lightweight credit/contribution system inspired by Foothold's BattleCommander.

local MZ_Credits = {}
MZ_Credits.balances = {}  -- { [playerName] = number }

function MZ_Credits.init()
  if not CONFIG.enableCredits then return end
  MZ_Credits.balances = {}
  out("Credit system initialized", 5)
end

function MZ_Credits.add(playerName, amount)
  if not CONFIG.enableCredits or not playerName then return end
  MZ_Credits.balances[playerName] = (MZ_Credits.balances[playerName] or CONFIG.startingCredits or 0) + amount
end

function MZ_Credits.get(playerName)
  if not CONFIG.enableCredits or not playerName then return 0 end
  return MZ_Credits.balances[playerName] or CONFIG.startingCredits or 0
end

function MZ_Credits.spend(playerName, amount)
  if not CONFIG.enableCredits or not playerName then return false end
  local bal = MZ_Credits.get(playerName)
  if bal >= amount then
    MZ_Credits.balances[playerName] = bal - amount
    return true
  end
  return false
end

function MZ_Credits.getBalances()
  return MZ_Credits.balances
end

function MZ_Credits.setBalances(tbl)
  if type(tbl) == "table" then MZ_Credits.balances = tbl end
end

--- Classify a DCS unit for reward purposes.
local function classifyTarget(unit)
  if not unit then return nil end
  local ok, desc = pcall(function() return unit:getDesc() end)
  if not ok or not desc then return "ground" end
  local cat = desc.category
  -- DCS Unit.Category: 0=AIRPLANE, 1=HELICOPTER, 2=GROUND_UNIT, 3=SHIP, 4=BUILDING
  if cat == 0 then return "airplane"
  elseif cat == 1 then return "helicopter"
  elseif cat == 3 then return "ship"
  elseif cat == 4 then return "ground"  -- structures
  elseif cat == 2 then
    -- Distinguish infantry vs SAM vs regular ground
    local typeName = desc.typeName or ""
    if typeName:find("SA%-") or typeName:find("S%-300") or typeName:find("Patriot")
       or typeName:find("Hawk") or typeName:find("Tor") or typeName:find("Buk")
       or typeName:find("Kub") or typeName:find("Roland") then
      return "sam"
    elseif typeName:find("Soldier") or typeName:find("Infantry") or typeName:find("Paratrooper") then
      return "infantry"
    else
      return "ground"
    end
  end
  return "ground"
end

--- Start the kill reward event handler.
function MZ_Credits.startKillRewards()
  if not CONFIG.enableCredits then return end
  local rewards = CONFIG.rewards or {}
  local handler = {}
  function handler:onEvent(event)
    if event.id ~= world.event.S_EVENT_KILL then return end
    local initiator = event.initiator
    if not initiator then return end
    local ok, pname = pcall(function() return initiator:getPlayerName() end)
    if not ok or not pname then return end
    local target = event.target
    local category = classifyTarget(target)
    local reward = rewards[category] or rewards.ground or 10
    MZ_Credits.add(pname, reward)
    if CONFIG.testMode then
      out(string.format("[Credits] %s +%d (%s kill)", pname, reward, category or "?"), 5)
    end
  end
  world.addEventHandler(handler)
  out("Credit kill rewards active", 5)
end

-- Make modules globally accessible for other scripts
_G.MZ_Persistence = MZ_Persistence
_G.MZ_Credits = MZ_Credits

local function buildZones(names)
  local zones = {}
  for _, n in ipairs(names) do
    local ok, zoOrErr = pcall(function() return ZONE:New(n) end)
    if ok and zoOrErr then
      local zo = zoOrErr
      table.insert(zones, zo)
      safeMooseSmoke(zo)
      -- Only use MOOSE DrawZone if DCS markup drawing is NOT active (avoid duplicates)
      if not CONFIG.useMarkupDraw then
        safeDrawZone(zo)
      end
      msgAll("Zone " .. (zo.GetName and zo:GetName() or n) .. " initialized", 8)
    else
      out(string.format("MOOSE ZONE:New('%s') failed: %s", n, tostring(zoOrErr)), 10)
    end
  end
  return zones
end

local function startDetection(mooseZones)
  local coalitionName = CONFIG.coalitionFilter
  local SetFactory = getGlobal("SET_UNIT") or getGlobal("SET_GROUP")
  if not SetFactory then
    out("Detection disabled: MOOSE SET_UNIT/SET_GROUP not available", 10)
    return
  end

  local BlueSet
  pcall(function()
    BlueSet = SetFactory:New():FilterCoalitions(coalitionName):FilterStart()
  end)

  if not BlueSet then
    out("Detection disabled: unable to create MOOSE set for coalition '" .. tostring(coalitionName) .. "'", 10)
    return
  end

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
          out("Unit(s) detected in zone: " .. (zo.GetName and zo:GetName() or "<unknown>"), 5)
          if getGlobal("BASE") then pcall(function() BASE:E("Detected in zone: " .. (zo.GetName and zo:GetName() or "<unknown>")) end) end
        end
      end
    end, {}, CONFIG.detectStartDelay, CONFIG.detectInterval)
  end)
end

-- =====================
-- SPAWN/CAPTURE MANAGER
-- =====================
local function getZonePoint(name)
  if trigger and trigger.misc and trigger.misc.getZone then
    local z = trigger.misc.getZone(name)
    if z and z.point then return z.point end
  end
  if getGlobal("ZONE") then
    local ok, zo = pcall(function() return ZONE:New(name) end)
    if ok and zo and zo.GetCoordinate then
      local c = zo:GetCoordinate()
      return { x = c.x, y = 0, z = c.z }
    end
  end
  return nil
end

--- Build a single waypoint table for a DCS ground route.
-- @param x       number  world X coordinate
-- @param y       number  world Y (actually Z in DCS 3D) coordinate
-- @param action  string  DCS waypoint action: "Off Road", "Rank", "Vee", etc.
-- @param speed   number  speed in m/s
local function makeWaypoint(x, y, action, speed)
  return {
    x          = x,
    y          = y,
    alt        = 0,
    alt_type   = "BARO",
    type       = "Turning Point",
    action     = action or "Off Road",
    speed      = speed or (CONFIG.transitSpeed or 10),
    ETA        = 0,
    ETA_locked = false,
    task       = { id = "ComboTask", params = { tasks = {} } },
  }
end

--- Build route points for a list of zone names (all use the same action/speed).
local function buildRoutePoints(zoneNames, action, speed)
  local pts = {}
  for _, zn in ipairs(zoneNames or {}) do
    local p = getZonePoint(zn)
    if p then
      table.insert(pts, makeWaypoint(p.x, p.z or p.y or 0, action or "Off Road", speed or CONFIG.transitSpeed or 10))
    end
  end
  return pts
end

--- Compute an approach waypoint offset from a zone center.
-- Returns a waypoint placed `dist` meters "before" the zone center
-- (toward the previous waypoint or due south if no previous point).
-- Uses the tactical formation and approach speed from CONFIG.
local function buildApproachWaypoint(targetZoneName, prevX, prevY)
  local p = getZonePoint(targetZoneName)
  if not p then return nil end
  local tx = p.x
  local ty = p.z or p.y or 0
  local dist = CONFIG.tacticalApproachDist or 800
  local formation = CONFIG.tacticalFormation or "Rank"
  local spd = CONFIG.tacticalApproachSpeed or 6

  -- Direction from target back toward previous waypoint (or due south)
  local dx, dy
  if prevX and prevY then
    dx = prevX - tx
    dy = prevY - ty
  else
    dx = 0
    dy = -1  -- default: approach from south
  end
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then len = 1 end  -- avoid division by zero
  dx = dx / len
  dy = dy / len

  -- Place approach waypoint `dist` meters back along the approach vector
  local ax = tx + dx * dist
  local ay = ty + dy * dist

  if CONFIG.testMode then
    out(string.format("  Approach WP for %s: (%.0f,%.0f) -> formation=%s speed=%.0f dist=%.0f",
      targetZoneName, ax, ay, formation, spd, dist), 5)
  end

  return makeWaypoint(ax, ay, formation, spd)
end

--- Build a route: intermediate waypoints (off-road transit) + target zones
--- with tactical approach waypoints injected before each target zone.
local function buildRouteWithWaypoints(waypointZones, targetZones)
  local pts = {}
  local formation = CONFIG.tacticalFormation or "Rank"
  local approachSpeed = CONFIG.tacticalApproachSpeed or 6
  local transitSpeed = CONFIG.transitSpeed or 10

  -- 1) Transit waypoints: off-road, normal speed
  if waypointZones then
    for _, zn in ipairs(waypointZones) do
      local p = getZonePoint(zn)
      if p then
        table.insert(pts, makeWaypoint(p.x, p.z or p.y or 0, "Off Road", transitSpeed))
      end
    end
  end

  -- 2) Target zones: inject approach waypoint + target waypoint in tactical formation
  if targetZones then
    for _, zn in ipairs(targetZones) do
      -- Determine previous waypoint position for approach vector
      local prevX, prevY
      if #pts > 0 then
        prevX = pts[#pts].x
        prevY = pts[#pts].y
      end

      -- Inject approach waypoint (formation switch point ~800m out)
      local approachWP = buildApproachWaypoint(zn, prevX, prevY)
      if approachWP then
        table.insert(pts, approachWP)
      end

      -- Target zone waypoint itself (also in tactical formation)
      local p = getZonePoint(zn)
      if p then
        table.insert(pts, makeWaypoint(p.x, p.z or p.y or 0, formation, approachSpeed))
      end
    end
  end

  if CONFIG.testMode then
    out(string.format("Route built: %d total waypoints (transit=%d, targets=%d with approach WPs)",
      #pts,
      waypointZones and #waypointZones or 0,
      targetZones and #targetZones or 0), 5)
  end

  return pts
end

local function addGroupSafe(countryId, groupData)
  local ok, res = pcall(function()
    return coalition.addGroup(countryId, Group.Category.GROUND, groupData)
  end)
  if not ok or not res then
    out("Spawn failed for group '" .. tostring(groupData and groupData.name or "<nil>") .. "' -- verify unit type names exist in your DCS build", 12)
  end
  return ok and res or nil
end

local function mkUnit(uName, typeName, x, y, heading)
  return {
    name = uName,
    type = typeName,
    x = x, y = y,
    heading = heading or 0,
    playerCanDrive = false,
    skill = "Average",
  }
end

local function mkGroup(gName, categoryStr, units, routePoints)
  return {
    visible = false,
    lateActivation = false,
    tasks = {},
    task = "Ground Nothing",
    uncontrollable = false,
    route = { points = (routePoints and #routePoints > 0) and routePoints or {} },
    units = units,
    name = gName,
    start_time = 0,
    x = units[1].x,
    y = units[1].y,
    category = categoryStr or "vehicle",
  }
end

local function radialOffsets(cx, cy, count, radius)
  local pts = {}
  radius = radius or 10
  for i = 1, count do
    local ang = (i - 1) * (2 * math.pi / count)
    pts[i] = { x = cx + radius * math.cos(ang), y = cy + radius * math.sin(ang), hdg = ang }
  end
  return pts
end

--- Spawn a vehicle group with N units of a given type, respecting quota limits.
-- Shared helper used by both BLUE and RED spawn packages to avoid code duplication.
-- @param baseName   string  prefix for group/unit names
-- @param typeName   string  DCS unit type name (e.g. "M-1 Abrams")
-- @param requested  number  desired number of units
-- @param cx         number  center X coordinate for radial placement
-- @param cy         number  center Y coordinate for radial placement
-- @param radius     number  radial spread distance
-- @param startIdx   number  starting offset in the radial ring
-- @param quotaCat   string|nil  quota category key ("MBT", "IFV", "APC") or nil to skip quota
-- @param room       table   mutable quota room table { MBT=n, IFV=n, APC=n }
-- @param countryId  number  DCS country.id for coalition.addGroup
-- @param routePoints table  DCS route waypoints
local function spawnVehicleGroup(baseName, typeName, requested, cx, cy, radius, startIdx, quotaCat, room, countryId, routePoints)
  local t = math.floor(now())
  local n = requested
  if quotaCat and room and room[quotaCat] then
    n = math.min(requested, room[quotaCat])
    if n > 0 then
      room[quotaCat] = room[quotaCat] - n  -- decrement for subsequent calls
    end
  end
  if n <= 0 then
    if CONFIG.testMode then out(baseName .. " skipped (quota full)", 5) end
    return nil
  end
  local pts = radialOffsets(cx, cy, math.max(n, 4), radius)
  local units = {}
  for i = 1, n do
    local p = pts[((startIdx or 1) + i - 2) % #pts + 1]
    table.insert(units, mkUnit(string.format("%sU_%d_%02d", baseName, t, i), typeName, p.x, p.y, p.hdg))
  end
  local grp = mkGroup(string.format("%s_%d", baseName, t), "vehicle", units, routePoints)
  return addGroupSafe(countryId, grp)
end

-- =====================
-- UNIT TYPE CLASSIFICATION (for quota tracking)
-- =====================
local BLUE_TYPE_CLASS = {
  ["M-1 Abrams"]        = "MBT",
  ["M-2 Bradley"]       = "IFV",
  ["M-113"]             = "APC",
  ["M1126 Stryker ICV"] = "APC",
}

local RED_TYPE_CLASS = {
  ["T-72B"]  = "MBT",
  ["BMP-2"]  = "IFV",
  ["BTR-80"] = "APC",
}

--- Count alive units of each quota category for a given coalition side.
local function countAliveByClass(coalitionSide, typeClassMap)
  local counts = { MBT = 0, IFV = 0, APC = 0 }
  local ok, groups = pcall(function()
    return coalition.getGroups(coalitionSide, Group.Category.GROUND)
  end)
  if not ok or not groups then return counts end
  for _, grp in ipairs(groups) do
    if grp and grp:isExist() then
      local units = grp:getUnits()
      if units then
        for _, u in ipairs(units) do
          if u and u:isExist() and u:getLife() > 1 then
            local typeName = u:getTypeName()
            local cat = typeClassMap[typeName]
            if cat and counts[cat] then
              counts[cat] = counts[cat] + 1
            end
          end
        end
      end
    end
  end
  return counts
end

--- Calculate how many more units of each category we can spawn.
local function quotaRoom(quotas, alive)
  local room = {}
  for cat, max in pairs(quotas) do
    room[cat] = math.max(0, max - (alive[cat] or 0))
  end
  return room
end

-- =====================
-- QUOTA GATE: check if a side has ANY room to spawn before calling spawn functions
-- =====================
local function blueHasQuotaRoom()
  local alive = countAliveByClass(coalition.side.BLUE, BLUE_TYPE_CLASS)
  local room = quotaRoom(CONFIG.blueQuota, alive)
  local totalRoom = (room.MBT or 0) + (room.IFV or 0) + (room.APC or 0)
  if CONFIG.testMode then
    out(string.format("BLUE total quota room: MBT=%d IFV=%d APC=%d (total=%d)",
      room.MBT, room.IFV, room.APC, totalRoom), 5)
  end
  return totalRoom > 0, alive, room
end

local function redHasQuotaRoom()
  local alive = countAliveByClass(coalition.side.RED, RED_TYPE_CLASS)
  local room = quotaRoom(CONFIG.redQuota, alive)
  local totalRoom = (room.MBT or 0) + (room.IFV or 0) + (room.APC or 0)
  if CONFIG.testMode then
    out(string.format("RED total quota room: MBT=%d IFV=%d APC=%d (total=%d)",
      room.MBT, room.IFV, room.APC, totalRoom), 5)
  end
  return totalRoom > 0, alive, room
end

-- =====================
-- BLUE SPAWN PACKAGES (quota-aware)
-- =====================
local function spawnInfantryPackage(atPoint, routePoints)
  local t = math.floor(now())
  local countryBlue = CONFIG.useUSAForBlue and country.id.USA or country.id.CJTF_BLUE
  local cx = atPoint.x
  local cy = atPoint.z or atPoint.y or 0

  -- Check APC quota for the escort Stryker
  local alive = countAliveByClass(coalition.side.BLUE, BLUE_TYPE_CLASS)
  local room = quotaRoom(CONFIG.blueQuota, alive)

  if CONFIG.testMode then
    out(string.format("BLUE INF quota check: APC alive=%d room=%d", alive.APC, room.APC), 5)
  end

  local off = radialOffsets(cx, cy, 10, 8)

  -- 6x M4, 1x M249, 1x RPG-7 (8 infantry -- not quota-limited)
  local infUnits = {}
  local idx = 1
  for i = 1, 6 do
    table.insert(infUnits, mkUnit(string.format("BL_INF_M4_%d_%d", t, i), "Soldier M4", off[idx].x, off[idx].y, off[idx].hdg))
    idx = idx + 1
  end
  table.insert(infUnits, mkUnit(string.format("BL_INF_M249_%d", t), "Soldier M249", off[idx].x, off[idx].y, off[idx].hdg))
  idx = idx + 1
  table.insert(infUnits, mkUnit(string.format("BL_INF_RPG_%d", t), "Soldier RPG", off[idx].x, off[idx].y, off[idx].hdg))
  idx = idx + 1

  local gInf = mkGroup(string.format("BLUE_INF_%d", t), "vehicle", infUnits, routePoints)
  addGroupSafe(countryBlue, gInf)

  -- 1x Stryker APC escort (only if quota allows)
  if room.APC >= 1 then
    local vpt = off[idx] or { x = cx + 12, y = cy, hdg = 0 }
    local vehUnits = {
      mkUnit(string.format("BL_STRYKER_%d", t), "M1126 Stryker ICV", vpt.x, vpt.y, vpt.hdg)
    }
    local gVeh = mkGroup(string.format("BLUE_STRYKER_%d", t), "vehicle", vehUnits, routePoints)
    addGroupSafe(countryBlue, gVeh)
  else
    logOnly("BLUE APC quota reached -- Stryker escort skipped")
  end
end

local function spawnArmorPackage(atPoint, routePoints)
  local countryBlue = CONFIG.useUSAForBlue and country.id.USA or country.id.CJTF_BLUE
  local cx = atPoint.x
  local cy = atPoint.z or atPoint.y or 0

  local alive = countAliveByClass(coalition.side.BLUE, BLUE_TYPE_CLASS)
  local room = quotaRoom(CONFIG.blueQuota, alive)

  if CONFIG.testMode then
    out(string.format("BLUE ARMOR quota check: MBT alive=%d room=%d | IFV alive=%d room=%d | APC alive=%d room=%d",
      alive.MBT, room.MBT, alive.IFV, room.IFV, alive.APC, room.APC), 5)
  end

  -- Quota-limited combat vehicles (uses shared spawnVehicleGroup)
  spawnVehicleGroup("BLUE_ABRAMS",  "M-1 Abrams",      4, cx, cy, 30, 1, "MBT", room, countryBlue, routePoints)
  spawnVehicleGroup("BLUE_BRADLEY", "M-2 Bradley",      4, cx, cy, 40, 2, "IFV", room, countryBlue, routePoints)
  spawnVehicleGroup("BLUE_M113",    "M-113",            2, cx, cy, 25, 3, "APC", room, countryBlue, routePoints)

  -- Support vehicles (not quota-limited: pass nil for quotaCat)
  spawnVehicleGroup("BLUE_CHAPARRAL", "M48 Chaparral", 1, cx, cy, 22, 1, nil, room, countryBlue, routePoints)
  spawnVehicleGroup("BLUE_TOW",       "M1045 HMMWV TOW", 2, cx, cy, 20, 2, nil, room, countryBlue, routePoints)

  -- German Gepard (BLUE coalition country) for AA
  spawnVehicleGroup("BLUE_GEPARD", "Gepard", 1, cx, cy, 28, 1, nil, room, country.id.GERMANY, routePoints)
end

-- =====================
-- RED SPAWN PACKAGES (quota-aware, using shared spawnVehicleGroup)
-- =====================
local function spawnRedWaveA(pt, routePoints, room)
  local cx = pt.x
  local cy = pt.z or pt.y or 0
  local cid = country.id.RUSSIA

  -- Wave A: BTR-80 + BMP-2 + ZSU-23-4 Shilka
  spawnVehicleGroup("RED_BTR80",  "BTR-80",          3, cx, cy, 26, 1, "APC", room, cid, routePoints)
  spawnVehicleGroup("RED_BMP2",   "BMP-2",           3, cx, cy, 30, 2, "IFV", room, cid, routePoints)
  spawnVehicleGroup("RED_SHILKA", "ZSU-23-4 Shilka", 1, cx, cy, 20, 1, nil,   room, cid, routePoints)  -- AA not quota-limited
end

local function spawnRedWaveB(pt, routePoints, room)
  local cx = pt.x
  local cy = pt.z or pt.y or 0
  local cid = country.id.RUSSIA

  -- Wave B: T-72B + BMP-2 + SA-9
  spawnVehicleGroup("RED_T72B", "T-72B",         4, cx, cy, 32, 1, "MBT", room, cid, routePoints)
  spawnVehicleGroup("RED_BMP2", "BMP-2",         2, cx, cy, 26, 2, "IFV", room, cid, routePoints)
  spawnVehicleGroup("RED_SA9",  "Strela-1 9P31", 1, cx, cy, 22, 1, nil,   room, cid, routePoints)  -- AA not quota-limited
end

-- =====================
-- SPAWN MANAGER (main logic)
-- =====================
local function startSpawnManager(mooseZones)
  if not CONFIG.enableSpawnManager then return end
  local SetFactory = getGlobal("SET_GROUP")
  if not SetFactory then
    out("Spawn manager disabled: MOOSE SET_GROUP not available", 10)
    return
  end

  local BlueGround, RedGround
  pcall(function()
    BlueGround = SetFactory:New():FilterCoalitions("blue"):FilterCategoryGround():FilterStart()
    RedGround  = SetFactory:New():FilterCoalitions("red"):FilterCategoryGround():FilterStart()
  end)
  if not BlueGround or not RedGround then
    out("Spawn manager disabled: unable to create BLUE/RED ground sets", 10)
    return
  end

  local zoneByName = {}
  for _, zo in ipairs(mooseZones or {}) do
    if type(zo.GetName) == "function" then zoneByName[zo:GetName()] = zo end
  end

  local function countInZone(zo, set)
    local n = 0
    if set and type(set.ForEachGroupInZone) == "function" then
      set:ForEachGroupInZone(zo, function() n = n + 1 end)
    end
    return n
  end

  -- =====================
  -- CAPTURE STATE: track which zones are captured by BLUE / RED
  -- =====================
  local blueCaptured = {}  -- blueCaptured["Alpha"] = true when BLUE holds it
  local redCaptured  = {}  -- redCaptured["Echo"] = true when RED holds it
  local holdStart    = {}  -- holdStart["Alpha_blue"] = timestamp

  -- Initialize capture state from CONFIG.initialZoneSides so the advance route
  -- logic knows which zones each side already owns at mission start.
  -- Without this, getCurrentTarget() would send units to zones they already hold.
  for _, zn in ipairs(CONFIG.blueAdvanceRoute) do blueCaptured[zn] = false end
  for _, zn in ipairs(CONFIG.redAdvanceRoute)  do redCaptured[zn]  = false end
  if CONFIG.initialZoneSides then
    for zn, side in pairs(CONFIG.initialZoneSides) do
      if side == 2 then
        -- BLUE owns this zone at start
        blueCaptured[zn] = true
        redCaptured[zn]  = false
      elseif side == 1 then
        -- RED owns this zone at start
        redCaptured[zn]  = true
        blueCaptured[zn] = false
      end
      -- side == 0 (NEUTRAL): both remain false (correct default)
    end
    logOnly("Capture state synced with initialZoneSides")
  end

  -- Restore saved state if persistence loaded it
  if rawget(_G, "_MZ_RestoredState") then
    local saved = _G._MZ_RestoredState
    if saved.blueCaptured then
      for k, v in pairs(saved.blueCaptured) do blueCaptured[k] = v end
      out("Restored BLUE capture state", 5)
    end
    if saved.redCaptured then
      for k, v in pairs(saved.redCaptured) do redCaptured[k] = v end
      out("Restored RED capture state", 5)
    end
    if saved.credits then
      MZ_Credits.setBalances(saved.credits)
      out("Restored player credits", 5)
    end
    -- Bridge hub state for deferred restoration (after activeHub/RED are initialized)
    _G._MZ_RestoredHubs = {
      activeHub      = saved.activeHub,
      redActive      = saved.redActive,
      redC2Destroyed = saved.redC2Destroyed,
    }
    _G._MZ_RestoredState = nil  -- clean up
  end

  --- Get the current target zone for a side (first uncaptured zone in their route).
  local function getCurrentTarget(route, capturedMap)
    for _, zn in ipairs(route) do
      if not capturedMap[zn] then return zn end
    end
    return route[#route]  -- all captured, hold at last zone
  end

  --- Build the remaining advance route from the current target onward.
  local function getRemainingRoute(route, capturedMap)
    local remaining = {}
    local found = false
    for _, zn in ipairs(route) do
      if not capturedMap[zn] then found = true end
      if found then table.insert(remaining, zn) end
    end
    if #remaining == 0 then remaining = { route[#route] } end
    return remaining
  end

  -- =====================
  -- ROUTE CYCLING: each wave picks a different route
  -- =====================
  local blueRouteIdx = 0
  local redRouteIdx  = 0

  --- Build the next route for a given side, cycling through available route variants.
  -- Shared logic for both BLUE and RED to eliminate duplication.
  -- @param sideLabel    string  "BLUE" or "RED" (for log messages)
  -- @param advanceRoute table   ordered list of zone names for this side
  -- @param capturedMap  table   { [zoneName] = bool } capture state
  -- @param routes       table|nil  list of waypoint route variants (from CONFIG)
  -- @param routeIdx     number  current route index (will be cycled)
  -- @return table, number  route waypoints, updated route index
  local function getNextRoute(sideLabel, advanceRoute, capturedMap, routes, routeIdx)
    local remaining = getRemainingRoute(advanceRoute, capturedMap)
    if routes and #routes > 0 then
      routeIdx = (routeIdx % #routes) + 1
      local waypoints = routes[routeIdx]
      -- Filter out waypoint zones that don't exist in the ME (graceful degradation)
      local validWp = {}
      local missingWp = {}
      for _, wp in ipairs(waypoints or {}) do
        if getZonePoint(wp) then
          table.insert(validWp, wp)
        else
          table.insert(missingWp, wp)
        end
      end
      if #missingWp > 0 and CONFIG.testMode then
        out(sideLabel .. " route #" .. routeIdx .. " missing WP zones: " .. listToString(missingWp), 8)
      end
      if #validWp > 0 then
        if CONFIG.testMode then
          out(sideLabel .. " using route #" .. routeIdx .. ": " .. listToString(validWp) .. " -> " .. listToString(remaining), 5)
        end
        return buildRouteWithWaypoints(validWp, remaining), routeIdx
      end
    end
    -- Fallback: direct route (still gets tactical approach waypoints)
    if CONFIG.testMode then
      out(sideLabel .. " using DIRECT route -> " .. listToString(remaining), 5)
    end
    return buildRouteWithWaypoints(nil, remaining), routeIdx
  end

  local function getNextBlueRoute()
    local route
    route, blueRouteIdx = getNextRoute("BLUE", CONFIG.blueAdvanceRoute, blueCaptured, CONFIG.blueRoutes, blueRouteIdx)
    return route
  end

  local function getNextRedRoute()
    local route
    route, redRouteIdx = getNextRoute("RED", CONFIG.redAdvanceRoute, redCaptured, CONFIG.redRoutes, redRouteIdx)
    return route
  end

  -- =====================
  -- BLUE spawn state
  -- =====================
  local activeHub = "north"
  local nextBlueSpawnAt = nil
  local lastBlueSpawnAt = 0
  local toggleInfArmor = true  -- true => infantry, false => armor

  --- Resolve the current BLUE spawn hub to a zone name and world point.
  -- @return table|nil, string|nil  world point, zone name
  local function currentSpawnPoint()
    local zname = CONFIG.spawnZones[activeHub]
    if not zname then return nil, nil end
    return getZonePoint(zname), zname
  end

  local function doSpawnWave()
    local curTime = now()
    if curTime - lastBlueSpawnAt < (CONFIG.spawnCooldown or 15) then
      if CONFIG.testMode then out("BLUE spawn skipped (cooldown)", 5) end
      return
    end

    -- QUOTA GATE: skip entire wave if no room for any vehicle type
    local hasRoom = blueHasQuotaRoom()
    if not hasRoom then
      logOnly("BLUE spawn skipped -- all vehicle quotas full")
      -- Still update timestamp so we don't spam this message every tick
      lastBlueSpawnAt = curTime
      return
    end

    local pt, zname = currentSpawnPoint()
    if not pt then
      out("No valid spawn point for hub '" .. tostring(activeHub) .. "' (check CONFIG.spawnZones)", 10)
      return
    end

    -- Build route for this wave (cycles through routes)
    local blueRoute = getNextBlueRoute()
    local target = getCurrentTarget(CONFIG.blueAdvanceRoute, blueCaptured)

    if CONFIG.testMode then
      out(string.format("BLUE route has %d waypoints, target=%s, routeIdx=%d",
        blueRoute and #blueRoute or 0, target, blueRouteIdx), 5)
    end

    local kind = nil
    if CONFIG.spawnAlternating then
      if toggleInfArmor then
        spawnInfantryPackage(pt, blueRoute)
        kind = "Infantry"
      else
        spawnArmorPackage(pt, blueRoute)
        kind = "Armor"
      end
      toggleInfArmor = not toggleInfArmor
    else
      spawnInfantryPackage(pt, blueRoute)
      spawnArmorPackage(pt, blueRoute)
      kind = "Infantry+Armor"
    end
    lastBlueSpawnAt = curTime
    logOnly(string.format("BLUE %s wave -> %s (from %s)", kind or "?", target, tostring(zname or "?")))
  end

  -- =====================
  -- RED spawn state
  -- =====================
  local RED = {
    hubs = CONFIG.redSpawnHubs or { start = "redSpawnE", middle = "redSpawnM" },
    active = "start",
    nextSpawnAt = nil,
    lastSpawnAt = 0,
    toggle = true,
    c2Destroyed = false,  -- set true when all C2 statics are destroyed
  }

  -- Restore spawn hub positions from saved state (persistence)
  if rawget(_G, "_MZ_RestoredHubs") then
    local hubs = _G._MZ_RestoredHubs
    if hubs.activeHub then activeHub = hubs.activeHub; out("Restored BLUE hub: " .. activeHub, 5) end
    if hubs.redActive then RED.active = hubs.redActive; out("Restored RED hub: " .. RED.active, 5) end
    if hubs.redC2Destroyed then RED.c2Destroyed = true; out("Restored RED C2 destroyed state", 5) end
    _G._MZ_RestoredHubs = nil
  end

  local function redSpawnPoint()
    local key = RED.active
    local zname = (key == "start" and RED.hubs.start) or (key == "middle" and RED.hubs.middle)
    return zname and getZonePoint(zname) or nil
  end

  local function doRedWave()
    -- C2 DESTRUCTION GATE: no more RED reinforcements if C2 is destroyed
    if RED.c2Destroyed then
      if CONFIG.testMode then out("RED spawn blocked -- C2 destroyed", 5) end
      return
    end

    local curTime = now()
    if curTime - RED.lastSpawnAt < (CONFIG.spawnCooldown or 15) then
      if CONFIG.testMode then out("RED spawn skipped (cooldown)", 5) end
      return
    end

    -- QUOTA GATE: skip entire wave if no room for any vehicle type
    local hasRoom = redHasQuotaRoom()
    if not hasRoom then
      logOnly("RED spawn skipped -- all vehicle quotas full")
      RED.lastSpawnAt = curTime
      return
    end

    local pt = redSpawnPoint()
    if not pt then
      out("No valid RED spawn point (check redSpawnE/redSpawnM zones exist)", 10)
      return
    end

    -- Check RED quotas (detailed, for per-type limiting inside wave functions)
    local alive = countAliveByClass(coalition.side.RED, RED_TYPE_CLASS)
    local room = quotaRoom(CONFIG.redQuota, alive)

    -- Build route for this wave (cycles through routes)
    local redRoute = getNextRedRoute()
    local target = getCurrentTarget(CONFIG.redAdvanceRoute, redCaptured)

    if CONFIG.testMode then
      out(string.format("RED route has %d waypoints, target=%s, routeIdx=%d",
        redRoute and #redRoute or 0, target, redRouteIdx), 5)
    end

    if RED.toggle then
      spawnRedWaveA(pt, redRoute, room)
    else
      spawnRedWaveB(pt, redRoute, room)
    end
    RED.toggle = not RED.toggle
    RED.lastSpawnAt = curTime
    logOnly(string.format("RED wave -> %s (%s)", target, RED.active == "start" and "rear" or "mid"))
  end

  -- =====================
  -- Initial spawns
  -- =====================
  if CONFIG.spawnOnStart then doSpawnWave() end
  do
    local firstInt = (CONFIG.firstSpawnIntervalBlue or CONFIG.firstSpawnInterval or CONFIG.spawnInterval)
    if firstInt and firstInt > 0 then
      nextBlueSpawnAt = now() + firstInt
    end
  end

  doRedWave()
  do
    local firstInt = (CONFIG.firstSpawnIntervalRed or CONFIG.firstSpawnInterval or CONFIG.spawnInterval)
    if firstInt and firstInt > 0 then
      RED.nextSpawnAt = now() + firstInt
    end
  end

  --- Build the current state snapshot for persistence saves.
  -- Centralizes the save-state table construction to avoid duplication.
  local function buildSaveState()
    return {
      blueCaptured    = blueCaptured,
      redCaptured     = redCaptured,
      activeHub       = activeHub,
      redActive       = RED.active,
      redC2Destroyed  = RED.c2Destroyed,
      credits         = MZ_Credits.getBalances(),
      timestamp       = os.time(),
    }
  end

  -- =====================
  -- ZONE_CAPTURE_COALITION SETUP (replaces manual capture polling)
  -- =====================
  -- Uses MOOSE ZONE_CAPTURE_COALITION for automatic capture detection.
  -- Each zone fires FSM events: OnAfterCaptured, OnAfterAttacked, OnAfterGuarded, OnAfterEmpty.
  -- Falls back to the legacy SCHEDULER-based polling if ZONE_CAPTURE_COALITION is not available.

  local captureZones = {}  -- { [zoneName] = ZONE_CAPTURE_COALITION object }
  local hasZCC = getGlobal("ZONE_CAPTURE_COALITION") ~= nil

  if CONFIG.useCaptureCoalition and hasZCC then
    out("Using ZONE_CAPTURE_COALITION for capture detection", 8)

    -- Build a name-to-index map for markup IDs
    local zoneIndexMap = {}
    for i, zn in ipairs(CONFIG.zoneNames) do zoneIndexMap[zn] = i end

    for _, zn in ipairs(CONFIG.zoneNames) do
      local zo = zoneByName[zn]
      if zo then
        -- Determine initial side for this zone
        local initSide = (CONFIG.initialZoneSides and CONFIG.initialZoneSides[zn]) or 1
        local initCoalition = (initSide == 2 and coalition.side.BLUE)
                           or (initSide == 1 and coalition.side.RED)
                           or coalition.side.NEUTRAL

        local ok, zcz = pcall(function()
          return ZONE_CAPTURE_COALITION:New(zo, initCoalition)
        end)

        if ok and zcz then
          captureZones[zn] = zcz
          local zIdx = zoneIndexMap[zn]

          -- Draw initial zone markup (Foothold-style)
          drawZoneMarkup(zn, zIdx, initSide)

          -- =====================
          -- OnAfterCaptured: fires when a new coalition takes the zone
          -- =====================
          function zcz:OnAfterCaptured(From, Event, To, NewCoalition)
            local newSide = 0
            if NewCoalition == coalition.side.BLUE then newSide = 2
            elseif NewCoalition == coalition.side.RED then newSide = 1
            end

            -- Update capture state tables
            if newSide == 2 then
              blueCaptured[zn] = true
              redCaptured[zn] = false
            elseif newSide == 1 then
              redCaptured[zn] = true
              blueCaptured[zn] = false
            end

            -- Update zone markup colors (Foothold-style)
            updateZoneMarkup(zIdx, newSide, zn)

            -- Also update via MOOSE DrawZone as fallback
            redrawZoneColor(zo,
              newSide == 2 and {0, 0, 1} or {1, 0, 0},
              newSide == 2 and {0, 0, 1} or {1, 0, 0})

            local sName = sideName(newSide)
            local nextTarget
            if newSide == 2 then
              nextTarget = getCurrentTarget(CONFIG.blueAdvanceRoute, blueCaptured)
            else
              nextTarget = getCurrentTarget(CONFIG.redAdvanceRoute, redCaptured)
            end
            msgAll(string.format("%s captured by %s! Next target: %s", zn, sName, nextTarget), 12)

            -- Award capture credits (only to players actually in/near the zone)
            if CONFIG.enableCredits then
              local zoneData = trigger.misc.getZone(zn)
              local players = (newSide == 2) and coalition.getPlayers(coalition.side.BLUE)
                                                or coalition.getPlayers(coalition.side.RED)
              if players and zoneData and zoneData.point then
                local zx, zz = zoneData.point.x, zoneData.point.z
                local zr = (zoneData.radius or 3000) * 1.5  -- 1.5x radius for credit eligibility
                local zrSq = zr * zr
                for _, p in ipairs(players) do
                  local pOk, pos = pcall(function() return p:getPoint() end)
                  if pOk and pos then
                    local dx = pos.x - zx
                    local dz = pos.z - zz
                    if (dx * dx + dz * dz) <= zrSq then
                      local pname = p:getPlayerName()
                      if pname then
                        MZ_Credits.add(pname, CONFIG.rewards.capture or 200)
                        out(string.format("[Credits] %s +%d (zone capture)", pname, CONFIG.rewards.capture or 200), 5)
                      end
                    end
                  end
                end
              end
            end

            -- BLUE capture actions
            if newSide == 2 then
              -- Advance spawn hub (data-driven via CONFIG.blueHubAdvance)
              local blueNewHub = CONFIG.blueHubAdvance and CONFIG.blueHubAdvance[zn]
              if blueNewHub and activeHub ~= blueNewHub then
                activeHub = blueNewHub
                local hubZone = CONFIG.spawnZones[blueNewHub] or blueNewHub
                msgAll("BLUE forward spawn moved to " .. hubZone .. ".", 10)
              end
              doSpawnWave()
            end

            -- RED capture actions
            if newSide == 1 then
              -- Advance RED hub (data-driven via CONFIG.redHubAdvance)
              local redNewHub = CONFIG.redHubAdvance and CONFIG.redHubAdvance[zn]
              if redNewHub and RED.active ~= redNewHub then
                RED.active = redNewHub
                local hubZone = RED.hubs[redNewHub] or redNewHub
                msgAll("RED counterattack hub moved to " .. hubZone .. ".", 10)
              end
              doRedWave()
            end

            -- Auto-save on capture
            if CONFIG.enablePersistence then
              MZ_Persistence.save(buildSaveState())
            end
          end

          -- =====================
          -- OnAfterAttacked: fires when enemy units enter a held zone
          -- =====================
          function zcz:OnAfterAttacked(From, Event, To, AttackCoalition)
            msgAll(string.format("%s is under attack by %s!", zn, sideName(AttackCoalition)), 8)
          end

          -- =====================
          -- OnAfterGuarded: fires when only the owning coalition is in the zone
          -- =====================
          function zcz:OnAfterGuarded(From, Event, To)
            if CONFIG.testMode then
              out(string.format("%s is guarded", zn), 3)
            end
          end

          -- Start the capture zone monitoring
          zcz:Start(CONFIG.captureCheckInterval or 15, CONFIG.captureHoldTime or 10)
          out(string.format("  Capture zone '%s' started (side=%d, check=%ds, hold=%ds)",
            zn, initSide, CONFIG.captureCheckInterval or 15, CONFIG.captureHoldTime or 10), 5)
        else
          out(string.format("ZONE_CAPTURE_COALITION:New('%s') failed: %s", zn, tostring(zcz)), 10)
        end
      end
    end

    local zcCount = 0; for _ in pairs(captureZones) do zcCount = zcCount + 1 end
    out(string.format("ZONE_CAPTURE_COALITION: %d zones active", zcCount), 8)

  else
    -- =====================
    -- LEGACY CAPTURE MONITOR (fallback if ZONE_CAPTURE_COALITION not available)
    -- =====================
    if not hasZCC then
      out("ZONE_CAPTURE_COALITION not available, using legacy capture monitor", 8)
    end

    -- Build a name-to-index map for markup IDs (same as ZCC path)
    local legacyZoneIndexMap = {}
    for i, zn in ipairs(CONFIG.zoneNames) do legacyZoneIndexMap[zn] = i end

    -- Draw initial zone markup for legacy path (ZCC path does this inside its loop)
    if CONFIG.useMarkupDraw then
      for _, zn in ipairs(CONFIG.zoneNames) do
        local initSide = (CONFIG.initialZoneSides and CONFIG.initialZoneSides[zn]) or 0
        local zIdx = legacyZoneIndexMap[zn]
        if zIdx then
          drawZoneMarkup(zn, zIdx, initSide)
        end
      end
    end

    pcall(function()
      SCHEDULER:New(nil, function()
        local curTime = now()

        -- Check BLUE captures (BLUE units in zone, no RED)
        for _, zn in ipairs(CONFIG.blueAdvanceRoute) do
          if not blueCaptured[zn] then
            local zo = zoneByName[zn]
            if zo then
              local b = countInZone(zo, BlueGround)
              local r = countInZone(zo, RedGround)
              local holdKey = zn .. "_blue"
              if b > 0 and r == 0 then
                if not holdStart[holdKey] then holdStart[holdKey] = curTime end
                if curTime - holdStart[holdKey] >= (CONFIG.captureHoldTime or 10) then
                  blueCaptured[zn] = true
                  redCaptured[zn] = false  -- clear RED ownership on BLUE capture
                  holdStart[holdKey] = nil
                  local nextTarget = getCurrentTarget(CONFIG.blueAdvanceRoute, blueCaptured)
                  msgAll(string.format("%s captured by BLUE! Next target: %s", zn, nextTarget), 12)
                  -- Update DCS markup zone colors (primary visual)
                  local zIdx = legacyZoneIndexMap[zn]
                  if zIdx then updateZoneMarkup(zIdx, 2, zn) end
                  -- Also update MOOSE DrawZone as fallback
                  redrawZoneColor(zo, {0, 0, 1}, {0, 0, 1})
                  -- Advance BLUE hub (data-driven via CONFIG.blueHubAdvance)
                  local blueNewHub = CONFIG.blueHubAdvance and CONFIG.blueHubAdvance[zn]
                  if blueNewHub and activeHub ~= blueNewHub then
                    activeHub = blueNewHub
                    local hubZone = CONFIG.spawnZones[blueNewHub] or blueNewHub
                    msgAll("BLUE forward spawn moved to " .. hubZone .. ".", 10)
                  end
                  doSpawnWave()
                  -- Auto-save on capture (persistence)
                  if CONFIG.enablePersistence then
                    MZ_Persistence.save(buildSaveState())
                  end
                end
              else
                holdStart[holdKey] = nil
              end
            end
          end
        end

        -- Check RED captures (RED units in zone, no BLUE)
        for _, zn in ipairs(CONFIG.redAdvanceRoute) do
          if not redCaptured[zn] then
            local zo = zoneByName[zn]
            if zo then
              local b = countInZone(zo, BlueGround)
              local r = countInZone(zo, RedGround)
              local holdKey = zn .. "_red"
              if r > 0 and b == 0 then
                if not holdStart[holdKey] then holdStart[holdKey] = curTime end
                if curTime - holdStart[holdKey] >= (CONFIG.captureHoldTime or 10) then
                  redCaptured[zn] = true
                  blueCaptured[zn] = false  -- clear BLUE ownership on RED capture
                  holdStart[holdKey] = nil
                  local nextTarget = getCurrentTarget(CONFIG.redAdvanceRoute, redCaptured)
                  msgAll(string.format("%s captured by RED! Next target: %s", zn, nextTarget), 12)
                  -- Update DCS markup zone colors (primary visual)
                  local zIdx = legacyZoneIndexMap[zn]
                  if zIdx then updateZoneMarkup(zIdx, 1, zn) end
                  -- Also update MOOSE DrawZone as fallback
                  redrawZoneColor(zo, {1, 0, 0}, {1, 0, 0})
                  -- Advance RED hub (data-driven via CONFIG.redHubAdvance)
                  local redNewHub = CONFIG.redHubAdvance and CONFIG.redHubAdvance[zn]
                  if redNewHub and RED.active ~= redNewHub then
                    RED.active = redNewHub
                    local hubZone = RED.hubs[redNewHub] or redNewHub
                    msgAll("RED counterattack hub moved to " .. hubZone .. ".", 10)
                  end
                  doRedWave()
                  -- Auto-save on capture (persistence)
                  if CONFIG.enablePersistence then
                    MZ_Persistence.save(buildSaveState())
                  end
                end
              else
                holdStart[holdKey] = nil
              end
            end
          end
        end
      end, {}, 2, 5)
    end)
  end

  -- =====================
  -- PERIODIC REINFORCEMENTS (runs regardless of capture method)
  -- =====================
  pcall(function()
    SCHEDULER:New(nil, function()
      local curTime = now()
      if nextBlueSpawnAt and curTime >= nextBlueSpawnAt then
        doSpawnWave()
        nextBlueSpawnAt = curTime + CONFIG.spawnInterval
      end
      if RED.nextSpawnAt and curTime >= RED.nextSpawnAt then
        doRedWave()
        RED.nextSpawnAt = curTime + CONFIG.spawnInterval
      end
    end, {}, 10, 10)
  end)

  -- =====================
  -- ENEMY C2 DESTRUCTION MONITOR
  -- =====================
  -- Periodically checks if all RED C2 static objects have been destroyed.
  -- When all are gone, RED reinforcements cease and a message is broadcast.
  -- Uses StaticObject.getByName() which returns nil for destroyed statics.
  if CONFIG.redC2StaticNames and #CONFIG.redC2StaticNames > 0 then
    local c2CheckInterval = CONFIG.redC2CheckInterval or 15
    out("C2 destruction monitor enabled for: " .. table.concat(CONFIG.redC2StaticNames, ", "), 5)
    pcall(function()
      SCHEDULER:New(nil, function()
        if RED.c2Destroyed then return end  -- already triggered, stop checking

        local allDestroyed = true
        for _, sName in ipairs(CONFIG.redC2StaticNames) do
          local obj = StaticObject.getByName(sName)
          if obj and obj:isExist() and obj:getLife() > 1 then
            allDestroyed = false
            break
          end
        end

        if allDestroyed then
          RED.c2Destroyed = true
          msgAll("Enemy C2 destroyed! RED reinforcements have been cut off!", 30)
          out("ALL RED C2 statics destroyed -- RED reinforcements DISABLED", 12)
        elseif CONFIG.testMode then
          -- Log status of each C2 object for debugging
          for _, sName in ipairs(CONFIG.redC2StaticNames) do
            local obj = StaticObject.getByName(sName)
            if obj and obj:isExist() then
              out(string.format("  C2 '%s': alive (life=%.0f)", sName, obj:getLife()), 5)
            else
              out(string.format("  C2 '%s': DESTROYED", sName), 5)
            end
          end
        end
      end, {}, c2CheckInterval, c2CheckInterval)
    end)
  end

  -- =====================
  -- PERSISTENCE: periodic auto-save
  -- =====================
  if CONFIG.enablePersistence then
    pcall(function()
      SCHEDULER:New(nil, function()
        MZ_Persistence.save(buildSaveState())
      end, {}, CONFIG.saveInterval or 60, CONFIG.saveInterval or 60)
    end)
    out("Persistence auto-save enabled (every " .. (CONFIG.saveInterval or 60) .. "s)", 5)
  end

  -- =====================
  -- CREDITS: start kill reward handler
  -- =====================
  if CONFIG.enableCredits then
    MZ_Credits.init()
    MZ_Credits.startKillRewards()
  end
end

-- =====================
-- CIRIBOB CTLD LOGGING PATCH
-- =====================
-- Monkey-patches ciribob CTLD's ctld.p() and logging functions at runtime
-- so users can run an UNMODIFIED ciribob CTLD.lua without log spam or crashes.
-- The original ctld.p() recursively serializes tables but does NOT detect
-- circular references (common in MOOSE/DCS objects), causing:
--   "E - CTLD - p|2307: max depth reached in ctld.p : 20"
-- Our replacement uses a 'seen' set to detect circular refs and returns
-- "[circular]" instead of recursing into already-visited tables.
local function patchCiribobCTLD()
  if not CONFIG.ctldPatchLogging then return end
  if type(ctld) ~= "table" then return end

  local maxDepth = CONFIG.ctldMaxLogDepth or 10

  -- Replace ctld.p() with a circular-reference-safe version
  ctld.p = function(o, level, seen)
    level = level or 0
    seen  = seen or {}

    if level > maxDepth then
      return "[max depth]"
    end

    if type(o) == "table" then
      if seen[o] then
        return "[circular]"
      end
      seen[o] = true
      local parts = {}
      local indent = string.rep(" ", level + 1)
      for key, value in pairs(o) do
        parts[#parts + 1] = indent .. "." .. tostring(key) .. "=" .. ctld.p(value, level + 1, seen)
      end
      return "\n" .. table.concat(parts, "\n")
    elseif type(o) == "function" then
      return "[function]"
    elseif type(o) == "boolean" then
      return o and "[true]" or "[false]"
    elseif o == nil then
      return "[nil]"
    else
      return tostring(o)
    end
  end

  -- Force debug/trace logging off as a safety measure
  ctld.Debug = false
  ctld.Trace = false

  -- Optionally suppress ctld.logInfo() to reduce log volume
  -- (errors and warnings are always kept)
  if CONFIG.ctldSuppressInfoLogs then
    ctld.logInfo = function() end
  end

  logOnly("Patched ciribob CTLD logging (maxDepth=" .. tostring(maxDepth)
    .. ", suppressInfo=" .. tostring(CONFIG.ctldSuppressInfoLogs == true) .. ")")
end

-- =====================
-- MOOSE Ops.CTLD SETUP
-- =====================
local function startCTLD()
  if not CONFIG.enableCTLD then return end

  -- =====================
  -- Detect which CTLD implementation is available
  -- =====================
  -- MOOSE classes use metatables, so CTLD.New lives on the metatable, not
  -- on the table itself.  We check for the global, then verify it looks like
  -- a MOOSE class (has a metatable or a .New key somewhere in the chain).
  local rawCTLD = rawget(_G, "CTLD")
  local hasMooseCTLD = false
  if rawCTLD ~= nil and type(rawCTLD) == "table" then
    -- .New may be inherited via metatable; use normal indexing, not rawget
    if type(rawCTLD.New) == "function" then
      hasMooseCTLD = true
    end
  end

  local hasCiribobCTLD = (getGlobal("ctld") ~= nil) and (type(rawget(_G, "ctld")) == "table")
                         and (rawget(_G, "ctld").Version ~= nil)

  -- Log what we found
  logOnly(string.format("CTLD detection: MOOSE Ops.CTLD=%s  ciribob ctld=%s",
    tostring(hasMooseCTLD), tostring(hasCiribobCTLD)))

  -- Extra diagnostics: check for required MOOSE support classes
  if hasMooseCTLD then
    local hasCTLD_CARGO_g = (rawget(_G, "CTLD_CARGO") ~= nil)
    local hasSET_GROUP_g  = (rawget(_G, "SET_GROUP") ~= nil)
    local hasFSM_g        = (rawget(_G, "FSM") ~= nil)
    logOnly(string.format("CTLD support classes: CTLD_CARGO=%s  SET_GROUP=%s  FSM=%s",
      tostring(hasCTLD_CARGO_g), tostring(hasSET_GROUP_g), tostring(hasFSM_g)))
  end

  if not hasMooseCTLD and not hasCiribobCTLD then
    out("CTLD disabled: neither MOOSE Ops.CTLD nor ciribob CTLD found.\n"
      .. "  - For MOOSE: ensure your MOOSE build includes Ops.CTLD\n"
      .. "  - For ciribob: load CTLD-i18n.lua, mist.lua, then CTLD.lua before this script", 15)
    return
  end

  -- zoneExists() is defined at module scope (shared utility)

  -- =====================
  -- PATH A: MOOSE Ops.CTLD
  -- =====================
  if hasMooseCTLD then
    logOnly("Initializing MOOSE Ops.CTLD...")

    -- Resolve smoke/flare colors now that MOOSE globals are available
    local smokeBlue   = (getGlobal("SMOKECOLOR") and SMOKECOLOR.Blue)   or 4
    local smokeRed    = (getGlobal("SMOKECOLOR") and SMOKECOLOR.Red)    or 1
    local smokeOrange = (getGlobal("SMOKECOLOR") and SMOKECOLOR.Orange) or 3
    local flareWhite  = (getGlobal("FLARECOLOR") and FLARECOLOR.White)  or 1

    local ok, err = pcall(function()
      -- -------------------------------------------------------
      -- Create the CTLD instance.
      -- Second arg is a table of GROUP NAME prefixes (case-sensitive).
      -- We include both "helicargo" and "Helicargo" to cover common
      -- naming conventions.
      -- -------------------------------------------------------
      local prefixes = CONFIG.ctldHeloPrefixes or { "helicargo" }
      logOnly("CTLD helo prefixes: " .. listToString(prefixes))

      local my_ctld = CTLD:New(
        coalition.side.BLUE,
        prefixes,
        CONFIG.ctldAlias or "Blue CTLD"
      )

      -- Store globally so other scripts can reference it
      _G.MZ_CTLD = my_ctld

      -- =====================
      -- CTLD Options
      -- =====================
      my_ctld.movetroopstowpzone    = CONFIG.ctldMoveToZone ~= false
      my_ctld.movetroopsdistance    = CONFIG.ctldMoveDistance or 5000
      my_ctld.EngineerSearch        = CONFIG.ctldEngineerSearch or 2000
      my_ctld.repairtime            = CONFIG.ctldRepairTime or 300
      my_ctld.buildtime             = CONFIG.ctldBuildTime or 300
      my_ctld.SmokeColor            = CONFIG.ctldSmokeColor or smokeBlue
      my_ctld.FlareColor            = CONFIG.ctldFlareColor or flareWhite
      my_ctld.useprefix             = true
      my_ctld.enableslingload       = false
      my_ctld.enableFixedWing       = true    -- enable C-130 / Hercules fixed-wing support
      my_ctld.pilotmustopendoors    = false
      my_ctld.forcehoverload        = true
      my_ctld.hoverautoloading      = true
      my_ctld.smokedistance         = 2000
      my_ctld.suppressmessages      = false
      my_ctld.allowcratepickupagain = true
      my_ctld.nobuildindropzones    = false
      my_ctld.dropcratesanywhere    = true    -- allow crate drops anywhere (not just DROP zones)
      my_ctld.nobuildinloadzones    = false   -- allow building in load zones too

      -- =====================
      -- MODDED HELICOPTER SUPPORT
      -- =====================
      -- Register extra unit-type capabilities for modded helicopters.
      -- This ensures MOOSE CTLD knows what each modded helo can carry.
      -- Without this, modded types default to 0 crates / 0 troops.
      for _, cap in ipairs(CONFIG.ctldExtraUnitCaps or {}) do
        if cap.type then
          my_ctld:SetUnitCapabilities(
            cap.type,
            cap.crates,
            cap.troops,
            cap.cratelimit  or 0,
            cap.trooplimit  or 0,
            cap.length       or 20,
            cap.cargoweightlimit or 500
          )
          logOnly("  Registered helo type: " .. cap.type
            .. " (crates=" .. tostring(cap.cratelimit or 0)
            .. ", troops=" .. tostring(cap.trooplimit or 0) .. ")")
        end
      end

      -- =====================
      -- CUSTOM PILOT SET (bypass FilterCategories for modded helos)
      -- =====================
      -- MOOSE CTLD's default onafterStart() creates a SET_GROUP filtered by
      -- coalition + prefix + FilterCategories("helicopter").  Modded aircraft
      -- (e.g. community UH-60, CH-47) may not be categorized as "helicopter"
      -- by DCS, causing them to be silently excluded.
      --
      -- When ctldUseOwnPilotSet is true, we create our own SET_GROUP that
      -- filters ONLY by coalition + prefix (no category filter) and pass it
      -- via SetOwnSetPilotGroups().  This guarantees modded helos get the
      -- CTLD F10 menu.
      if CONFIG.ctldUseOwnPilotSet then
        logOnly("Using custom pilot SET_GROUP (no category filter) for modded helo support")
        local pilotSet = SET_GROUP:New()
          :FilterCoalitions("blue")
          :FilterPrefixes(prefixes)
          :FilterStart()
        my_ctld:SetOwnSetPilotGroups(pilotSet)
        logOnly("  Custom pilot set created with prefixes: " .. listToString(prefixes))
      end

      -- =====================
      -- Validate template groups exist (warn but don't abort)
      -- =====================
      local function checkTemplate(tplName)
        -- Try MOOSE DATABASE first (most reliable for late-activated groups)
        if _DATABASE and _DATABASE.Templates and _DATABASE.Templates.Groups then
          if _DATABASE.Templates.Groups[tplName] then
            logOnly("  Template OK (DATABASE): " .. tplName)
            return true
          end
        end
        -- Fallback: try DCS Group.getByName (only finds active groups)
        if Group and Group.getByName then
          local grp = Group.getByName(tplName)
          if grp then
            logOnly("  Template OK (DCS API): " .. tplName)
            return true
          end
        end
        out("WARNING: late-activated template group '" .. tplName
          .. "' not found in ME. CTLD cargo using it will not work.\n"
          .. "  Create a BLUE late-activated group named exactly '" .. tplName .. "' in the ME.", 12)
        return false
      end

      -- =====================
      -- Add Troops Cargo (loaded directly into heli)
      -- =====================
      local hasCTLD_CARGO = (getGlobal("CTLD_CARGO") ~= nil)
      if not hasCTLD_CARGO then
        out("WARNING: CTLD_CARGO class not found; troop/crate cargo may not work. "
          .. "Check your MOOSE build includes Ops.CTLD fully.", 12)
      end

      for _, troop in ipairs(CONFIG.ctldTroops or {}) do
        for _, tpl in ipairs(troop.templates or {}) do checkTemplate(tpl) end
        if hasCTLD_CARGO then
          my_ctld:AddTroopsCargo(
            troop.name,
            troop.templates,
            CTLD_CARGO.Enum.TROOPS,
            troop.size,
            nil,
            nil
          )
          logOnly("  Added troop cargo: " .. troop.name .. " (size " .. tostring(troop.size) .. ")")
        end
      end

      -- =====================
      -- Add Engineers
      -- =====================
      if CONFIG.ctldEngineers and hasCTLD_CARGO then
        local eng = CONFIG.ctldEngineers
        for _, tpl in ipairs(eng.templates or {}) do checkTemplate(tpl) end
        my_ctld:AddTroopsCargo(
          eng.name,
          eng.templates,
          CTLD_CARGO.Enum.ENGINEERS,
          eng.size or 2,
          nil,
          nil
        )
        logOnly("  Added engineer cargo: " .. eng.name .. " (size " .. tostring(eng.size or 2) .. ")")
      end

       -- =====================
       -- Add Vehicle Crates Cargo
       -- =====================
       for _, veh in ipairs(CONFIG.ctldVehicleCrates or {}) do
         for _, tpl in ipairs(veh.templates or {}) do checkTemplate(tpl) end
         if hasCTLD_CARGO then
           my_ctld:AddCratesCargo(
             veh.name,
             veh.templates,
             CTLD_CARGO.Enum.VEHICLE,
             veh.crates or 2,
             nil,
             veh.stock or nil
           )
           logOnly("  Added crate cargo: " .. veh.name .. " (" .. tostring(veh.crates or 2) .. " crates)")
         end
       end
       
       -- =====================
       -- Add FARP Crates Cargo
       -- =====================
       if CONFIG.ctldFarpCrates and hasCTLD_CARGO then
         for _, farp in ipairs(CONFIG.ctldFarpCrates or {}) do
           for _, tpl in ipairs(farp.templates or {}) do checkTemplate(tpl) end
           my_ctld:AddCratesCargo(
             farp.name,
             farp.templates,
             CTLD_CARGO.Enum.FARP,
             farp.crates or 1,
             nil,
             farp.stock or nil
           )
           logOnly("  Added FARP cargo: " .. farp.name .. " (" .. tostring(farp.crates or 1) .. " crates)")
         end
       end
       
       -- =====================
       -- Shop Menu Builder (for credit system)
       -- =====================
       if CONFIG.enableCredits then
         -- Add shop items to CTLD menu
         my_ctld:AddMenuItem("Reinforcement Wave", CONFIG.shopPrices.reinforcementWave, function()
           -- Spawn reinforcement wave logic will go here
           out("Reinforcement wave deployed! (Not yet implemented)", 10)
         end)
         
         my_ctld:AddMenuItem("Smoke Marker", CONFIG.shopPrices.smokeMarker, function()
           -- Smoke marker logic will go here
           out("Smoke marker deployed! (Not yet implemented)", 10)
         end)
         
          -- Add CTLD items to shop menu with prices
          for _, troop in ipairs(CONFIG.ctldTroops or {}) do
            local priceKey = "ctld" .. troop.name:gsub(" ", ""):gsub("Team", "Team"):gsub("Squad", "Squad")
            if CONFIG.shopPrices[priceKey] then
              my_ctld:AddMenuItem(troop.name .. " (" .. CONFIG.shopPrices[priceKey] .. " credits)", function()
                -- This would normally trigger the CTLD cargo selection
                out("Select " .. troop.name .. " from CTLD menu to purchase", 10)
              end)
            end
          end
         
          for _, veh in ipairs(CONFIG.ctldVehicleCrates or {}) do
            local priceKey = "ctld" .. veh.name:gsub(" ", ""):gsub("ICV", "ICV"):gsub("IFV", "IFV"):gsub("TOW", "TOW")
            if CONFIG.shopPrices[priceKey] then
              my_ctld:AddMenuItem(veh.name .. " (" .. CONFIG.shopPrices[priceKey] .. " credits)", function()
                out("Select " .. veh.name .. " from CTLD menu to purchase", 10)
              end)
            end
          end
         
          if CONFIG.ctldEngineers then
            local priceKey = "ctldEngineers"
            if CONFIG.shopPrices[priceKey] then
              my_ctld:AddMenuItem("Engineer Team (" .. CONFIG.shopPrices[priceKey] .. " credits)", function()
                out("Select Engineer Team from CTLD menu to purchase", 10)
              end)
            end
          end
         
          if CONFIG.ctldFarpCrates then
            for _, farp in ipairs(CONFIG.ctldFarpCrates or {}) do
              local priceKey = "ctldFARPCrate"
              if CONFIG.shopPrices[priceKey] then
                my_ctld:AddMenuItem(farp.name .. " (" .. CONFIG.shopPrices[priceKey] .. " credits)", function()
                  out("Select " .. farp.name .. " from CTLD menu to purchase", 10)
                end)
              end
            end
          end
       end

      -- =====================
      -- Add CTLD Zones (only if the trigger zone exists in the ME)
      -- =====================
      local zonesAdded = 0

      -- LOAD zones
      for _, zname in ipairs(CONFIG.ctldLoadZones or {}) do
        if zoneExists(zname) then
          my_ctld:AddCTLDZone(zname, CTLD.CargoZoneType.LOAD, smokeBlue, true, true)
          zonesAdded = zonesAdded + 1
          logOnly("  LOAD zone added: " .. zname)
        else
          out("WARNING: CTLD LOAD zone '" .. zname .. "' not found in ME -- skipped.\n"
            .. "  Create a round trigger zone named '" .. zname .. "' in the Mission Editor.", 10)
        end
      end

      -- DROP zones
      for _, zname in ipairs(CONFIG.ctldDropZones or {}) do
        if zoneExists(zname) then
          my_ctld:AddCTLDZone(zname, CTLD.CargoZoneType.DROP, smokeRed, true, true)
          zonesAdded = zonesAdded + 1
          logOnly("  DROP zone added: " .. zname)
        else
          out("WARNING: CTLD DROP zone '" .. zname .. "' not found in ME -- skipped.\n"
            .. "  Create a round trigger zone named '" .. zname .. "' in the Mission Editor.", 10)
        end
      end

      -- MOVE zones
      for _, zname in ipairs(CONFIG.ctldMoveZones or {}) do
        if zoneExists(zname) then
          my_ctld:AddCTLDZone(zname, CTLD.CargoZoneType.MOVE, smokeOrange, true, false)
          zonesAdded = zonesAdded + 1
          logOnly("  MOVE zone added: " .. zname)
        else
          out("WARNING: CTLD MOVE zone '" .. zname .. "' not found in ME -- skipped.\n"
            .. "  Create a round trigger zone named '" .. zname .. "' in the Mission Editor.", 10)
        end
      end

      if zonesAdded == 0 then
        out("WARNING: No CTLD zones were added! Create trigger zones in the ME:\n"
          .. "  LOAD: " .. listToString(CONFIG.ctldLoadZones or {}) .. "\n"
          .. "  DROP: " .. listToString(CONFIG.ctldDropZones or {}) .. "\n"
          .. "  MOVE: " .. listToString(CONFIG.ctldMoveZones or {}), 15)
      end

      -- =====================
      -- Start CTLD
      -- =====================
      my_ctld:__Start(5)

      -- =====================
      -- FSM Event Callbacks
      -- =====================
      function my_ctld:OnAfterTroopsDeployed(From, Event, To, Group, Unit, Troops)
        local msg = string.format("[MZ-CTLD] Troops deployed by %s: %s",
          Unit and Unit:GetName() or "unknown",
          Troops and Troops.Name or "unknown")
        if env and env.info then env.info(msg) end
        out(msg, 8)
      end

      function my_ctld:OnAfterCratesBuild(From, Event, To, Group, Unit, Vehicle)
        local msg = string.format("[MZ-CTLD] Vehicle built by %s: %s",
          Unit and Unit:GetName() or "unknown",
          Vehicle and Vehicle.Name or "unknown")
        if env and env.info then env.info(msg) end
        out(msg, 8)
      end

      function my_ctld:OnAfterTroopsPickedUp(From, Event, To, Group, Unit, Cargo)
        local msg = string.format("[MZ-CTLD] Troops picked up by %s: %s",
          Unit and Unit:GetName() or "unknown",
          Cargo and Cargo.Name or "unknown")
        if env and env.info then env.info(msg) end
      end

      function my_ctld:OnAfterCratesPickedUp(From, Event, To, Group, Unit, Cargo)
        local msg = string.format("[MZ-CTLD] Crate picked up by %s: %s",
          Unit and Unit:GetName() or "unknown",
          Cargo and Cargo.Name or "unknown")
        if env and env.info then env.info(msg) end
      end

      out(string.format("MOOSE Ops.CTLD initialized and started (%d zones, %d helo types registered)",
        zonesAdded, #(CONFIG.ctldExtraUnitCaps or {})), 10)
      msgAll("CTLD active! Helicopter pilots (helicargo1, helicargo2, ...) can load troops and crates.\n"
        .. "Land in a LOAD zone and use the F10 menu.", 15)
    end)

    if not ok then
      out("MOOSE CTLD initialization FAILED: " .. tostring(err), 15)
      out("Check dcs.log for details. Common causes:\n"
        .. "  1) MOOSE build missing Ops.CTLD or CTLD_CARGO\n"
        .. "  2) Late-activated template groups missing from ME\n"
        .. "  3) Trigger zones missing from ME", 10)
    end
    return
  end

  -- =====================
  -- PATH B: ciribob standalone CTLD (fallback)
  -- =====================
  if hasCiribobCTLD then
    out("Detected ciribob CTLD v" .. tostring(ctld.Version) .. " -- configuring zones", 8)

    -- Patch ciribob CTLD logging to prevent ctld.p() circular-reference crashes
    patchCiribobCTLD()

    local ok2, err2 = pcall(function()
      -- The helicopter names "helicargo1".."helicargo25" are already in
      -- ctld.transportPilotNames by default.  Add any extra names from CONFIG.
      -- ciribob CTLD uses EXACT unit name matching, not prefix matching.
      -- We'll add "helicargo1".."helicargo10" explicitly just in case the
      -- defaults were overridden.
      local function ensurePilotName(name)
        for _, existing in ipairs(ctld.transportPilotNames) do
          if existing == name then return end
        end
        table.insert(ctld.transportPilotNames, name)
        out("  Added transport pilot: " .. name, 5)
      end

      -- Ensure helicargo1-4 are registered (they should be by default)
      for i = 1, 4 do
        ensurePilotName("helicargo" .. i)
      end

      -- Add LOAD zones (pickup zones) from CONFIG
      -- ciribob format (post-init): { name, smokeColorNum, limit, activeFlag(1/0), side }
      for _, zname in ipairs(CONFIG.ctldLoadZones or {}) do
        if zoneExists(zname) then
          table.insert(ctld.pickupZones, { zname, trigger.smokeColor.Blue, 10000, 1, 2 })
          out("  Pickup zone added: " .. zname, 5)
        else
          out("WARNING: CTLD pickup zone '" .. zname .. "' not found in ME -- skipped", 10)
        end
      end

      -- Add DROP zones from CONFIG
      -- ciribob format (post-init): { name, smokeColorNum, side }
      for _, zname in ipairs(CONFIG.ctldDropZones or {}) do
        if zoneExists(zname) then
          table.insert(ctld.dropOffZones, { zname, trigger.smokeColor.Green, 2, 1 })
          out("  Drop-off zone added: " .. zname, 5)
        else
          out("WARNING: CTLD drop-off zone '" .. zname .. "' not found in ME -- skipped", 10)
        end
      end

      -- Add MOVE zones (waypoint zones) from CONFIG
      -- ciribob format (post-init): { name, smokeColorNum, activeFlag(1/0), side }
      for _, zname in ipairs(CONFIG.ctldMoveZones or {}) do
        if zoneExists(zname) then
          table.insert(ctld.wpZones, { zname, trigger.smokeColor.Orange, 1, 2 })
          out("  Waypoint zone added: " .. zname, 5)
        else
          out("WARNING: CTLD waypoint zone '" .. zname .. "' not found in ME -- skipped", 10)
        end
      end

      out("ciribob CTLD configured successfully", 10)
      msgAll("CTLD active (ciribob v" .. tostring(ctld.Version) .. ")! Use F10 menu to load troops.", 15)
    end)

    if not ok2 then
      out("ciribob CTLD configuration failed: " .. tostring(err2), 15)
    end
    return
  end
end

-- =====================
-- MAIN INITIALIZATION
-- =====================
local t0 = now()
out(string.format("Initializer loaded (t=%.1fs)", t0))

validateConfig()

local function computeZonesOk(missing)
  local allPresent = (#missing == 0)
  local anyPresent = (#missing < #CONFIG.zoneNames)
  if CONFIG.requireAllZones then
    return allPresent
  else
    return anyPresent
  end
end

-- Readiness loop: wait for MOOSE + zones
if timer and type(timer.scheduleFunction) == "function" and type(timer.getTime) == "function" then
  local first = true
  local deadline = timer.getTime() + CONFIG.readyTimeout
  local lastMissingMsgAt = -1

  local function poll()
    local pollTime = timer.getTime()

    if first then
      first = false
      out("Waiting for MOOSE core and Mission Editor zones...")
    end

    local missing = getMissingZones(CONFIG.zoneNames)
    local zonesOk = computeZonesOk(missing)
    local mooseOk = mooseVisible()

    if CONFIG.testMode then
      out(string.format(
        "poll: mooseOk=%s zonesOk=%s missing=[%s]",
        tostring(mooseOk), tostring(zonesOk), listToString(missing)
      ), 5)
    end

    if zonesOk and mooseOk then
      out(string.format("Ready after %.1fs -- initializing", pollTime - t0), 10)

      local namesToUse
      if CONFIG.requireAllZones then
        namesToUse = CONFIG.zoneNames
      else
        namesToUse = {}
        for _, n in ipairs(CONFIG.zoneNames) do
          if trigger and trigger.misc and trigger.misc.getZone then
            local z = trigger.misc.getZone(n)
            if z and z.point then table.insert(namesToUse, n) end
          end
        end
      end

      if CONFIG.smokeZones then
        for _, n in ipairs(namesToUse) do nativeSmoke(n) end
      end

      local mooseZones = buildZones(namesToUse)
      out(string.format("Constructed %d MOOSE zones", #mooseZones), 10)

      -- Load saved state before starting managers (persistence)
      if CONFIG.enablePersistence then
        local saved = MZ_Persistence.load()
        if saved then
          out("Restoring saved state...", 8)
          -- Note: blueCaptured/redCaptured/activeHub/RED.active are local to
          -- startSpawnManager, so we pass the saved state via a global bridge.
          _G._MZ_RestoredState = saved
        end
      end

      local detOk, detErr = pcall(startDetection, mooseZones)
      if not detOk then out("startDetection() CRASHED: " .. tostring(detErr), 20) end

      local spawnOk, spawnErr = pcall(startSpawnManager, mooseZones)
      if not spawnOk then out("startSpawnManager() CRASHED: " .. tostring(spawnErr), 20) end

      logOnly("About to call startCTLD() (enableCTLD=" .. tostring(CONFIG.enableCTLD) .. ")")
      local ctldOk, ctldErr = pcall(startCTLD)
      if not ctldOk then
        out("startCTLD() CRASHED: " .. tostring(ctldErr), 20)
      end
      if CONFIG.testMode then out("Spawn manager started (test mode active)", 8) end
      return nil
    end

    if #missing > 0 and (lastMissingMsgAt < 0 or pollTime - lastMissingMsgAt >= 5) then
      out("Still waiting for zone(s): " .. listToString(missing), 8)
      lastMissingMsgAt = pollTime
    end

    if pollTime > deadline then
      if #missing > 0 then
        out("Timeout waiting for MOOSE and/or zones. Missing: " .. listToString(missing) .. ". Check load order and zone names.", 15)
      else
        out("Timeout waiting for MOOSE core availability.", 15)
      end
      return nil
    end

    return pollTime + CONFIG.pollInterval
  end

  timer.scheduleFunction(function() return poll() end, nil, timer.getTime() + CONFIG.pollInterval)
else
  local missing = getMissingZones(CONFIG.zoneNames)
  local zonesOk = computeZonesOk(missing)
  local mooseOk = mooseVisible()
  out(string.format("Timer unavailable; zonesOk=%s mooseOk=%s (single-attempt init)", tostring(zonesOk), tostring(mooseOk)), 10)
  if zonesOk and mooseOk then
    local namesToUse = CONFIG.requireAllZones and CONFIG.zoneNames or (function()
      local tbl = {}
      for _, n in ipairs(CONFIG.zoneNames) do
        local z = trigger and trigger.misc and trigger.misc.getZone and trigger.misc.getZone(n) or nil
        if z and z.point then table.insert(tbl, n) end
      end
      return tbl
    end)()
    if CONFIG.smokeZones then for _, n in ipairs(namesToUse) do nativeSmoke(n) end end
    local mooseZones = buildZones(namesToUse)
    startDetection(mooseZones)
    startSpawnManager(mooseZones)
      logOnly("About to call startCTLD() (enableCTLD=" .. tostring(CONFIG.enableCTLD) .. ")")
    local ctldOk2, ctldErr2 = pcall(startCTLD)
    if not ctldOk2 then
      out("startCTLD() CRASHED: " .. tostring(ctldErr2), 20)
    end
  elseif #missing > 0 then
    out("Single-attempt init missing zone(s): " .. listToString(missing), 10)
  end
end
