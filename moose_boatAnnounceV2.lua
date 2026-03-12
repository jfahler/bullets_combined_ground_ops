-------------------------------------------------------------------
-- Carrier Launch Sequence Script (MOOSE + DCS Scripting Engine)
--
-- Purpose:
--   F10 menu item lets the mission commander authorize a carrier
--   launch sequence. When activated:
--     1. A deck announcement .ogg plays in 3D space at the carrier
--     2. DCS flag 42 is set to TRUE, triggering AI flight ops
--     3. A confirmation message is displayed
--
-- Requirements:
--   - MOOSE framework loaded before this script
--   - A unit named "unionCVN" in the Mission Editor
--   - boatAnnounce.ogg placed in the mission's sound folder
--     (inside the .miz under "l10n/DEFAULT/")
--   - AI flight group(s) set to start via flag 42 in the ME
--     (use "FLAG IS TRUE(42)" as an activation trigger)
-------------------------------------------------------------------

-- ============================================================
-- CONFIGURATION
-- ============================================================
local CONFIG = {
    carrierUnitName  = "unionCVN",         -- ME unit name of the carrier
    soundFile        = "boatAnnounce.ogg", -- .ogg in l10n/DEFAULT/ inside .miz
    zoneRadius       = 50,                 -- radius (meters) for the tower zone
    flagNumber       = 42,                 -- DCS flag to push for AI launch
    menuText         = "Authorize Launch Sequence",
    msgDuration      = 15,                 -- seconds to show confirmation message
    coalition        = coalition.side.BLUE, -- which coalition hears the sound
}

-- ============================================================
-- INITIALIZATION
-- ============================================================

--- Find the carrier unit
local CarrierUnit = UNIT:FindByName(CONFIG.carrierUnitName)

if not CarrierUnit then
    env.error("[BoatAnnounce] ERROR: Carrier unit '"
        .. CONFIG.carrierUnitName
        .. "' not found! Check the unit name in the Mission Editor.")
    MESSAGE:New("ERROR: Carrier unit '"
        .. CONFIG.carrierUnitName .. "' not found!", 30):ToAll()
    return
end

env.info("[BoatAnnounce] Carrier unit '"
    .. CONFIG.carrierUnitName .. "' found. Script initializing...")

--- Create a moving zone centered on the carrier for spatial reference
local TowerZone = ZONE_UNIT:New("CarrierTowerZone", CarrierUnit, CONFIG.zoneRadius)

-- Track whether launch has already been authorized (prevent double-trigger)
local launchAuthorized = false

-- Forward-declare the menu variable so we can remove it later
local MenuLaunchSequence = nil

-- ============================================================
-- SOUND PLAYBACK HELPER
-- ============================================================
-- DCS has no true "play sound at a 3D world coordinate" API.
-- The closest options are:
--   trigger.action.outSound(filename)              -> all players
--   trigger.action.outSoundForCoalition(coa, file) -> one coalition
--   trigger.action.outSoundForGroup(groupId, file) -> one group
--
-- For carrier ops the most useful approach is to play the sound
-- for the BLUE coalition so everyone on the friendly side hears
-- the deck announcement.  If you want only players physically
-- near the carrier to hear it, you can iterate players inside
-- the TowerZone and use outSoundForGroup per-group instead.
-- ============================================================

--- Play the announcement sound to the configured coalition.
--- @param filename string  The .ogg filename
local function PlayAnnouncementSound(filename)
    -- Option A: Play for the whole coalition (simple, reliable)
    trigger.action.outSoundForCoalition(CONFIG.coalition, filename)

    -- Option B (commented out): Play only for player groups inside
    -- the carrier zone. Uncomment this block and comment Option A
    -- if you want distance-limited playback.
    --[[
    local zoneSet = SET_GROUP:New():FilterZones({ TowerZone }):FilterOnce()
    zoneSet:ForEachGroup(function(grp)
        if grp and grp:IsAlive() then
            trigger.action.outSoundForGroup(grp:GetDCSObject():getID(), filename)
        end
    end)
    --]]
end

-- ============================================================
-- CORE FUNCTION: Trigger the launch sequence
-- ============================================================
local function TriggerLaunchSequence()

    -- Guard: prevent multiple activations
    if launchAuthorized then
        MESSAGE:New("Launch sequence already authorized.", 10):ToAll()
        return
    end
    launchAuthorized = true

    -- 1. Verify carrier is still alive
    if not CarrierUnit:IsAlive() then
        env.error("[BoatAnnounce] Carrier unit is no longer alive.")
        MESSAGE:New("ERROR: Carrier is no longer operational!", 10):ToAll()
        launchAuthorized = false
        return
    end

    -- 2. Play the .ogg announcement
    PlayAnnouncementSound(CONFIG.soundFile)
    env.info("[BoatAnnounce] Deck announcement playing.")

    -- 3. Set the DCS flag to activate AI flight operations
    trigger.action.setUserFlag(tostring(CONFIG.flagNumber), true)
    env.info("[BoatAnnounce] Flag " .. CONFIG.flagNumber
        .. " set to TRUE. AI flights authorized.")

    -- 4. Display confirmation to all players
    MESSAGE:New(
        "CARRIER LAUNCH SEQUENCE AUTHORIZED\n" ..
        "Deck announcement active. AI flight ops initiated.\n" ..
        "Flag " .. CONFIG.flagNumber .. " is now TRUE.",
        CONFIG.msgDuration
    ):ToAll()

    -- 5. Remove the F10 menu item so it can't be triggered again
    if MenuLaunchSequence then
        MenuLaunchSequence:Remove()
        MenuLaunchSequence = nil
        env.info("[BoatAnnounce] F10 menu item removed.")
    end
end

-- ============================================================
-- F10 RADIO MENU
-- ============================================================

--- Add the "Authorize Launch Sequence" option under F10 > Other
MenuLaunchSequence = MENU_MISSION:New(
    CONFIG.menuText, nil, TriggerLaunchSequence
)

env.info("[BoatAnnounce] Script loaded. F10 menu item '"
    .. CONFIG.menuText .. "' is available.")

-------------------------------------------------------------------
-- END OF SCRIPT
-------------------------------------------------------------------
