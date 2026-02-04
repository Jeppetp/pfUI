-- load pfUI environment
setfenv(1, pfUI:GetEnvironment())

--[[ libdebuff ]]--
-- A pfUI library that detects and saves all ongoing debuffs of players, NPCs and enemies.
-- The functions UnitDebuff is exposed to the modules which allows to query debuffs like you
-- would on later expansions.
--
--  libdebuff:UnitDebuff(unit, id)
--    Returns debuff informations on the given effect of the specified unit.
--    name, rank, texture, stacks, dtype, duration, timeleft

-- return instantly if we're not on a vanilla client
if pfUI.client > 11200 then return end

-- return instantly when another libdebuff is already active
if pfUI.api.libdebuff then return end

-- fix a typo (missing $) in ruRU capture index
if GetLocale() == "ruRU" then
  SPELLREFLECTSELFOTHER = gsub(SPELLREFLECTSELFOTHER, "%%2s", "%%2%$s")
end

local libdebuff = CreateFrame("Frame", "pfdebuffsScanner", UIParent)
local scanner = libtipscan:GetScanner("libdebuff")
local _, class = UnitClass("player")
local lastspell

-- Nampower Support
local hasNampower = false

-- Set hasNampower immediately for functionality
if GetNampowerVersion then
  local major, minor, patch = GetNampowerVersion()
  patch = patch or 0
  -- Minimum required version: 2.27.2 (SPELL_FAILED_OTHER fix)
  if major > 2 or (major == 2 and minor > 27) or (major == 2 and minor == 27 and patch >= 2) then
    hasNampower = true
  end
end

-- Delayed Nampower version check (5 seconds after PLAYER_ENTERING_WORLD)
local nampowerCheckFrame = CreateFrame("Frame")
local nampowerCheckTimer = 0
local nampowerCheckDone = false
nampowerCheckFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
nampowerCheckFrame:RegisterEvent("PLAYER_LOGOUT")
nampowerCheckFrame:SetScript("OnEvent", function()
  -- Handle shutdown to prevent crash 132
  if event == "PLAYER_LOGOUT" then
    this:UnregisterAllEvents()
    this:SetScript("OnEvent", nil)
    this:SetScript("OnUpdate", nil)
    return
  end
  
  nampowerCheckFrame:SetScript("OnUpdate", function()
    nampowerCheckTimer = nampowerCheckTimer + arg1
    if nampowerCheckTimer >= 5 and not nampowerCheckDone then
      nampowerCheckDone = true
      
      if GetNampowerVersion then
        local major, minor, patch = GetNampowerVersion()
        patch = patch or 0  -- Fallback falls patch nil ist
        local versionString = major .. "." .. minor .. "." .. patch
        
        -- Check for minimum required version: 2.27.2 (SPELL_FAILED_OTHER fix)
        if major > 2 or (major == 2 and minor > 27) or (major == 2 and minor == 27 and patch >= 2) then
          DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[libdebuff]|r Nampower v" .. versionString .. " detected - debuff tracking enabled!")
          
          -- ✅ Aktiviere benötigte Nampower CVars
          if SetCVar and GetCVar then
            local cvarsToEnable = {
              "NP_EnableSpellStartEvents",
              "NP_EnableSpellGoEvents", 
              "NP_EnableAuraCastEvents",
              "NP_EnableAutoAttackEvents"
            }
            
            local totalCvars = table.getn(cvarsToEnable)
            local enabledCount = 0
            local alreadyEnabledCount = 0
            local failedCount = 0
            
            for _, cvar in ipairs(cvarsToEnable) do
              local success, currentValue = pcall(GetCVar, cvar)
              if success and currentValue then
                if currentValue == "1" then
                  alreadyEnabledCount = alreadyEnabledCount + 1
                else
                  local setSuccess = pcall(SetCVar, cvar, "1")
                  if setSuccess then
                    enabledCount = enabledCount + 1
                  else
                    failedCount = failedCount + 1
                  end
                end
              else
                failedCount = failedCount + 1
              end
            end
            
            if enabledCount > 0 then
              DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[libdebuff]|r Enabled " .. enabledCount .. " Nampower CVars")
            end
            
            if alreadyEnabledCount == totalCvars then
              DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[libdebuff]|r All required Nampower CVars already enabled")
            elseif alreadyEnabledCount > 0 then
              DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[libdebuff]|r " .. alreadyEnabledCount .. " CVars were already enabled")
            end
            
            if failedCount > 0 then
              DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[libdebuff]|r Warning: Could not check/set " .. failedCount .. " CVars")
            end
          else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[libdebuff]|r Note: SetCVar/GetCVar not available - please enable CVars manually:")
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[libdebuff]|r /run SetCVar('NP_EnableAuraCastEvents','1')")
          end
          
        elseif major == 2 and minor == 27 and patch == 1 then
          -- Special warning for 2.27.1 (SPELL_FAILED_OTHER broken)
          DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[libdebuff] WARNING: Nampower v2.27.1 detected!|r")
          DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[libdebuff] Cast-bar cancel detection will NOT work due to SPELL_FAILED_OTHER bug.|r")
          DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[libdebuff] Please update to v2.27.2 or higher!|r")
          DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[libdebuff] Download: https://gitea.com/avitasia/nampower/releases/tag/v2.27.2|r")
          
          -- Show popup warning
          StaticPopup_Show("LIBDEBUFF_NAMPOWER_UPDATE", versionString)
          
        else
          DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[libdebuff] Debuff tracking disabled! Please update Nampower to v2.27.2 or higher.|r")
          DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[libdebuff] Current version: |r|cffff0000[" .. versionString .. "]|r")
          DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[libdebuff] Download: https://gitea.com/avitasia/nampower/releases/tag/v2.27.2|r")
          
          -- Show popup warning
          StaticPopup_Show("LIBDEBUFF_NAMPOWER_UPDATE", versionString)
        end
      else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[libdebuff] Nampower not found! Debuff tracking disabled.|r")
        
        -- Show popup warning
        StaticPopup_Show("LIBDEBUFF_NAMPOWER_MISSING")
      end
      
      nampowerCheckFrame:SetScript("OnUpdate", nil)
    end
  end)
end)

-- ownDebuffs: [targetGUID][spellName] = {startTime, duration, texture, rank, slot}
pfUI.libdebuff_own = pfUI.libdebuff_own or {}
local ownDebuffs = pfUI.libdebuff_own

-- ownSlots: [targetGUID][slot] = spellName (for accurate slot tracking of OUR debuffs)
pfUI.libdebuff_own_slots = pfUI.libdebuff_own_slots or {}
local ownSlots = pfUI.libdebuff_own_slots

-- allSlots: [targetGUID][slot] = {spellName, casterGuid, isOurs} (for tracking ALL debuff slots)
pfUI.libdebuff_all_slots = pfUI.libdebuff_all_slots or {}
local allSlots = pfUI.libdebuff_all_slots

-- allAuraCasts: [targetGUID][spellName][casterGuid] = {startTime, duration, rank} (for other players' timers)
pfUI.libdebuff_all_auras = pfUI.libdebuff_all_auras or {}
local allAuraCasts = pfUI.libdebuff_all_auras

-- pendingCasts: [targetGUID][spellName] = {casterGuid, time} (temporary storage from SPELL_GO)
pfUI.libdebuff_pending = pfUI.libdebuff_pending or {}
local pendingCasts = pfUI.libdebuff_pending

-- Spell Icon Cache: [spellId] = texture
pfUI.libdebuff_icon_cache = pfUI.libdebuff_icon_cache or {}
local iconCache = pfUI.libdebuff_icon_cache

-- Cast Tracking: [casterGuid] = {spellID, spellName, icon, startTime, duration, endTime}
-- Shared with nameplates for cast-bar display
pfUI.libdebuff_casts = pfUI.libdebuff_casts or {}

-- Deduplication
if not lastProcessedDebuff then lastProcessedDebuff = {} end

-- Track last DEBUFF_REMOVED time per GUID for debug output
if not lastDebuffRemoved then lastDebuffRemoved = {} end

-- StaticPopup for Nampower version warning
StaticPopupDialogs["LIBDEBUFF_NAMPOWER_UPDATE"] = {
  text = "Nampower Update Required!\n\nYour current version: %s\nRequired version: 2.27.2+\n\nReason: SPELL_FAILED_OTHER bug fix needed for cast-bar cancel detection.\n\nPlease update Nampower!",
  button1 = "OK",
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  preferredIndex = 3,
  OnAccept = function()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[libdebuff]|r Download: https://gitea.com/avitasia/nampower/releases/tag/v2.27.2")
  end,
}

StaticPopupDialogs["LIBDEBUFF_NAMPOWER_MISSING"] = {
  text = "Nampower Not Found!\n\nNampower 2.27.2+ is required for pfUI Enhanced debuff tracking and cast-bar features.\n\nPlease install Nampower.",
  button1 = "OK",
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  preferredIndex = 3,
  OnAccept = function()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[libdebuff]|r Download: https://gitea.com/avitasia/nampower/releases")
  end,
}

-- Get spell icon texture (with caching for performance)
-- Uses GetSpellIconTexture (Nampower) for fast DBC lookup
function libdebuff:GetSpellIcon(spellId)
  if not spellId or type(spellId) ~= "number" or spellId <= 0 then
    return "Interface\\Icons\\INV_Misc_QuestionMark"  -- Fallback
  end
  
  -- Check cache first
  if iconCache[spellId] then
    return iconCache[spellId]
  end
  
  local texture = nil
  
  -- METHOD 1: GetSpellIconTexture (fast, requires Nampower)
  if GetSpellRecField and GetSpellIconTexture then
    local spellIconId = GetSpellRecField(spellId, "spellIconID")
    if spellIconId and type(spellIconId) == "number" and spellIconId > 0 then
      texture = GetSpellIconTexture(spellIconId)
    end
  end
  
  -- METHOD 2: Fallback to SpellInfo (slower, but works without Nampower)
  if not texture and SpellInfo then
    local _, _, spellTexture = SpellInfo(spellId)
    texture = spellTexture
  end
  
  -- Final fallback
  if not texture then
    texture = "Interface\\Icons\\INV_Misc_QuestionMark"
  end
  
  -- Cache result
  iconCache[spellId] = texture
  
  return texture
end

-- Export for external use (saves locals in other modules)
pfUI.libdebuff_GetSpellIcon = function(spellId)
  return libdebuff:GetSpellIcon(spellId)
end

-- Track recent DEBUFF_REMOVED events to suppress unnecessary rescans
pfUI.libdebuff_recent_removals = pfUI.libdebuff_recent_removals or {}
local recentRemovals = pfUI.libdebuff_recent_removals

-- Cleveroids API: [targetGUID][spellID] = {start, duration, caster, stacks}
pfUI.libdebuff_objects_guid = pfUI.libdebuff_objects_guid or {}
local objectsByGuid = pfUI.libdebuff_objects_guid

-- Combo Points Tracking
local currentComboPoints = 0
local lastSpentComboPoints = 0
local lastSpentTime = 0

-- Unique debuffs (same spell overwrites itself when cast by different player)
local uniqueDebuffs = {
  ["Hunter's Mark"] = true,
  ["Scorpid Sting"] = true,
  ["Curse of Weakness"] = true,
  ["Curse of Recklessness"] = true,
  ["Curse of the Elements"] = true,
  ["Curse of Shadow"] = true,
  ["Curse of Tongues"] = true,
  ["Curse of Idiocy"] = true,
  ["Curse of Agony"] = true,
  ["Curse of Doom"] = true,
  ["Curse of Exhaustion"] = true,
  ["Judgement of Light"] = true,
  ["Judgement of Wisdom"] = true,
  ["Judgement of Justice"] = true,
  ["Judgement of the Crusader"] = true,
  ["Shadow Vulnerability"] = true,
  ["Shadow Weaving"] = true,
  ["Stormstrike"] = true,
  ["Sunder Armor"] = true,
  ["Expose Armor"] = true,
  ["Nightfall"] = true,
  ["Improved Scorch"] = true,
  ["Winter's Chill"] = true,
}

-- Debuff pairs that overwrite each other
local debuffOverwritePairs = {
  -- Faerie Fire variants
  ["Faerie Fire"] = "Faerie Fire (Feral)",
  ["Faerie Fire (Feral)"] = "Faerie Fire",
  
  -- Demo variants
  ["Demoralizing Shout"] = "Demoralizing Roar",
  ["Demoralizing Roar"] = "Demoralizing Shout",
}

-- Self-overwrite list (same spell overwrites itself from different caster)
local selfOverwriteDebuffs = {
  ["Faerie Fire"] = true,
  ["Faerie Fire (Feral)"] = true,
  ["Demoralizing Shout"] = true,
  ["Demoralizing Roar"] = true,
}

-- Combopoint-based abilities: Only show timers for OUR casts (others = unknown duration)
local combopointAbilities = {
  ["Rip"] = true,
  ["Rupture"] = true,
  ["Kidney Shot"] = true,
  ["Slice and Dice"] = true,
  ["Expose Armor"] = true,
}

-- Duplicate event filter
local lastEventSignature = nil
local lastEventTime = 0

-- Range cleanup timer
local lastRangeCheck = 0

-- Debug Stats (for /pfui shifttest)
pfUI.libdebuff_debugstats = pfUI.libdebuff_debugstats or {
  enabled = false,
  trackAllUnits = false,  -- NEW: Track all units, not just target
  aura_cast = 0,
  debuff_added_ours = 0,
  debuff_added_other = 0,
  debuff_removed_ours = 0,
  debuff_removed_other = 0,
  shift_down = 0,
  shift_up = 0,
}
local debugStats = pfUI.libdebuff_debugstats

-- Helper function for debug: safely show last 4 chars of GUID
local function DebugGuid(guid)
  if not guid then return "nil" end
  local str = tostring(guid)
  if string.len(str) > 4 then
    return string.sub(str, -4)
  end
  return str
end

local function GetStoredComboPoints()
  if lastSpentComboPoints > 0 and (GetTime() - lastSpentTime) < 1 then
    return lastSpentComboPoints
  end
  return 0
end

-- Player GUID Cache
local playerGUID = nil
local function GetPlayerGUID()
  if not playerGUID and UnitExists then
    local _, guid = UnitExists("player")
    playerGUID = guid
  end
  return playerGUID
end

-- Helper function: Check if GUID is current target (for debug filtering)
local function IsCurrentTarget(guid)
  if debugStats.trackAllUnits then return true end  -- NEW: Track all units if enabled
  if not guid or not UnitExists then return false end
  local _, targetGuid = UnitExists("target")
  return targetGuid == guid
end

-- Helper function: Format timestamp for debug output
local function GetDebugTimestamp()
  return string.format("[%.3f]", GetTime())
end

-- Shift all slots down after a removal
local function ShiftSlotsDown(guid, removedSlot)
  -- Debug: SHIFT DOWN (disabled - too spammy)
  
  -- Shift ownSlots (only our debuffs)
  if ownSlots[guid] then
    local maxSlot = 0
    for slot in pairs(ownSlots[guid]) do
      if slot > maxSlot then maxSlot = slot end
    end
    
    for slot = removedSlot + 1, maxSlot + 1 do
      if ownSlots[guid][slot] then
        local spellName = ownSlots[guid][slot]
        ownSlots[guid][slot - 1] = spellName
        ownSlots[guid][slot] = nil
        
        if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
          ownDebuffs[guid][spellName].slot = slot - 1
        end
      end
    end
  end
  
  -- Shift allSlots (ALL debuffs from all players)
  if allSlots[guid] then
    local maxSlot = 0
    for slot in pairs(allSlots[guid]) do
      if slot > maxSlot then maxSlot = slot end
    end
    
    for slot = removedSlot + 1, maxSlot + 1 do
      if allSlots[guid][slot] then
        allSlots[guid][slot - 1] = allSlots[guid][slot]
        allSlots[guid][slot] = nil
      end
    end
  end
end

-- Validate consistency between allSlots and allAuraCasts after shifting
local function ValidateSlotConsistency(guid)
  if not debugStats.enabled or not IsCurrentTarget(guid) then return end
  
  local inconsistencies = 0
  
  if allSlots[guid] then
    for slot, slotData in pairs(allSlots[guid]) do
      local spellName = slotData.spellName
      local casterGuid = slotData.casterGuid
      
      -- Check for invalid/missing casterGuid
      if not casterGuid or casterGuid == "" or casterGuid == "0x0000000000000000" then
        inconsistencies = inconsistencies + 1
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[INCONSISTENCY]|r target=%s slot=%d %s has INVALID casterGuid=%s", 
          DebugGuid(guid), slot, spellName, tostring(casterGuid)))
      -- Check if timer data exists for non-our debuffs with valid casterGuid
      elseif not slotData.isOurs then
        if not allAuraCasts[guid] or not allAuraCasts[guid][spellName] or not allAuraCasts[guid][spellName][casterGuid] then
          inconsistencies = inconsistencies + 1
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[INCONSISTENCY]|r target=%s slot=%d %s caster=%s has no timer data in allAuraCasts", 
            DebugGuid(guid), slot, spellName, DebugGuid(casterGuid)))
        end
      end
    end
  end
  
  if inconsistencies > 0 then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[VALIDATION FAILED]|r target=%s: %d slot inconsistencies found", 
      DebugGuid(guid), inconsistencies))
  else
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[VALIDATION OK]|r target=%s: All slots consistent", DebugGuid(guid)))
  end
end

-- Shift all slots up when a new one is added
local function ShiftSlotsUp(guid, newSlot)
  if debugStats.enabled then
    debugStats.shift_up = debugStats.shift_up + 1
    if IsCurrentTarget(guid) then
      DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[SHIFT UP]|r target=%s inserting at slot %d", DebugGuid(guid), newSlot))
    end
  end
  
  -- Shift ownSlots (only our debuffs)
  if ownSlots[guid] then
    local maxSlot = 0
    for slot in pairs(ownSlots[guid]) do
      if slot > maxSlot then maxSlot = slot end
    end
    
    for slot = maxSlot, newSlot, -1 do
      if ownSlots[guid][slot] then
        local spellName = ownSlots[guid][slot]
        ownSlots[guid][slot + 1] = spellName
        ownSlots[guid][slot] = nil
        
        if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
          ownDebuffs[guid][spellName].slot = slot + 1
        end
      end
    end
  end
  
  -- Shift allSlots (ALL debuffs from all players)
  if allSlots[guid] then
    local maxSlot = 0
    for slot in pairs(allSlots[guid]) do
      if slot > maxSlot then maxSlot = slot end
    end
    
    for slot = maxSlot, newSlot, -1 do
      if allSlots[guid][slot] then
        allSlots[guid][slot + 1] = allSlots[guid][slot]
        allSlots[guid][slot] = nil
      end
    end
  end
end

-- Cleanup orphaned debuffs
local function CleanupOrphanedDebuffs(guid)
  -- Cleanup ownDebuffs
  if ownDebuffs[guid] then
    local toDelete = {}
    
    for spell, data in pairs(ownDebuffs[guid]) do
      local timeleft = (data.startTime + data.duration) - GetTime()
      local expired = timeleft < 0
      local noSlotTooLong = not data.slot and (GetTime() - data.startTime) > 2
      
      if expired or noSlotTooLong then
        if debugStats.enabled and IsCurrentTarget(guid) and noSlotTooLong then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[CLEANUP DELETED]|r %s slot=nil age=%.1fs", 
            spell, GetTime() - data.startTime))
        end
        -- Mark for deletion AFTER iteration
        table.insert(toDelete, spell)
      end
    end
    
    -- Delete AFTER iteration (prevents iterator corruption)
    for _, spell in ipairs(toDelete) do
      ownDebuffs[guid][spell] = nil
    end
  end
  
  -- Cleanup allAuraCasts (expired timers from other casters)
  if allAuraCasts[guid] then
    for spell, casterTable in pairs(allAuraCasts[guid]) do
      local castersToDelete = {}
      
      for casterGuid, data in pairs(casterTable) do
        local timeleft = (data.startTime + data.duration) - GetTime()
        if timeleft < 0 then
          -- Timer expired, mark for deletion
          table.insert(castersToDelete, casterGuid)
        end
      end
      
      -- Delete expired casters
      for _, casterGuid in ipairs(castersToDelete) do
        allAuraCasts[guid][spell][casterGuid] = nil
      end
      
      -- If no casters remain for this spell, remove the spell table
      local hasCasters = false
      for _ in pairs(allAuraCasts[guid][spell]) do
        hasCasters = true
        break
      end
      if not hasCasters then
        allAuraCasts[guid][spell] = nil
      end
    end
  end
end

-- Initial scan of all debuff slots on target change
local function InitializeTargetSlots(guid)
  if not guid or not GetUnitField or not SpellInfo then return end
  
  -- Save old slot data — needed to recover casterGuid for spells that never
  -- went through AURA_CAST (e.g. Pain Spike, Deep Wound on some servers).
  -- InitializeTargetSlots only looks up casters from allAuraCasts, which won't
  -- have entries for those spells. But DEBUFF_ADDED already filled the real caster.
  local oldSlots = allSlots[guid]
  
  -- Clear existing slots for this target
  allSlots[guid] = {}
  
  if debugStats.enabled and IsCurrentTarget(guid) then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ffff[INITIAL SCAN]|r Scanning target=%s", GetDebugTimestamp(), DebugGuid(guid)))
  end
  
  local myGuid = GetPlayerGUID()
  local slotCount = 0
  
  -- Get all auras (buffs + debuffs) for this unit
  local auras = GetUnitField(guid, "aura")
  if not auras then 
    if debugStats.enabled and IsCurrentTarget(guid) then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[INITIAL SCAN]|r GetUnitField failed!")
    end
    return 
  end
  
  -- Scan debuff slots only (aura slots 33-48)
  -- IMPORTANT: UnitDebuff() returns compacted slots (1, 2, 3... no gaps)
  -- GetUnitField returns raw aura slots which CAN have gaps (e.g. 33, 35, 36)
  -- We must use a counter here to match UnitDebuff's compacted numbering
  local debuffSlot = 0
  for auraSlot = 33, 48 do
    local spellId = auras[auraSlot]
    
    if spellId and spellId > 0 then
      -- Get spell name from ID
      local spellName = SpellInfo(spellId)
      
      if spellName and spellName ~= "" then
        slotCount = slotCount + 1
        debuffSlot = debuffSlot + 1
        
        -- Check if this is our debuff
        local isOurs = false
        local casterGuid = nil
        
        if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
          isOurs = true
          casterGuid = myGuid
          -- Update slot in ownDebuffs
          ownDebuffs[guid][spellName].slot = debuffSlot
          -- Update ownSlots
          ownSlots[guid] = ownSlots[guid] or {}
          ownSlots[guid][debuffSlot] = spellName
        else
          -- Not our debuff - try to find caster from allAuraCasts
          if allAuraCasts[guid] and allAuraCasts[guid][spellName] then
            -- Find first valid caster (there might be multiple)
            for existingCasterGuid, auraData in pairs(allAuraCasts[guid][spellName]) do
              if existingCasterGuid and existingCasterGuid ~= "" and existingCasterGuid ~= "0x0000000000000000" then
                casterGuid = existingCasterGuid
                break
              end
            end
          end
          
          -- Also check pendingCasts (from SPELL_GO) for spells without AURA_CAST
          if not casterGuid and pendingCasts[guid] and pendingCasts[guid][spellName] then
            local pending = pendingCasts[guid][spellName]
            if GetTime() - pending.time < 1 then
              casterGuid = pending.casterGuid
              if casterGuid == myGuid then
                isOurs = true
              end
            end
          end
        end
        
        -- Add to allSlots (using debuff slot numbering)
        allSlots[guid][debuffSlot] = {
          spellName = spellName,
          casterGuid = casterGuid,
          isOurs = isOurs
        }
        
        -- Merge back caster info from previous allSlots data.
        -- Spells like Pain Spike never produce AURA_CAST, so allAuraCasts has no entry.
        -- But a prior DEBUFF_ADDED may have filled the real caster — recover it.
        if casterGuid == nil and oldSlots then
          for _, oldData in pairs(oldSlots) do
            if oldData.spellName == spellName and oldData.casterGuid then
              allSlots[guid][debuffSlot].casterGuid = oldData.casterGuid
              allSlots[guid][debuffSlot].isOurs = oldData.isOurs
              casterGuid = oldData.casterGuid  -- update for the debug log below
              isOurs = oldData.isOurs
              break
            end
          end
        end
        
        if debugStats.enabled and IsCurrentTarget(guid) then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[SLOT INIT]|r slot=%d %s (ID=%d) isOurs=%s caster=%s", 
            debuffSlot, spellName, spellId, tostring(isOurs), DebugGuid(casterGuid)))
        end
      end
    end
  end
  
  if debugStats.enabled and IsCurrentTarget(guid) then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ffff[INITIAL SCAN DONE]|r Found %d debuff slots", GetDebugTimestamp(), slotCount))
  end
end

-- ============================================================================
-- TARGETED CLEANUP: Cleanup a specific GUID completely
-- ============================================================================
local function CleanupUnit(guid)
  if not guid then return false end
  
  local cleaned = false
  
  -- Remove from all tracking tables
  if ownDebuffs[guid] then
    ownDebuffs[guid] = nil
    cleaned = true
  end
  
  if ownSlots[guid] then
    ownSlots[guid] = nil
    cleaned = true
  end
  
  if allSlots[guid] then
    allSlots[guid] = nil
    cleaned = true
  end
  
  if allAuraCasts[guid] then
    allAuraCasts[guid] = nil
    cleaned = true
  end
  
  if objectsByGuid[guid] then
    objectsByGuid[guid] = nil
    cleaned = true
  end
  
  if pendingCasts[guid] then
    pendingCasts[guid] = nil
    cleaned = true
  end
  
  -- Debug output
  if debugStats.enabled and cleaned and IsCurrentTarget(guid) then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[CLEANUP UNIT]|r Cleaned up all data for GUID %s", DebugGuid(guid)))
  end
  
  return cleaned
end

-- Cleanup old pending casts (older than 1 second)
local function CleanupPendingCasts()
  local now = GetTime()
  for guid, spells in pairs(pendingCasts) do
    for spell, data in pairs(spells) do
      if now - data.time > 1 then
        pendingCasts[guid][spell] = nil
      end
    end
    -- Clean empty guid entries
    local isEmpty = true
    for _ in pairs(pendingCasts[guid]) do
      isEmpty = false
      break
    end
    if isEmpty then
      pendingCasts[guid] = nil
    end
  end
end

-- Speichert die Ranks der zuletzt gecasteten Spells (bleibt länger als pending)
pfUI.libdebuff_lastranks = pfUI.libdebuff_lastranks or {}
local lastCastRanks = pfUI.libdebuff_lastranks

-- Speichert Spells die gefailed sind (miss/dodge/parry/etc.) für 1 Sekunde
pfUI.libdebuff_lastfailed = pfUI.libdebuff_lastfailed or {}
local lastFailedSpells = pfUI.libdebuff_lastfailed

-- ============================================================================
-- PERIODIC CLEANUP: Check all units every 10s (fallback for missed events)
-- ============================================================================
local function CleanupOutOfRangeUnits()
  local now = GetTime()
  if now - lastRangeCheck < 10 then return end  -- Reduced from 30s to 10s
  lastRangeCheck = now
  
  -- Build set of all GUIDs across all tables
  local allGuids = {}
  for guid in pairs(ownDebuffs) do allGuids[guid] = true end
  for guid in pairs(ownSlots) do allGuids[guid] = true end
  for guid in pairs(allSlots) do allGuids[guid] = true end
  for guid in pairs(allAuraCasts) do allGuids[guid] = true end
  for guid in pairs(objectsByGuid) do allGuids[guid] = true end
  for guid in pairs(pendingCasts) do allGuids[guid] = true end
  
  local cleanedCount = 0
  
  -- Check each GUID
  for guid in pairs(allGuids) do
    local exists = UnitExists and UnitExists(guid)
    local isDead = UnitIsDead and UnitIsDead(guid)
    
    -- Cleanup if:
    -- 1. Unit doesn't exist anymore (despawned/out of range)
    -- 2. OR unit is dead (fallback in case UNIT_HEALTH event was missed)
    if not exists or isDead then
      if CleanupUnit(guid) then
        cleanedCount = cleanedCount + 1
      end
    end
  end
  
  if debugStats.enabled and cleanedCount > 0 and false then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[PERIODIC CLEANUP]|r Cleaned %d units (dead or out of range)", cleanedCount))
  end
  
  -- Cleanup old lastCastRanks entries (older than 3 seconds)
  for spell, data in pairs(lastCastRanks) do
    if now - data.time > 3 then
      lastCastRanks[spell] = nil
    end
  end
  
  -- Cleanup old lastFailedSpells entries (older than 2 seconds)
  for spell, data in pairs(lastFailedSpells) do
    if now - data.time > 2 then
      lastFailedSpells[spell] = nil
    end
  end
  
  -- Cleanup old pendingCasts (integrated here for efficiency)
  for guid, spells in pairs(pendingCasts) do
    for spell, data in pairs(spells) do
      if now - data.time > 1 then
        pendingCasts[guid][spell] = nil
      end
    end
    -- Clean empty guid entries
    local isEmpty = true
    for _ in pairs(pendingCasts[guid]) do
      isEmpty = false
      break
    end
    if isEmpty then
      pendingCasts[guid] = nil
    end
  end
end

-- Prüft ob ein Spell kürzlich gefailed ist (öffentliche Funktion für andere Module)
function libdebuff:DidSpellFail(spell)
  if not spell then return false end
  local data = lastFailedSpells[spell]
  if data and (GetTime() - data.time) < 1 then
    return true
  end
  return false
end

-- Shared Debuffs: Diese werden von allen Spielern geteilt (nur einer kann drauf sein)
-- Timer darf von anderen Spielern aktualisiert werden
local sharedDebuffs = {
  -- Warrior
  ["Sunder Armor"] = true,
  ["Demoralizing Shout"] = true,
  ["Thunder Clap"] = true,
  
  -- Rogue
  ["Expose Armor"] = true,
  
  -- Druid
  ["Faerie Fire"] = true,
  ["Faerie Fire (Feral)"] = true,
  
  -- Hunter
  ["Hunter's Mark"] = true,
  
  -- Warlock Curses (nur eine pro Typ kann auf Target sein)
  ["Curse of Weakness"] = true,
  ["Curse of Recklessness"] = true,
  ["Curse of the Elements"] = true,
  ["Curse of Shadow"] = true,
  ["Curse of Tongues"] = true,
  ["Curse of Exhaustion"] = true,
  -- NICHT: Curse of Agony, Curse of Doom (jeder Warlock hat seinen eigenen!)
  
  -- Priest
  ["Shadow Weaving"] = true,
  
  -- Mage
  ["Winter's Chill"] = true,
  
  -- Paladin Judgements
  ["Judgement of Wisdom"] = true,
  ["Judgement of Light"] = true,
  ["Judgement of the Crusader"] = true,
  ["Judgement of Justice"] = true,
}

function libdebuff:GetDuration(effect, rank)
  if L["debuffs"][effect] then
    local rank = rank and tonumber((string.gsub(rank, RANK, ""))) or 0
    local rank = L["debuffs"][effect][rank] and rank or libdebuff:GetMaxRank(effect)
    local duration = L["debuffs"][effect][rank]

    if effect == L["dyndebuffs"]["Rupture"] then
      -- Rupture: +2 sec per combo point
      local cp = GetComboPoints() or 0
      if cp == 0 then cp = GetStoredComboPoints() end
      duration = duration + cp*2
    elseif effect == L["dyndebuffs"]["Kidney Shot"] then
      -- Kidney Shot: +1 sec per combo point
      local cp = GetComboPoints() or 0
      if cp == 0 then cp = GetStoredComboPoints() end
      duration = duration + cp*1
    elseif effect == "Rip" or effect == L["dyndebuffs"]["Rip"] then
      -- Rip (Turtle WoW): 10s base + 2s per additional combo point
      -- Base in table is 8, so: 8 + CP*2 = 10/12/14/16/18
      local cp = GetComboPoints() or 0
      if cp == 0 then cp = GetStoredComboPoints() end
      duration = 8 + cp*2
    elseif effect == L["dyndebuffs"]["Demoralizing Shout"] then
      -- Booming Voice: 10% per talent
      local _,_,_,_,count = GetTalentInfo(2,1)
      if count and count > 0 then duration = duration + ( duration / 100 * (count*10)) end
    elseif effect == L["dyndebuffs"]["Shadow Word: Pain"] then
      -- Improved Shadow Word: Pain: +3s per talent
      local _,_,_,_,count = GetTalentInfo(3,4)
      if count and count > 0 then duration = duration + count * 3 end
    elseif effect == L["dyndebuffs"]["Frostbolt"] then
      -- Permafrost: +1s per talent
      local _,_,_,_,count = GetTalentInfo(3,7)
      if count and count > 0 then duration = duration + count end
    elseif effect == L["dyndebuffs"]["Gouge"] then
      -- Improved Gouge: +.5s per talent
      local _,_,_,_,count = GetTalentInfo(3,3)
      if count and count > 0 then duration = duration + (count*.5) end
    end
    return duration
  else
    return 0
  end
end

function libdebuff:UpdateDuration(unit, unitlevel, effect, duration)
  if not unit or not effect or not duration then return end
  unitlevel = unitlevel or 0

  if libdebuff.objects[unit] and libdebuff.objects[unit][unitlevel] and libdebuff.objects[unit][unitlevel][effect] then
    libdebuff.objects[unit][unitlevel][effect].duration = duration
  end
end

function libdebuff:GetMaxRank(effect)
  local max = 0
  for id in pairs(L["debuffs"][effect]) do
    if id > max then max = id end
  end
  return max
end

function libdebuff:UpdateUnits()
  if not pfUI.uf or not pfUI.uf.target then return end
  pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
end

function libdebuff:AddPending(unit, unitlevel, effect, duration, caster, rank)
  if not unit or duration <= 0 then return end
  if not L["debuffs"][effect] then return end
  if libdebuff.pending[3] then return end

  libdebuff.pending[1] = unit
  libdebuff.pending[2] = unitlevel or 0
  libdebuff.pending[3] = effect
  libdebuff.pending[4] = duration
  libdebuff.pending[5] = caster
  libdebuff.pending[6] = rank

  QueueFunction(libdebuff.PersistPending)
end

function libdebuff:RemovePending()
  libdebuff.pending[1] = nil
  libdebuff.pending[2] = nil
  libdebuff.pending[3] = nil
  libdebuff.pending[4] = nil
  libdebuff.pending[5] = nil
  libdebuff.pending[6] = nil
end

function libdebuff:PersistPending(effect)
  if not libdebuff.pending[3] then return end

  if libdebuff.pending[3] == effect or ( effect == nil and libdebuff.pending[3] ) then
    local p1, p2, p3, p4, p5, p6 = libdebuff.pending[1], libdebuff.pending[2], libdebuff.pending[3], libdebuff.pending[4], libdebuff.pending[5], libdebuff.pending[6]
    libdebuff.AddEffect(libdebuff, p1, p2, p3, p4, p5, p6)
  end

  libdebuff:RemovePending()
end

function libdebuff:RevertLastAction()
  if lastspell and lastspell.effect then
  end
  lastspell.start = lastspell.start_old
  lastspell.start_old = nil
  libdebuff:UpdateUnits()
end

function libdebuff:AddEffect(unit, unitlevel, effect, duration, caster, rank)
  -- WORKAROUND: Wenn rank nil ist und wir einen eigenen Cast haben, hole rank aus lastCastRanks
  if not rank and caster == "player" and effect then
    -- Erst aus pending versuchen
    if libdebuff.pending[3] == effect and libdebuff.pending[6] then
      rank = libdebuff.pending[6]
    -- Dann aus lastCastRanks (bleibt länger)
    elseif lastCastRanks[effect] and (GetTime() - lastCastRanks[effect].time) < 2 then
      rank = lastCastRanks[effect].rank
    end
  end
  
  if not unit or not effect then return end
  
  -- SCHUTZ: Wenn der Spell gerade gefailed ist (miss/dodge/parry/etc.), nicht anwenden
  -- Nur für eigene Spells prüfen, nicht für andere Spieler
  if caster == "player" and libdebuff:DidSpellFail(effect) then
    return  -- Spell hat nicht getroffen, keinen Timer setzen
  end
  
  unitlevel = unitlevel or 0
  if not libdebuff.objects[unit] then libdebuff.objects[unit] = {} end
  if not libdebuff.objects[unit][unitlevel] then libdebuff.objects[unit][unitlevel] = {} end
  if not libdebuff.objects[unit][unitlevel][effect] then libdebuff.objects[unit][unitlevel][effect] = {} end

  local existing = libdebuff.objects[unit][unitlevel][effect]
  local now = GetTime()
  
  -- Wenn kein Caster übergeben wurde, behalte den existierenden (wichtig für Refresh-Mechaniken wie Ferocious Bite)
  if not caster and existing.caster then
    caster = existing.caster
  end
  
  -- Wenn kein Rank übergeben wurde, behalte den existierenden
  if not rank and existing.rank then
    rank = existing.rank
  end
  
  -- Prüfe ob ein existierender Debuff noch aktiv ist
  local existingIsActive = existing.start and existing.duration and (existing.start + existing.duration) > now
  
  -- SCHUTZ: Wenn MEIN Debuff aktiv ist, darf ein anderer Spieler ihn NICHT überschreiben
  -- AUSNAHME: Shared Debuffs (Sunder Armor, Curses, etc.) dürfen aktualisiert werden
  if existingIsActive and existing.caster == "player" and caster ~= "player" then
    if not sharedDebuffs[effect] then
      return  -- Blockiere das Update
    end
  end
  
  -- Rank-Prüfung wenn beide vom Player sind und beide Ranks bekannt sind
  if existingIsActive and existing.rank and rank and existing.caster == "player" and caster == "player" then
    -- Niedrigerer Rank darf höheren NICHT überschreiben
    if rank < existing.rank then
      return  -- Blockiere das Update
    end
    -- Gleicher oder höherer Rank darf überschreiben (Timer erneuern)
  end

  -- save current effect as lastspell
  lastspell = existing

  existing.effect = effect
  existing.start_old = existing.start
  existing.start = now
  existing.duration = duration or libdebuff:GetDuration(effect)
  existing.caster = caster
  existing.rank = rank

  libdebuff:UpdateUnits()
end

-- scan for debuff application
libdebuff:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
libdebuff:RegisterEvent("PLAYER_TARGET_CHANGED")
libdebuff:RegisterEvent("PLAYER_LOGOUT")
libdebuff:RegisterEvent("SPELLCAST_STOP")
libdebuff:RegisterEvent("UNIT_AURA")

-- register seal handler
if class == "PALADIN" then
  libdebuff:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
end

-- Remove Pending
libdebuff.rp = { SPELLIMMUNESELFOTHER, IMMUNEDAMAGECLASSSELFOTHER,
  SPELLMISSSELFOTHER, SPELLRESISTSELFOTHER, SPELLEVADEDSELFOTHER,
  SPELLDODGEDSELFOTHER, SPELLDEFLECTEDSELFOTHER, SPELLREFLECTSELFOTHER,
  SPELLPARRIEDSELFOTHER, SPELLLOGABSORBSELFOTHER, SPELLFAILCASTSELF }

libdebuff.objects = {}
libdebuff.pending = {}

-- Gather Data by Events
libdebuff:SetScript("OnEvent", function()
  -- Stop event handling during logout to prevent crash 132
  if event == "PLAYER_LOGOUT" then
    this:UnregisterAllEvents()
    this:SetScript("OnEvent", nil)
    return
    
  -- paladin seal refresh
  elseif event == "CHAT_MSG_COMBAT_SELF_HITS" then
    local hit = cmatch(arg1, COMBATHITSELFOTHER)
    local crit = cmatch(arg1, COMBATHITCRITSELFOTHER)
    if hit or crit then
      for seal in L["judgements"] do
        local name = UnitName("target")
        local level = UnitLevel("target")
        if name and libdebuff.objects[name] then
          if level and libdebuff.objects[name][level] and libdebuff.objects[name][level][seal] then
            libdebuff:AddEffect(name, level, seal)
          elseif libdebuff.objects[name][0] and libdebuff.objects[name][0][seal] then
            libdebuff:AddEffect(name, 0, seal)
          end
        end
      end
    end

  -- Add Combat Log
  elseif event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE" or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
    local unit, effect = cmatch(arg1, AURAADDEDOTHERHARMFUL)
    if unit and effect then
      local unitlevel = UnitName("target") == unit and UnitLevel("target") or 0
      if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
        libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)  -- Explizit nil für rank
      end
    end

  -- Add Missing Buffs by Iteration (legacy target frame support)
  elseif event == "PLAYER_TARGET_CHANGED" then
    if not UnitExists("target") then return end
    
    local unit = UnitName("target")
    local unitlevel = UnitLevel("target") or 0
    
    -- Use GetUnitField if available (faster, gets all 48 slots at once)
    if GetUnitField and SpellInfo then
      local auras = GetUnitField("target", "aura")
      if auras then
        -- Debuff slots are 33-48 in the aura array
        for auraSlot = 33, 48 do
          local spellId = auras[auraSlot]
          if spellId and spellId > 0 then
            local spellName = SpellInfo(spellId)
            if spellName and spellName ~= "" then
              -- Don't overwrite existing timers
              if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][spellName] then
                libdebuff:AddEffect(unit, unitlevel, spellName, nil, nil, nil)
              end
            end
          end
        end
      end
    else
      -- Fallback: Use UnitDebuff API (slower, only slots 1-16)
      for i=1, 16 do
        local effect, rank, texture = libdebuff:UnitDebuff("target", i)
        if not texture then break end
        if texture and effect and effect ~= "" then
          if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
            libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)
          end
        end
      end
    end

  -- Update Pending Spells und tracke failed spells
  elseif event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" or event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
    -- Prüfe ob ein Spell gefailed ist und speichere ihn
    for _, msg in pairs(libdebuff.rp) do
      local effect = cmatch(arg1, msg)
      if effect then
        -- Speichere den failed spell für 1 Sekunde
        lastFailedSpells[effect] = { time = GetTime() }
        
        -- Bestehende Logik: Remove pending spell
        if libdebuff.pending[3] == effect then
          libdebuff:RemovePending()
          return
        elseif lastspell and lastspell.start_old and lastspell.effect == effect then
          -- late removal of debuffs (e.g hunter arrows as they hit late)
          libdebuff:RevertLastAction()
          return
        end
      end
    end
  elseif event == "SPELLCAST_STOP" then
    libdebuff:PersistPending()
  end
end)

-- Gather Data by User Actions
hooksecurefunc("CastSpell", function(id, bookType)
  local rawEffect, rank = libspell.GetSpellInfo(id, bookType)
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = num and tonumber(num) or 0
  end
  
  -- Speichere rank für später (bleibt 2 Sekunden)
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

hooksecurefunc("CastSpellByName", function(effect, target)
  local rawEffect, rank = libspell.GetSpellInfo(effect)
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = num and tonumber(num) or 0
  end
  
  -- Speichere rank für später (bleibt 2 Sekunden)
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

hooksecurefunc("UseAction", function(slot, target, button)
  if GetActionText(slot) or not IsCurrentAction(slot) then return end
  scanner:SetAction(slot)
  local rawEffect, rank = scanner:Line(1)
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = num and tonumber(num) or 0
  end
  
  -- Speichere rank für später (bleibt 2 Sekunden)
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

-- Debug throttle for UnitDebuff (to avoid spam)
pfUI.libdebuff_lastlog = pfUI.libdebuff_lastlog or {}
local lastUnitDebuffLog = pfUI.libdebuff_lastlog
local UNITDEBUFF_LOG_THROTTLE = 5 -- seconds

-- Throttle for missing-slot rescans (per guid, max once per second)
local lastRescanTime = {}
local RESCAN_THROTTLE = 1 -- seconds

function libdebuff:UnitDebuff(unit, id)
  local unitname = UnitName(unit)
  local unitlevel = UnitLevel(unit)
  local texture, stacks, dtype
  local spellId = nil
  local duration, timeleft = nil, -1
  local rank = nil -- no backport
  local caster = nil -- experimental
  local effect

  -- OPTIMIZED: Use GetUnitField to get spellID directly (Nampower)
  if GetUnitField then
    -- Debuff slots: 1-16 map to aura array indices 33-48
    local auraSlot = 32 + id
    
    -- Get spell ID from aura array
    local auras = GetUnitField(unit, "aura")
    if auras and auras[auraSlot] and auras[auraSlot] > 0 then
      spellId = auras[auraSlot]
      
      -- Get texture via optimized GetSpellIcon (uses GetSpellIconTexture with caching)
      texture = libdebuff:GetSpellIcon(spellId)
      
      -- Get stack count from auraApplications array
      local applications = GetUnitField(unit, "auraApplications")
      stacks = (applications and applications[auraSlot]) or 1
      
      -- Get spell name via SpellInfo
      if SpellInfo then
        effect = SpellInfo(spellId)
      end
      
      -- dtype (debuff type) - we don't have this from GetUnitField
      -- Leave as nil for now (not critical, mainly for dispel checks)
      dtype = nil
    end
  end
  
  -- FALLBACK: Use vanilla UnitDebuff API if GetUnitField failed or not available
  if not texture then
    texture, stacks, dtype = UnitDebuff(unit, id)
    
    if texture then
      scanner:SetUnitDebuff(unit, id)
      effect = scanner:Line(1) or ""
    end
  end

  -- Nampower: Check slots with allSlots
  if hasNampower and UnitExists and effect then
    local _, guid = UnitExists(unit)
    
    -- EMERGENCY SCAN: If allSlots is empty but debuff exists, trigger scan
    if guid and not allSlots[guid] and GetUnitField and SpellInfo then
      if debugStats.enabled and IsCurrentTarget(guid) then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[EMERGENCY SCAN]|r allSlots empty for %s but debuff exists - triggering scan", DebugGuid(guid)))
      end
      InitializeTargetSlots(guid)
    end
    
    if guid and allSlots[guid] and allSlots[guid][id] then
      local slotData = allSlots[guid][id]
      local spellName = slotData.spellName
      local isOurs = slotData.isOurs
      
      -- Debug throttle: only log every 5s OR if caster changed
      local logKey = guid .. "_" .. id
      local now = GetTime()
      local shouldLog = false
      
      if debugStats.enabled and IsCurrentTarget(guid) then
        if not lastUnitDebuffLog[logKey] then
          shouldLog = true
        elseif (now - lastUnitDebuffLog[logKey].time) > UNITDEBUFF_LOG_THROTTLE then
          shouldLog = true
        elseif lastUnitDebuffLog[logKey].caster ~= slotData.casterGuid then
          shouldLog = true -- Caster changed!
          DEFAULT_CHAT_FRAME:AddMessage("|cffff00ff[CASTER CHANGED]|r")
        end
        
        if shouldLog then
          lastUnitDebuffLog[logKey] = {time = now, caster = slotData.casterGuid}
          DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ffff[UNITDEBUFF READ]|r slot=%d %s target=%s caster=%s isOurs=%s", 
            GetDebugTimestamp(), id, spellName, DebugGuid(guid), DebugGuid(slotData.casterGuid), tostring(isOurs)))
          
          -- Show timer values too (only when throttle allows)
          if duration and duration > 0 then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ff00[TIMER]|r slot=%d %s duration=%.1fs timeleft=%.1fs", 
              GetDebugTimestamp(), id, spellName, duration, timeleft))
          end
        end
      end
      
      -- Verify spell name matches (safety check)
      -- Smart approach: Only trigger cleanup if the mismatch is due to a MISSING event
      -- (i.e., debuff expired but DEBUFF_REMOVED never fired)
      if spellName ~= effect then
        -- MISMATCH detected!
        -- Check if the debuff in allSlots has expired (missing DEBUFF_REMOVED event)
        
        local shouldCleanup = false
        local expiredSpellName = nil
        
        if allSlots[guid][id] then
          local slotData = allSlots[guid][id]
          local slotSpellName = slotData.spellName
          local slotCasterGuid = slotData.casterGuid
          local slotIsOurs = slotData.isOurs
          
          -- Check if this debuff has expired
          local timeleft = nil
          
          if slotIsOurs and ownDebuffs[guid] and ownDebuffs[guid][slotSpellName] then
            local data = ownDebuffs[guid][slotSpellName]
            timeleft = (data.startTime + data.duration) - GetTime()
          elseif not slotIsOurs and slotCasterGuid and allAuraCasts[guid] and allAuraCasts[guid][slotSpellName] and allAuraCasts[guid][slotSpellName][slotCasterGuid] then
            local data = allAuraCasts[guid][slotSpellName][slotCasterGuid]
            timeleft = (data.startTime + data.duration) - GetTime()
          end
          
          -- If expired for more than 0.5s, the DEBUFF_REMOVED event is missing
          if timeleft and timeleft < -0.5 then
            shouldCleanup = true
            expiredSpellName = slotSpellName
          end
        end
        
        if shouldCleanup then
          -- MISSING EVENT detected - force cleanup
          if debugStats.enabled and IsCurrentTarget(guid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[MISSING DEBUFF_REMOVED]|r slot=%d %s expired but event never fired - forcing cleanup", 
              id, expiredSpellName))
          end
          
          -- Simulate the missing event
          local slotData = allSlots[guid][id]
          local slotIsOurs = slotData.isOurs
          
          allSlots[guid][id] = nil
          if slotIsOurs then
            if ownSlots[guid] then ownSlots[guid][id] = nil end
            if ownDebuffs[guid] then ownDebuffs[guid][expiredSpellName] = nil end
          end
          
          -- Shift slots
          ShiftSlotsDown(guid, id)
          
          -- Retry
          if allSlots[guid] and allSlots[guid][id] then
            slotData = allSlots[guid][id]
            spellName = slotData.spellName
            isOurs = slotData.isOurs
            
            if debugStats.enabled and IsCurrentTarget(guid) then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[CLEANUP OK]|r slot=%d now shows '%s'", id, spellName))
            end
          end
        else
          -- Transient mismatch - DEBUFF_REMOVED event is pending
          -- This is normal during the brief window between client-side removal
          -- and server event arrival - just return nil and wait
          -- (No logging needed - this happens all the time and is expected)
          return nil
        end
      end
      
      if spellName == effect then
        if isOurs then
          -- This slot is OURS - show our timer
          if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
            local data = ownDebuffs[guid][spellName]
            local remaining = (data.startTime + data.duration) - GetTime()
            if remaining > 0 then
              duration = data.duration
              timeleft = remaining
              caster = "player"
              rank = data.rank
            else
              -- Cleanup expired
              ownDebuffs[guid][spellName] = nil
            end
          else
            -- FALLBACK: ownDebuffs is empty (e.g. cleaned up while on other target)
            -- Check allAuraCasts as backup (using our GUID)
            local myGuid = GetPlayerGUID()
            if myGuid and allAuraCasts[guid] and allAuraCasts[guid][spellName] and allAuraCasts[guid][spellName][myGuid] then
              local data = allAuraCasts[guid][spellName][myGuid]
              local remaining = (data.startTime + data.duration) - GetTime()
              if remaining > 0 and data.duration > 0 and remaining <= data.duration then
                duration = data.duration
                timeleft = remaining
                caster = "player"
                rank = data.rank
              else
                -- Cleanup expired
                if remaining <= 0 then
                  allAuraCasts[guid][spellName][myGuid] = nil
                end
              end
            end
          end
        else
          -- This slot is from another player - show their timer if available
          local otherCasterGuid = slotData.casterGuid
          
          -- DEFENSIVE CHECK: Only show timer if casterGuid is valid
          if otherCasterGuid and otherCasterGuid ~= "" and otherCasterGuid ~= "0x0000000000000000" then
            if allAuraCasts[guid] and allAuraCasts[guid][spellName] and allAuraCasts[guid][spellName][otherCasterGuid] then
              local data = allAuraCasts[guid][spellName][otherCasterGuid]
              local remaining = (data.startTime + data.duration) - GetTime()
              -- Only show timer if duration is known (not 0) and remaining time is valid
              if remaining > 0 and data.duration > 0 and remaining <= data.duration then
                duration = data.duration
                timeleft = remaining
                caster = "other"
                rank = data.rank
              else
                -- Cleanup expired timer (FIX #1)
                if remaining <= 0 then
                  allAuraCasts[guid][spellName][otherCasterGuid] = nil
                end
              end
              if debugStats.enabled and shouldLog and remaining > data.duration then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[INVALID TIMER]|r %s remaining=%.1f > duration=%.1f", 
                  spellName, remaining, data.duration))
              end
            elseif debugStats.enabled and shouldLog then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[CASTER NOT IN ALLAURACASTS]|r %s caster=%s", 
                spellName, DebugGuid(otherCasterGuid)))
            end
          elseif allAuraCasts[guid] and allAuraCasts[guid][spellName] then
            -- FALLBACK (FIX #4): casterGuid is nil/invalid - search through ALL casters
            for anyCasterGuid, data in pairs(allAuraCasts[guid][spellName]) do
              if anyCasterGuid and anyCasterGuid ~= "" and anyCasterGuid ~= "0x0000000000000000" then
                local remaining = (data.startTime + data.duration) - GetTime()
                if remaining > 0 and data.duration > 0 and remaining <= data.duration then
                  duration = data.duration
                  timeleft = remaining
                  caster = (anyCasterGuid == GetPlayerGUID()) and "player" or "other"
                  rank = data.rank
                  break  -- Use first valid timer found
                else
                  -- Cleanup expired
                  if remaining <= 0 then
                    allAuraCasts[guid][spellName][anyCasterGuid] = nil
                  end
                end
              end
            end
          elseif debugStats.enabled and shouldLog then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[INVALID CASTERGUID]|r slot=%d %s caster=%s", 
              id, spellName, DebugGuid(otherCasterGuid)))
          end
        end
      end
      -- Found timer data in allSlots - return early
      return effect, rank, texture, stacks, dtype, duration, timeleft, caster
    else
      -- allSlots exists but this slot is missing — trigger a throttled rescan
      -- (happens when debuff was pre-existing before target acquired, DEBUFF_ADDED never fired)
      if guid and GetUnitField and SpellInfo then
        local now = GetTime()
        if not lastRescanTime[guid] or (now - lastRescanTime[guid]) > RESCAN_THROTTLE then
          lastRescanTime[guid] = now
          if debugStats.enabled and IsCurrentTarget(guid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[ALLSLOTS MISSING]|r slot=%d effect=%s - triggering rescan", id, tostring(effect)))
          end
          InitializeTargetSlots(guid)
        end
      end
      -- If allSlots exists, don't fall back to libdebuff.objects
      -- (prevents showing stale slot data after WoW doesn't auto-shift slots)
      return nil
    end
  end

  -- read level based debuff table (ONLY if allSlots doesn't exist)
  local data = libdebuff.objects[unitname] and libdebuff.objects[unitname][unitlevel]
  data = data or libdebuff.objects[unitname] and libdebuff.objects[unitname][0]

  if data and data[effect] then
    if data[effect].duration and data[effect].start and data[effect].duration + data[effect].start > GetTime() then
      -- read valid debuff data
      duration = data[effect].duration
      timeleft = duration + data[effect].start - GetTime()
      caster = data[effect].caster
    else
      -- clean up invalid values
      data[effect] = nil
    end
  end

  -- Safety: Vanilla only has 16 debuff slots (aura slots 33-48)
  -- If someone requests slot > 16, return nil
  if id > 16 then
    return nil
  end

  return effect, rank, texture, stacks, dtype, duration, timeleft, caster
end

pfUI.libdebuff_cache = pfUI.libdebuff_cache or {}
local cache = pfUI.libdebuff_cache
function libdebuff:UnitOwnDebuff(unit, id)
  -- Mit Nampower: Direkt aus ownDebuffs lesen
  if hasNampower and UnitExists then
    local _, guid = UnitExists(unit)
    if guid and ownDebuffs[guid] then
      for k in pairs(cache) do cache[k] = nil end
      
      local count = 1
      local toDelete = {}
      
      for spellName, data in pairs(ownDebuffs[guid]) do
        local timeleft = (data.startTime + data.duration) - GetTime()
        
        -- Grace period: keep debuff visible for 1s after expiry to prevent flicker
        -- IMMUNITY CHECK: Only show if slot is set (confirmed by DEBUFF_ADDED_OTHER)
        -- This prevents showing timers for spells like Rake where the bleed is immune
        -- (AURA_CAST fires but DEBUFF_ADDED never fires = slot stays nil)
        if data.slot and timeleft > -1 then
          cache[spellName] = true
          if count == id then
            local texture = data.texture or "Interface\\Icons\\INV_Misc_QuestionMark"
            -- Return 0 for timeleft if expired, but keep it in the list
            local displayTimeleft = timeleft > 0 and timeleft or 0
            return spellName, data.rank, texture, 1, nil, data.duration, displayTimeleft, "player"
          end
          count = count + 1
        else
          -- Mark for deletion AFTER iteration (prevents iterator corruption)
          table.insert(toDelete, spellName)
        end
      end
      
      -- Delete expired entries AFTER iteration
      for _, spellName in ipairs(toDelete) do
        ownDebuffs[guid][spellName] = nil
      end
    end
    return nil
  end
  
  -- Fallback: Normale UnitDebuff Methode
  for k in pairs(cache) do cache[k] = nil end
  local count = 1
  for i=1,16 do
    local effect, rank, texture, stacks, dtype, duration, timeleft, caster = libdebuff:UnitDebuff(unit, i)
    if effect and not cache[effect] and caster and caster == "player" then
      cache[effect] = true
      if count == id then
        return effect, rank, texture, stacks, dtype, duration, timeleft, caster
      else
        count = count + 1
      end
    end
  end
end

-- Nampower Integration
if hasNampower then
  -- Carnage Talent Rank
  local carnageRank = 0
  local function UpdateCarnageRank()
    if class ~= "DRUID" then return end
    local _, _, _, _, rank = GetTalentInfo(2, 17)
    carnageRank = rank or 0
  end
  
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  frame:RegisterEvent("PLAYER_COMBO_POINTS")
  frame:RegisterEvent("PLAYER_TALENT_UPDATE")
  frame:RegisterEvent("PLAYER_LOGOUT")
  frame:RegisterEvent("SPELL_START_SELF")
  frame:RegisterEvent("SPELL_START_OTHER")
  frame:RegisterEvent("SPELL_GO_SELF")
  frame:RegisterEvent("SPELL_GO_OTHER")
  frame:RegisterEvent("SPELL_FAILED_OTHER")
  frame:RegisterEvent("AURA_CAST_ON_SELF")
  frame:RegisterEvent("AURA_CAST_ON_OTHER")
  frame:RegisterEvent("DEBUFF_ADDED_OTHER")
  frame:RegisterEvent("DEBUFF_REMOVED_OTHER")
  frame:RegisterEvent("PLAYER_TARGET_CHANGED")
  frame:RegisterEvent("UNIT_HEALTH")  -- For instant cleanup when units die
  
  frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGOUT" then
      -- Stop event handling to prevent crash 132 during logout
      -- (UnitExists calls during logout can crash with UnitXP)
      this:UnregisterAllEvents()
      this:SetScript("OnEvent", nil)
      return
      
    elseif event == "PLAYER_ENTERING_WORLD" then
      GetPlayerGUID()
      UpdateCarnageRank()
      
    elseif event == "PLAYER_TALENT_UPDATE" then
      UpdateCarnageRank()
      
    elseif event == "PLAYER_COMBO_POINTS" then
      -- Track combo points for Druid AND Rogue (both use CP-based abilities)
      if class ~= "DRUID" and class ~= "ROGUE" then return end
      local current = GetComboPoints("player", "target") or 0
      if current < currentComboPoints then
        lastSpentComboPoints = currentComboPoints
        lastSpentTime = GetTime()
      end
      currentComboPoints = current
      
    elseif event == "UNIT_HEALTH" then
      -- Instant cleanup when unit dies (proactive cleanup)
      local guid = arg1
      
      if guid and UnitIsDead and UnitIsDead(guid) then
        -- Unit just died - do targeted cleanup for this GUID
        CleanupUnit(guid)
      end
      
    elseif event == "SPELL_GO_SELF" or event == "SPELL_GO_OTHER" then
      local spellId = arg2
      local casterGuid = arg3
      local targetGuid = arg4
      local numHit = arg6 or 0
      local numMissed = arg7 or 0
      
      local spellName = GetSpellRecField(spellId, "name")
      if not spellName then return end
      
      -- Spell missed - clear pending so no timer gets set
      if numHit == 0 and numMissed > 0 then
        if targetGuid and pendingCasts[targetGuid] then
          pendingCasts[targetGuid][spellName] = nil
        end
        return
      end
      
      -- Spell hit - do refresh logic for OWN debuffs
      local myGuid = GetPlayerGUID()
      local isOurs = (casterGuid == myGuid)
      
      -- Get cast rank from DBC (faster than SpellInfo)
      local castRank = 0
      local spellRankString = GetSpellRecField(spellId, "rank")
      if spellRankString and spellRankString ~= "" then
        castRank = tonumber((string.gsub(spellRankString, "Rank ", ""))) or 0
      end
      
      if isOurs and targetGuid and ownDebuffs[targetGuid] and ownDebuffs[targetGuid][spellName] then
        local existingData = ownDebuffs[targetGuid][spellName]
        local timeleft = (existingData.startTime + existingData.duration) - GetTime()
        
        -- Get existing rank
        local existingRank = 0
        if type(existingData.rank) == "number" then
          existingRank = existingData.rank
        elseif type(existingData.rank) == "string" and existingData.rank ~= "" then
          existingRank = tonumber((string.gsub(existingData.rank, "Rank ", ""))) or 0
        end
        
        if timeleft > 0 then
          -- Rank check: lower rank cannot refresh higher rank
          if castRank > 0 and castRank < existingRank then
          else
            ownDebuffs[targetGuid][spellName].startTime = GetTime()
            
            -- Force UI refresh
            if pfUI and pfUI.uf and pfUI.uf.target and UnitExists then
              local _, currentTargetGuid = UnitExists("target")
              if currentTargetGuid == targetGuid then
                pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
              end
            end
          end
        end
      
      -- Refresh OTHER players' debuffs
      elseif not isOurs and targetGuid and allAuraCasts[targetGuid] and allAuraCasts[targetGuid][spellName] and allAuraCasts[targetGuid][spellName][casterGuid] then
        local existingData = allAuraCasts[targetGuid][spellName][casterGuid]
        local timeleft = (existingData.startTime + existingData.duration) - GetTime()
        
        -- Get existing rank
        local existingRank = 0
        if type(existingData.rank) == "number" then
          existingRank = existingData.rank
        elseif type(existingData.rank) == "string" and existingData.rank ~= "" then
          existingRank = tonumber((string.gsub(existingData.rank, "Rank ", ""))) or 0
        end
        
        if timeleft > 0 then
          if castRank > 0 and castRank < existingRank then
            -- Lower rank cannot refresh higher rank
          else
            allAuraCasts[targetGuid][spellName][casterGuid].startTime = GetTime()
            
            -- Force UI refresh
            if pfUI and pfUI.uf and pfUI.uf.target and UnitExists then
              local _, currentTargetGuid = UnitExists("target")
              if currentTargetGuid == targetGuid then
                pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
              end
            end
          end
        end
      end
      
      -- Carnage: Ferocious Bite refreshes Rip & Rake (only on HIT, only for us)
      if class == "DRUID" and carnageRank == 2 and spellName == "Ferocious Bite" and isOurs then
        if targetGuid and ownDebuffs[targetGuid] then
          if ownDebuffs[targetGuid]["Rip"] then
            ownDebuffs[targetGuid]["Rip"].startTime = GetTime()
          end
          if ownDebuffs[targetGuid]["Rake"] then
            ownDebuffs[targetGuid]["Rake"].startTime = GetTime()
          end
        end
      end
      
    elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
      local spellId = arg1
      local casterGuid = arg2
      local targetGuid = arg3
      local durationMs = arg8
      
      -- SpellInfo returns: name, rank (texture via GetSpellIconTexture + caching)
      if not SpellInfo then return end
      
      local spellName, spellRankString = SpellInfo(spellId)
      if not spellName then return end
      
      -- Get texture via optimized icon lookup (uses GetSpellIconTexture with caching)
      local texture = libdebuff:GetSpellIcon(spellId)
      
      -- Duplicate filter: Same spell + caster + target within 0.1s
      local now = GetTime()
      local signature = string.format("%s:%s:%s", tostring(spellId), tostring(casterGuid), tostring(targetGuid))
      if signature == lastEventSignature and (now - lastEventTime) < 0.1 then
        return -- Duplicate, skip!
      end
      lastEventSignature = signature
      lastEventTime = now
      
      -- Extract rank number
      local rankNum = 0
      if spellRankString and spellRankString ~= "" then
        rankNum = tonumber((string.gsub(spellRankString, "Rank ", ""))) or 0
      end
      
      local duration = durationMs and (durationMs / 1000) or 0
      
      local startTime = GetTime()
      local myGuid = GetPlayerGUID()
      local isOurs = (myGuid and casterGuid == myGuid)
      
      if debugStats.enabled and isOurs then
        debugStats.aura_cast = debugStats.aura_cast + 1
      end
      
      -- CP-based spells: ALWAYS use GetDuration for our casts (event duration is base only!)
      if isOurs and combopointAbilities[spellName] then
        duration = libdebuff:GetDuration(spellName, rankNum)
      end
      
      -- CP-based spells: Force duration=0 for other players (unknown duration!)
      if not isOurs and combopointAbilities[spellName] then
        duration = 0
        
        if debugStats.enabled and IsCurrentTarget(targetGuid) then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[CP-ABILITY OTHER]|r %s duration forced to 0 (unknown)", spellName))
        end
      end
      
      -- Store ALL aura casts (nested by casterGuid for multiple same-spell debuffs)
      if targetGuid and targetGuid ~= "" and targetGuid ~= "0x0000000000000000" then
        allAuraCasts[targetGuid] = allAuraCasts[targetGuid] or {}
        allAuraCasts[targetGuid][spellName] = allAuraCasts[targetGuid][spellName] or {}
        
        -- Check if this is a self-overwrite spell (clears all OTHER casters)
        -- ✅ RANK PROTECTION: Check rank BEFORE clearing other casters
        if selfOverwriteDebuffs[spellName] then
          local shouldOverwrite = true
          
          -- Check if we're trying to overwrite a higher rank
          for otherCaster, otherData in pairs(allAuraCasts[targetGuid][spellName]) do
            if otherCaster ~= casterGuid then
              -- Extract existing rank
              local existingRankNum = 0
              if type(otherData.rank) == "number" then
                existingRankNum = otherData.rank
              elseif type(otherData.rank) == "string" and otherData.rank ~= "" then
                existingRankNum = tonumber((string.gsub(otherData.rank, "Rank ", ""))) or 0
              end
              
              -- Check timeleft
              local timeleft = (otherData.startTime + otherData.duration) - GetTime()
              
              if timeleft > 0 and rankNum > 0 and rankNum < existingRankNum then
                -- Lower rank cannot overwrite higher rank!
                if debugStats.enabled and IsCurrentTarget(targetGuid) then
                  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[SELF-OVERWRITE RANK BLOCK]|r %s Rank %d cannot overwrite Rank %d from caster %s", 
                    spellName, rankNum, existingRankNum, DebugGuid(otherCaster)))
                end
                shouldOverwrite = false
                break
              end
            end
          end
          
          if shouldOverwrite then
            if debugStats.enabled and IsCurrentTarget(targetGuid) then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[SELF-OVERWRITE CHECK]|r %s is in selfOverwriteDebuffs", spellName))
            end
            
            -- Clear all OTHER casters (keep ours if we're recasting)
            local oldCasters = {}
            for otherCaster in pairs(allAuraCasts[targetGuid][spellName]) do
              if otherCaster ~= casterGuid then
                table.insert(oldCasters, otherCaster)
                
                if debugStats.enabled and IsCurrentTarget(targetGuid) then
                  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[SELF-OVERWRITE CLEAR]|r Clearing caster %s (new caster is %s)", 
                    DebugGuid(otherCaster), DebugGuid(casterGuid)))
                end
              end
            end
            for _, otherCaster in ipairs(oldCasters) do
              allAuraCasts[targetGuid][spellName][otherCaster] = nil
            end
            
            -- CRITICAL: Also update allSlots! (WoW doesn't fire DEBUFF_ADDED for overwrites)
            if allSlots[targetGuid] then
              for slot, slotData in pairs(allSlots[targetGuid]) do
                if slotData.spellName == spellName then
                  -- Found the slot with this spell - update it with new caster!
                  allSlots[targetGuid][slot].casterGuid = casterGuid
                  allSlots[targetGuid][slot].isOurs = isOurs
                  
                  if debugStats.enabled and IsCurrentTarget(targetGuid) then
                    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[ALLSLOTS OVERWRITE]|r target=%s slot=%d updated to caster=%s isOurs=%s", 
                      DebugGuid(targetGuid), slot, DebugGuid(casterGuid), tostring(isOurs)))
                  end
                  break
                end
              end
            end
            
            -- CRITICAL: If new caster is NOT us, clear from ownDebuffs (for Target Frame)
            if not isOurs and ownDebuffs[targetGuid] and ownDebuffs[targetGuid][spellName] then
              local oldSlot = ownDebuffs[targetGuid][spellName].slot
              ownDebuffs[targetGuid][spellName] = nil
              
              -- Also clear from ownSlots
              if oldSlot and ownSlots[targetGuid] then
                ownSlots[targetGuid][oldSlot] = nil
              end
              
              if debugStats.enabled and IsCurrentTarget(targetGuid) then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[OWNDBUFFS CLEARED]|r %s removed (not ours anymore)", spellName))
              end
            end
            
            if debugStats.enabled and IsCurrentTarget(targetGuid) and table.getn(oldCasters) == 0 then
              DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[SELF-OVERWRITE SKIP]|r No other casters found to clear")
            end
          end -- end shouldOverwrite
        end -- end selfOverwriteDebuffs
        
        -- ✅ RANK PROTECTION: Check before overwriting in allAuraCasts
        local shouldStore = true
        local existing = allAuraCasts[targetGuid][spellName][casterGuid]
        if existing then
          -- Extract rank number from existing data
          local existingRankNum = 0
          if type(existing.rank) == "number" then
            existingRankNum = existing.rank
          elseif type(existing.rank) == "string" and existing.rank ~= "" then
            existingRankNum = tonumber((string.gsub(existing.rank, "Rank ", ""))) or 0
          end
          
          -- Compare with new rank
          local timeleft = (existing.startTime + existing.duration) - GetTime()
          
          if timeleft > 0 and rankNum > 0 and rankNum < existingRankNum then
            if debugStats.enabled and IsCurrentTarget(targetGuid) then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[AURA_CAST RANK BLOCK]|r %s Rank %d cannot overwrite Rank %d", 
                spellName, rankNum, existingRankNum))
            end
            shouldStore = false -- Don't overwrite higher rank!
          end
        end
        
        -- Only store if rank check passed
        if shouldStore then
          if debugStats.enabled and IsCurrentTarget(targetGuid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ffff[AURA_CAST STORE]|r %s target=%s caster=%s isOurs=%s duration=%.1fs rank=%d", 
              GetDebugTimestamp(), spellName, DebugGuid(targetGuid), DebugGuid(casterGuid), tostring(isOurs), duration, rankNum))
          end
          
          allAuraCasts[targetGuid][spellName][casterGuid] = {
            startTime = startTime,
            duration = duration, -- Will be 0 for other players' CP spells
            rank = rankNum  -- Store as number for consistency
          }
        end
        
        -- CRITICAL: Force refresh Target Frame AFTER adding to allAuraCasts!
        if selfOverwriteDebuffs[spellName] and pfUI and pfUI.uf and pfUI.uf.target then
          pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
          
          if debugStats.enabled and IsCurrentTarget(targetGuid) then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[TARGET REFRESHED]|r RefreshUnit called")
          end
        end
        
        -- Check if this spell overwrites another variant (e.g., Faerie Fire <-> Faerie Fire (Feral))
        if debuffOverwritePairs[spellName] then
          local otherVariant = debuffOverwritePairs[spellName]
          
          if debugStats.enabled and IsCurrentTarget(targetGuid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[OVERWRITE CHECK]|r %s -> %s for caster %s", 
              spellName, otherVariant, DebugGuid(casterGuid)))
          end
          
          -- Remove the other variant from allAuraCasts (for THIS caster only!)
          if allAuraCasts[targetGuid][otherVariant] and allAuraCasts[targetGuid][otherVariant][casterGuid] then
            allAuraCasts[targetGuid][otherVariant][casterGuid] = nil
            
            if debugStats.enabled and IsCurrentTarget(targetGuid) then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[OVERWRITE CLEARED]|r Removed %s for caster %s", 
                otherVariant, DebugGuid(casterGuid)))
            end
          elseif debugStats.enabled and IsCurrentTarget(targetGuid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[OVERWRITE SKIP]|r No %s found for caster %s", 
              otherVariant, DebugGuid(casterGuid)))
          end
        end
      end
      
      -- Notify nameplates that aura was cast
      if pfUI.nameplates and pfUI.nameplates.OnAuraUpdate then
        pfUI.nameplates:OnAuraUpdate(targetGuid)
      end
      
      -- Only track OUR debuffs in ownDebuffs
      if not isOurs then return end
      
      -- Self-Buff: Ignore
      if targetGuid == myGuid then return end
      
      -- Check valid target
      if not targetGuid or targetGuid == "" or targetGuid == "0x0000000000000000" then
        return
      end
      
      -- Rank Protection
      ownDebuffs[targetGuid] = ownDebuffs[targetGuid] or {}
      local existing = ownDebuffs[targetGuid][spellName]
      
      if existing then
        local existingRankNum = 0
        if existing.rank and existing.rank ~= "" then
          existingRankNum = tonumber((string.gsub(existing.rank, "Rank ", ""))) or 0
        end
        
        local timeleft = (existing.startTime + existing.duration) - GetTime()
        
        if timeleft > 0 and rankNum < existingRankNum then
          return -- Lower rank cannot overwrite higher rank!
        end
      end
      
      -- Store in ownDebuffs (slot will be set by DEBUFF_ADDED)
      local existingStartTime = existing and existing.startTime
      
      -- UPDATE existing table instead of replacing it (prevents iterator race condition)
      if not ownDebuffs[targetGuid][spellName] then
        ownDebuffs[targetGuid][spellName] = {}
      end
      
      local data = ownDebuffs[targetGuid][spellName]
      data.startTime = startTime
      data.duration = duration
      data.texture = texture
      data.rank = rankNum  -- Store as number for consistency
      -- Keep existing slot if present (only set to nil on first creation)
      if not data.slot then
        data.slot = nil -- Will be set by DEBUFF_ADDED_OTHER
      end
      
      -- Debug: Track when startTime changes
      if debugStats.enabled and IsCurrentTarget(targetGuid) and existingStartTime then
        local timeDiff = startTime - existingStartTime
        if timeDiff > 0.1 then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[STARTTIME UPDATED]|r %s old=%.2f new=%.2f diff=+%.2fs", 
            spellName, existingStartTime, startTime, timeDiff))
        end
      end
      
      -- Check if this spell overwrites another variant for OUR debuffs
      if debuffOverwritePairs[spellName] then
        local otherVariant = debuffOverwritePairs[spellName]
        if ownDebuffs[targetGuid][otherVariant] then
          local oldSlot = ownDebuffs[targetGuid][otherVariant].slot
          ownDebuffs[targetGuid][otherVariant] = nil
          -- Also clear from ownSlots if it had a slot
          if oldSlot and ownSlots[targetGuid] then
            ownSlots[targetGuid][oldSlot] = nil
          end
        end
      end
      
      -- Speichere für Cleveroids
      objectsByGuid[targetGuid] = objectsByGuid[targetGuid] or {}
      objectsByGuid[targetGuid][spellId] = {
        start = startTime,
        duration = duration,
        caster = "player",
        stacks = 1
      }
      
    elseif event == "SPELL_START_SELF" or event == "SPELL_START_OTHER" then
      local itemId = arg1
      local spellId = arg2
      local casterGuid = arg3
      local targetGuid = arg4
      local castFlags = arg5
      local castTime = arg6  -- in milliseconds
      
      if not casterGuid or not spellId then return end
      
      -- Get spell name and icon
      local spellName = SpellInfo and SpellInfo(spellId) or nil
      local icon = libdebuff:GetSpellIcon(spellId)
      
      -- Store cast info for nameplates
      pfUI.libdebuff_casts[casterGuid] = {
        spellID = spellId,  -- uppercase ID for consistency with nameplates
        spellName = spellName,
        icon = icon,
        startTime = GetTime(),
        duration = castTime and castTime / 1000 or 0,
        endTime = castTime and (GetTime() + castTime / 1000) or nil,
        event = "START"
      }
      
    elseif event == "SPELL_GO_SELF" or event == "SPELL_GO_OTHER" then
      local itemId = arg1
      local spellId = arg2
      local casterGuid = arg3
      local targetGuid = arg4
      local castFlags = arg5
      local numTargetsHit = arg6
      local numTargetsMissed = arg7
      
      -- Clear cast info for nameplates
      if casterGuid and pfUI.libdebuff_casts[casterGuid] then
        pfUI.libdebuff_casts[casterGuid] = nil
      end
      
      -- Nur erfolgreiche Casts (mindestens 1 Target getroffen, keine Misses)
      if numTargetsMissed > 0 or numTargetsHit == 0 then return end
      
      if not SpellInfo then return end
      
      local spellName, spellRankString = SpellInfo(spellId)
      if not spellName then return end
      
      -- Extract rank number from rank string
      local castRank = 0
      if spellRankString and spellRankString ~= "" then
        castRank = tonumber((string.gsub(spellRankString, "Rank ", ""))) or 0
      end
      
      -- Store in pendingCasts for DEBUFF_ADDED
      if targetGuid then
        pendingCasts[targetGuid] = pendingCasts[targetGuid] or {}
        pendingCasts[targetGuid][spellName] = {
          casterGuid = casterGuid,
          rank = castRank,
          time = GetTime()
        }
      end
      
    elseif event == "SPELL_FAILED_OTHER" then
      local casterGuid = arg1
      local spellId = arg2
      
      -- Clear cast info for nameplates (movement cancel, interrupted, etc.)
      if casterGuid and pfUI.libdebuff_casts[casterGuid] then
        pfUI.libdebuff_casts[casterGuid] = nil
      end
      
    elseif event == "DEBUFF_ADDED_OTHER" then
      local guid, slot, spellId, stacks = arg1, arg2, arg3, arg4
      
      local spellName = SpellInfo and SpellInfo(spellId)
      if not spellName then return end
      
      -- DEDUPLICATION
      local now = GetTime()
      lastProcessedDebuff[guid] = lastProcessedDebuff[guid] or {}
      lastProcessedDebuff[guid][slot] = lastProcessedDebuff[guid][slot] or {}
      
      if lastProcessedDebuff[guid][slot][spellName] == now then
        return
      end
      
      lastProcessedDebuff[guid][slot][spellName] = now
      
      -- If unit is dead, cleanup and skip processing (defensive fallback)
      if UnitIsDead and UnitIsDead(guid) then
        CleanupUnit(guid)
        return
      end
      
      -- Get casterGuid from pendingCasts (SPELL_GO)
      local casterGuid = nil
      if pendingCasts[guid] and pendingCasts[guid][spellName] then
        local pending = pendingCasts[guid][spellName]
        -- Only use if within 0.5s (confirmed cast -> debuff)
        if GetTime() - pending.time < 0.5 then
          casterGuid = pending.casterGuid
          -- Clear it now that we've used it
          pendingCasts[guid][spellName] = nil
        end
      end
      
      -- Fallback: Try to get from allAuraCasts if pendingCasts didn't work
      -- (Try most recent cast if multiple casters exist)
      if not casterGuid and allAuraCasts[guid] and allAuraCasts[guid][spellName] then
        local mostRecent = nil
        local mostRecentTime = 0
        for casterId, data in pairs(allAuraCasts[guid][spellName]) do
          if data.startTime > mostRecentTime then
            mostRecentTime = data.startTime
            mostRecent = casterId
          end
        end
        if mostRecent then
          casterGuid = mostRecent
        end
      end
      
      -- Check if ours
      local myGuid = GetPlayerGUID()
      local isOurs = (myGuid and casterGuid == myGuid)
      
      -- Fallback check via ownDebuffs timing (if casterGuid unknown)
      if not isOurs and not casterGuid then
        if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
          local time = GetTime() - ownDebuffs[guid][spellName].startTime
          isOurs = time < 0.5
        end
      end
      
      -- Additional inference for combopoint abilities
      if not casterGuid and combopointAbilities[spellName] then
        local storedCPs = GetStoredComboPoints()
        if storedCPs > 0 then
          casterGuid = myGuid
          isOurs = true
          if debugStats.enabled and IsCurrentTarget(guid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[COMBO INFERENCE]|r %s assigned to us (CP=%d)", 
              spellName, storedCPs))
          end
        end
      end
      
      -- Debug: Show DEBUFF_ADDED (disabled - too spammy)
      
      -- Warn if casterGuid remains unknown
      if not casterGuid and debugStats.enabled and IsCurrentTarget(guid) then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[UNKNOWN CASTER]|r slot=%d %s - no timer available", 
          slot, spellName))
      end
      
      if debugStats.enabled then
        if isOurs then
          debugStats.debuff_added_ours = debugStats.debuff_added_ours + 1
        else
          debugStats.debuff_added_other = debugStats.debuff_added_other + 1
        end
      end
      
      -- Shift up if slot is occupied — but NOT if it's the same spell/caster already
      -- (happens when InitializeTargetSlots already filled the slot, or on stack updates)
      allSlots[guid] = allSlots[guid] or {}
      ownSlots[guid] = ownSlots[guid] or {}
      
      local isDuplicate = false
      if allSlots[guid][slot] then
        local existing = allSlots[guid][slot]
        -- Same spell + same caster → exact duplicate (stack update or post-InitializeTargetSlots)
        -- Same spell + existing caster is nil → rescan placeholder, DEBUFF_ADDED fills the real caster
        if existing.spellName == spellName and (existing.casterGuid == casterGuid or existing.casterGuid == nil) then
          isDuplicate = true
        end
      end
      
      if not isDuplicate then
        local needsShift = false
        for existingSlot in pairs(allSlots[guid]) do
          if existingSlot >= slot then
            needsShift = true
            break
          end
        end
        if needsShift then
          ShiftSlotsUp(guid, slot)
        end
      end
      
      -- ✅ RANK PROTECTION: Check if same spell + same caster with higher rank already in this slot
      if allSlots[guid][slot] and allSlots[guid][slot].spellName == spellName and allSlots[guid][slot].casterGuid == casterGuid then
        -- Same spell, same caster - check rank before overwriting
        
        -- Get new cast rank from SpellInfo
        local newRank = 0
        if SpellInfo then
          local _, newRankString = SpellInfo(spellId)
          if newRankString and newRankString ~= "" then
            newRank = tonumber((string.gsub(newRankString, "Rank ", ""))) or 0
          end
        end
        
        -- Get existing rank from allAuraCasts
        local existingRank = 0
        if allAuraCasts[guid] and allAuraCasts[guid][spellName] and allAuraCasts[guid][spellName][casterGuid] then
          local existingData = allAuraCasts[guid][spellName][casterGuid]
          if type(existingData.rank) == "number" then
            existingRank = existingData.rank
          elseif type(existingData.rank) == "string" and existingData.rank ~= "" then
            existingRank = tonumber((string.gsub(existingData.rank, "Rank ", ""))) or 0
          end
          
          -- Check timeleft
          local timeleft = (existingData.startTime + existingData.duration) - GetTime()
          
          if timeleft > 0 and newRank > 0 and newRank < existingRank then
            -- Lower rank cannot overwrite higher rank!
            if debugStats.enabled and IsCurrentTarget(guid) then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[DEBUFF_ADDED RANK BLOCK]|r %s Rank %d cannot overwrite Rank %d in slot %d", 
                spellName, newRank, existingRank, slot))
            end
            return -- Skip allSlots update!
          end
        end
      end
      
      -- Add to allSlots (for ALL debuffs)
      allSlots[guid][slot] = {
        spellName = spellName,
        casterGuid = casterGuid,
        isOurs = isOurs
      }
      
      if debugStats.enabled and IsCurrentTarget(guid) then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[ALLSLOTS SET]|r target=%s slot=%d %s caster=%s isOurs=%s", 
          DebugGuid(guid), slot, spellName, DebugGuid(casterGuid), tostring(isOurs)))
      end
      
      -- Add to ownSlots if ours
      if isOurs then
        ownSlots[guid][slot] = spellName
        -- Safety: only set slot if entry exists in ownDebuffs
        if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
          ownDebuffs[guid][spellName].slot = slot
        end
      end
      
      -- Also store in allAuraCasts for spells without AURA_CAST event (e.g. Pain Spike)
      -- This ensures InitializeTargetSlots can find the caster on future rescans
      if casterGuid and casterGuid ~= "" and casterGuid ~= "0x0000000000000000" then
        allAuraCasts[guid] = allAuraCasts[guid] or {}
        if not allAuraCasts[guid][spellName] or not allAuraCasts[guid][spellName][casterGuid] then
          allAuraCasts[guid][spellName] = allAuraCasts[guid][spellName] or {}
          -- Only add if not already present (don't overwrite AURA_CAST data which has duration)
          if not allAuraCasts[guid][spellName][casterGuid] then
            allAuraCasts[guid][spellName][casterGuid] = {
              startTime = GetTime(),
              duration = 0,  -- Unknown duration for spells without AURA_CAST
              rank = 0
            }
            if debugStats.enabled and IsCurrentTarget(guid) then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[AURACAST FALLBACK]|r %s caster=%s added to allAuraCasts (no AURA_CAST event)", 
                spellName, DebugGuid(casterGuid)))
            end
          end
        end
      end
      
      -- Cleanup orphaned debuffs
      CleanupOrphanedDebuffs(guid)
      
      -- Notify nameplates that debuff was added
      if pfUI.nameplates and pfUI.nameplates.OnAuraUpdate then
        pfUI.nameplates:OnAuraUpdate(guid)
      end
      
    elseif event == "DEBUFF_REMOVED_OTHER" then
      local guid, slot, spellId = arg1, arg2, arg3
      
      local spellName = SpellInfo and SpellInfo(spellId) or "?"
      
      -- ALWAYS log the event when debugging
      if debugStats.enabled and IsCurrentTarget(guid) then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cffff9900[DEBUFF_REMOVED_OTHER EVENT]|r slot=%d %s target=%s", 
          GetDebugTimestamp(), slot, spellName, DebugGuid(guid)))
      end
      
      -- If unit is dead, cleanup and skip processing (defensive fallback)
      if UnitIsDead and UnitIsDead(guid) then
        CleanupUnit(guid)
        return
      end
      
      -- Check if was ours
      local wasOurs = false
      if ownSlots[guid] and ownSlots[guid][slot] == spellName then
        wasOurs = true
        ownSlots[guid][slot] = nil
        
        -- Only delete from ownDebuffs if NOT recently renewed
        if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
          local age = GetTime() - ownDebuffs[guid][spellName].startTime
          
          -- If renewed within last 1s, DON'T delete (prevents flicker)
          if age > 1 then
            ownDebuffs[guid][spellName] = nil
          elseif debugStats.enabled and IsCurrentTarget(guid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cffff00ff[RENEWAL SKIP DELETE]|r %s age=%.2fs - kept in ownDebuffs", 
              GetDebugTimestamp(), spellName, age))
          end
        end
      end
      
      -- Remove from allSlots
      if allSlots[guid] and allSlots[guid][slot] then
        local slotData = allSlots[guid][slot]
        local removedCasterGuid = slotData.casterGuid
        local removedSpellName = slotData.spellName  -- Use slotData for consistency
        
        -- STALE EVENT CHECK: If the event's spell doesn't match what's in the slot,
        -- a rescan already compacted the slots. This event is for a debuff that's
        -- already gone — don't touch the current slot data.
        if removedSpellName ~= spellName then
          if debugStats.enabled and IsCurrentTarget(guid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cffff00ff[DEBUFF_REMOVED STALE]|r slot=%d event=%s but slot has %s - skipping", 
              GetDebugTimestamp(), slot, spellName, removedSpellName))
          end
          -- Still shift down and cleanup, but don't touch allSlots or allAuraCasts
          if debugStats.enabled then
            if wasOurs then
              debugStats.debuff_removed_ours = debugStats.debuff_removed_ours + 1
            else
              debugStats.debuff_removed_other = debugStats.debuff_removed_other + 1
            end
          end
          CleanupOrphanedDebuffs(guid)
          if pfUI.nameplates and pfUI.nameplates.OnAuraUpdate then
            pfUI.nameplates:OnAuraUpdate(guid)
          end
          return
        end
        
        -- Debug: Show DEBUFF_REMOVED (disabled - too spammy)
        
        -- Also remove from allAuraCasts - use removedSpellName from slotData!
        -- BUT: Check age first to avoid removing during rank changes/refreshes
        if removedCasterGuid and removedCasterGuid ~= "" and allAuraCasts[guid] and allAuraCasts[guid][removedSpellName] then
          if allAuraCasts[guid][removedSpellName][removedCasterGuid] then
            -- Check age - don't delete if recently refreshed (< 1s ago)
            local auraData = allAuraCasts[guid][removedSpellName][removedCasterGuid]
            local age = GetTime() - auraData.startTime
            
            if age > 1 then
              -- Old debuff, safe to delete
              allAuraCasts[guid][removedSpellName][removedCasterGuid] = nil
              
              if debugStats.enabled and IsCurrentTarget(guid) then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[AURACAST CLEARED]|r Removed %s for caster %s from allAuraCasts (age=%.2fs)", 
                  removedSpellName, DebugGuid(removedCasterGuid), age))
              end
              
              -- Cleanup: If no other casters remain, remove spell table
              local hasOtherCasters = false
              for _ in pairs(allAuraCasts[guid][removedSpellName]) do
                hasOtherCasters = true
                break
              end
              if not hasOtherCasters then
                allAuraCasts[guid][removedSpellName] = nil
              end
            else
              -- Recently refreshed - probably rank change, keep it!
              if debugStats.enabled and IsCurrentTarget(guid) then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cffff00ff[RENEWAL SKIP AURACAST DELETE]|r %s age=%.2fs - kept in allAuraCasts", 
                  GetDebugTimestamp(), removedSpellName, age))
              end
            end
          elseif debugStats.enabled and IsCurrentTarget(guid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[AURACAST MISSING]|r %s caster %s not found in allAuraCasts", 
              removedSpellName, DebugGuid(removedCasterGuid)))
          end
        end
        
        allSlots[guid][slot] = nil
      else
        -- Slot is already empty - log this!
        if debugStats.enabled and IsCurrentTarget(guid) then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cffff0000[DEBUFF_REMOVED SLOT EMPTY]|r slot=%d %s already removed (probably by rescan)", 
            GetDebugTimestamp(), slot, spellName))
        end
      end
      
      if debugStats.enabled then
        if wasOurs then
          debugStats.debuff_removed_ours = debugStats.debuff_removed_ours + 1
        else
          debugStats.debuff_removed_other = debugStats.debuff_removed_other + 1
        end
      end
      
      -- ALWAYS shift down (affects all slots)
      ShiftSlotsDown(guid, slot)
      
      -- Mark this GUID as having recent removal (suppress rescans for 0.5s)
      recentRemovals[guid] = GetTime()
      
      -- Cleanup lastProcessedDebuff
      if lastProcessedDebuff[guid] and lastProcessedDebuff[guid][slot] then
        lastProcessedDebuff[guid][slot] = nil
      end
      
      -- Cleanup
      CleanupOrphanedDebuffs(guid)
      ValidateSlotConsistency(guid)
      
      -- Notify nameplates that debuff was removed
      if pfUI.nameplates and pfUI.nameplates.OnAuraUpdate then
        pfUI.nameplates:OnAuraUpdate(guid)
      end
      
    elseif event == "PLAYER_TARGET_CHANGED" then
      -- Initialize slots when targeting a new unit
      if not UnitExists then return end
      local _, targetGuid = UnitExists("target")
      
      if targetGuid and targetGuid ~= "" and targetGuid ~= "0x0000000000000000" then
        local unit = UnitName("target")
        local unitlevel = UnitLevel("target") or 0
        
        -- HYBRID APPROACH: Two-step sync on target change
        
        -- Step 1: Fast GetUnitField scan (fills allSlots with correct slot numbers)
        InitializeTargetSlots(targetGuid)
        
        -- Step 2: Accurate UnitDebuff scan (updates libdebuff.objects with precise timers)
        -- This is "expensive" but only runs ONCE per target change, not on every UNIT_AURA!
        local scannedDebuffs = 0
        for i=1, 16 do
          local effect, rank, texture, stacks, dtype, duration, timeleft = libdebuff:UnitDebuff("target", i)
          
          -- Stop when no more debuffs
          if not texture then break end
          
          if effect and effect ~= "" then
            scannedDebuffs = scannedDebuffs + 1
            
            -- Store accurate timer data in libdebuff.objects
            if duration and timeleft and duration > 0 and timeleft > 0 then
              -- We have accurate timer data from UnitDebuff - store it!
              libdebuff:AddEffect(unit, unitlevel, effect, duration, "player", nil)
              
              if debugStats.enabled then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[TARGET SYNC]|r slot=%d %s dur=%.1f tleft=%.1f", 
                  i, effect, duration, timeleft))
              end
            elseif not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
              -- No timer data available, just store that debuff exists
              libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)
            end
          end
        end
        
        if debugStats.enabled and scannedDebuffs > 0 then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[HYBRID SYNC COMPLETE]|r target=%s scanned=%d debuffs", 
            unit, scannedDebuffs))
        end
      end
    end
    
    -- Periodic cleanup (every event)
    CleanupOutOfRangeUnits()
  end)
end

-- Cleveroids API
if hasNampower then
  -- Exponiere libdebuff
  if CleveRoids then
    CleveRoids.libdebuff = libdebuff
    libdebuff.objects = objectsByGuid
  end
  
  -- GetEnhancedDebuffs API
  function libdebuff:GetEnhancedDebuffs(targetGUID)
    if not targetGUID then return nil end
    local result = {}
    if ownDebuffs[targetGUID] then
      local myGuid = GetPlayerGUID()
      for spellName, data in pairs(ownDebuffs[targetGUID]) do
        local timeleft = (data.startTime + data.duration) - GetTime()
        if timeleft > 0 then
          result[spellName] = result[spellName] or {}
          result[spellName][myGuid] = {
            startTime = data.startTime,
            duration = data.duration,
            texture = data.texture,
            rank = data.rank
          }
        end
      end
    end
    return result
  end
end

-- add libdebuff to pfUI API
pfUI.api.libdebuff = libdebuff

-- Expose debugStats for external access
libdebuff.debugStats = debugStats

-- Debug command: /dumpslot <slot> - Dump complete state for a debuff slot
_G.SLASH_DUMPSLOT1 = "/dumpslot"
_G.SlashCmdList["DUMPSLOT"] = function(msg)
  if not UnitExists("target") then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[DumpSlot]|r No target!")
    return
  end
  
  local slot = tonumber(msg) or 1
  if slot < 1 or slot > 16 then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[DumpSlot]|r Invalid slot! Use /dumpslot 1-16")
    return
  end
  
  local _, guid = UnitExists("target")
  local targetName = UnitName("target")
  local myGuid = GetPlayerGUID()
  
  DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff========================================|r")
  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[DumpSlot]|r Target=%s Slot=%d GUID=%s", targetName, slot, DebugGuid(guid)))
  DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff========================================|r")
  
  -- Check allSlots
  if allSlots[guid] and allSlots[guid][slot] then
    local slotData = allSlots[guid][slot]
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[allSlots]|r FOUND")
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  spellName: %s", slotData.spellName))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  isOurs: %s", tostring(slotData.isOurs)))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  casterGuid: %s", DebugGuid(slotData.casterGuid)))
    
    local spellName = slotData.spellName
    
    -- Check ownDebuffs
    if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
      local data = ownDebuffs[guid][spellName]
      local remaining = (data.startTime + data.duration) - GetTime()
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ownDebuffs]|r FOUND")
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  duration: %.1f", data.duration))
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  remaining: %.1f", remaining))
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  slot: %s", tostring(data.slot)))
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  rank: %s", tostring(data.rank)))
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[ownDebuffs]|r NOT FOUND")
    end
    
    -- Check ownSlots
    if ownSlots[guid] and ownSlots[guid][slot] then
      DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[ownSlots]|r %s", ownSlots[guid][slot]))
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[ownSlots]|r NOT FOUND")
    end
    
    -- Check allAuraCasts
    if allAuraCasts[guid] and allAuraCasts[guid][spellName] then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[allAuraCasts]|r FOUND")
      local count = 0
      for casterGuid, data in pairs(allAuraCasts[guid][spellName]) do
        count = count + 1
        local remaining = (data.startTime + data.duration) - GetTime()
        local isYou = (casterGuid == myGuid)
        local color = isYou and "|cff00ff00" or "|cffff9900"
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s[%d]|r caster=%s%s|r", color, count, DebugGuid(casterGuid), isYou and " (YOU)" or ""))
        DEFAULT_CHAT_FRAME:AddMessage(string.format("      duration=%.1f remaining=%.1f rank=%s", data.duration, remaining, tostring(data.rank)))
      end
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[allAuraCasts]|r NOT FOUND")
    end
    
    -- Call UnitDebuff and show what it returns
    local name, rank, texture, stacks, dtype, duration, timeleft, caster = libdebuff:UnitDebuff("target", slot)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[UnitDebuff() returns]|r")
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  name: %s", tostring(name)))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  duration: %s", tostring(duration)))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  timeleft: %s", tostring(timeleft)))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  caster: %s", tostring(caster)))
    
    if not duration or not timeleft then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff0000>>> NO TIMER DATA! <<<|r")
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00>>> TIMER OK <<<|r")
    end
    
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[allSlots]|r EMPTY - No debuff in this slot")
  end
  
  DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff========================================|r")
end

-- Debug command: /shifttest
_G.SLASH_SHIFTTEST1 = "/shifttest"
_G.SlashCmdList["SHIFTTEST"] = function(msg)
  msg = string.lower(msg or "")
  
  if msg == "start" then
    debugStats.enabled = true
    debugStats.trackAllUnits = false
    -- Reset stats
    for k in pairs(debugStats) do
      if k ~= "enabled" and k ~= "trackAllUnits" then debugStats[k] = 0 end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ShiftTest]|r Tracking STARTED (current target only)")
    
  elseif msg == "stop" then
    debugStats.enabled = false
    debugStats.trackAllUnits = false
    DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[ShiftTest]|r Tracking STOPPED")
    
  elseif msg == "stats" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff=== SHIFT TEST STATS ===|r")
    DEFAULT_CHAT_FRAME:AddMessage(string.format("AURA_CAST (ours): %d", debugStats.aura_cast))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("DEBUFF_ADDED (ours): %d", debugStats.debuff_added_ours))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("DEBUFF_ADDED (other): %d", debugStats.debuff_added_other))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("DEBUFF_REMOVED (ours): %d", debugStats.debuff_removed_ours))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("DEBUFF_REMOVED (other): %d", debugStats.debuff_removed_other))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Shift Down: %d", debugStats.shift_down))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Shift Up: %d", debugStats.shift_up))
    
    -- Validate: Check for mismatches
    local mismatches = 0
    for guid, slots in pairs(ownSlots) do
      for slot, spellName in pairs(slots) do
        if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
          if ownDebuffs[guid][spellName].slot ~= slot then
            mismatches = mismatches + 1
          end
        end
      end
    end
    
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Slot Mismatches: %s%d%s", 
      mismatches > 0 and "|cffff0000" or "|cff00ff00", mismatches, "|r"))
    
    if debugStats.debuff_added_ours > 0 then
      if mismatches == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00*** 100% ACCURATE! ***|r")
      else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000*** ERRORS DETECTED! ***|r")
      end
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff888888(No data yet - use '/shifttest start' and cast some debuffs)|r")
    end
    
  elseif msg == "slots" then
    if not UnitExists then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[ShiftTest]|r UnitExists not available!")
      return
    end
    
    local _, guid = UnitExists("target")
    if not guid then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[ShiftTest]|r No target!")
      return
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff=== TARGET SLOTS ===|r")
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff888888GUID: %s|r", tostring(guid)))
    
    local foundSomething = false
    
    if ownSlots[guid] then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ownSlots:|r")
      for slot, spell in pairs(ownSlots[guid]) do
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  slot %d: %s", slot, spell))
        foundSomething = true
      end
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cffff9900ownSlots: empty|r")
    end
    
    if ownDebuffs[guid] then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ownDebuffs:|r")
      for spell, data in pairs(ownDebuffs[guid]) do
        local left = (data.startTime + data.duration) - GetTime()
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s: slot=%s left=%.1fs", 
          spell, tostring(data.slot or "?"), left))
        foundSomething = true
      end
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cffff9900ownDebuffs: empty|r")
    end
    
    if not foundSomething then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No tracked debuffs on this target|r")
    end
    
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[ShiftTest] Commands:|r")
    DEFAULT_CHAT_FRAME:AddMessage("  /shifttest start")
    DEFAULT_CHAT_FRAME:AddMessage("  /shifttest stop")
    DEFAULT_CHAT_FRAME:AddMessage("  /shifttest stats")
    DEFAULT_CHAT_FRAME:AddMessage("  /shifttest slots")
  end
end

-- Debug command: /memcheck - Show memory usage statistics
_G.SLASH_MEMCHECK1 = "/memcheck"
_G.SlashCmdList["MEMCHECK"] = function()
  local function countTable(t)
    local count = 0
    if not t then return 0 end
    for _ in pairs(t) do count = count + 1 end
    return count
  end
  
  local function countNestedEntries(t)
    local total = 0
    if not t then return 0 end
    for _, nested in pairs(t) do
      if type(nested) == "table" then
        total = total + countTable(nested)
      end
    end
    return total
  end
  
  -- Count active debuffs (ownDebuffs)
  local totalOwnDebuffs = 0
  for guid, debuffs in pairs(ownDebuffs) do
    for spell, data in pairs(debuffs) do
      local timeleft = (data.startTime + data.duration) - GetTime()
      if timeleft > 0 then
        totalOwnDebuffs = totalOwnDebuffs + 1
      end
    end
  end
  
  DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff========== LIBDEBUFF MEMORY ==========|r")
  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00Primary Tables:|r"))
  DEFAULT_CHAT_FRAME:AddMessage(string.format("  ownDebuffs: %d GUIDs, %d active debuffs", countTable(ownDebuffs), totalOwnDebuffs))
  DEFAULT_CHAT_FRAME:AddMessage(string.format("  ownSlots: %d GUIDs, %d tracked slots", countTable(ownSlots), countNestedEntries(ownSlots)))
  DEFAULT_CHAT_FRAME:AddMessage(string.format("  allSlots: %d GUIDs, %d tracked slots", countTable(allSlots), countNestedEntries(allSlots)))
  DEFAULT_CHAT_FRAME:AddMessage(string.format("  objectsByGuid: %d GUIDs, %d entries", countTable(objectsByGuid), countNestedEntries(objectsByGuid)))
  
  -- Count allAuraCasts (triple-nested)
  local totalAuraCasts = 0
  local activeAuraCasts = 0
  for guid, spells in pairs(allAuraCasts) do
    for spell, casters in pairs(spells) do
      for casterGuid, data in pairs(casters) do
        totalAuraCasts = totalAuraCasts + 1
        local timeleft = (data.startTime + data.duration) - GetTime()
        if timeleft > 0 then
          activeAuraCasts = activeAuraCasts + 1
        end
      end
    end
  end
  DEFAULT_CHAT_FRAME:AddMessage(string.format("  allAuraCasts: %d GUIDs, %d casts (%d active)", countTable(allAuraCasts), totalAuraCasts, activeAuraCasts))
  
  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900Support Tables:|r"))
  DEFAULT_CHAT_FRAME:AddMessage(string.format("  pendingCasts: %d GUIDs, %d pending", countTable(pendingCasts), countNestedEntries(pendingCasts)))
  DEFAULT_CHAT_FRAME:AddMessage(string.format("  lastCastRanks: %d entries", countTable(lastCastRanks)))
  DEFAULT_CHAT_FRAME:AddMessage(string.format("  lastFailedSpells: %d entries", countTable(lastFailedSpells)))
  
  -- Summary
  local totalGuids = 0
  local allGuids = {}
  for guid in pairs(ownDebuffs) do allGuids[guid] = true end
  for guid in pairs(ownSlots) do allGuids[guid] = true end
  for guid in pairs(allSlots) do allGuids[guid] = true end
  for guid in pairs(allAuraCasts) do allGuids[guid] = true end
  for guid in pairs(objectsByGuid) do allGuids[guid] = true end
  for guid in pairs(pendingCasts) do allGuids[guid] = true end
  for _ in pairs(allGuids) do totalGuids = totalGuids + 1 end
  
  DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff========================================|r")
  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[TOTAL]|r %d unique GUIDs tracked", totalGuids))
  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[ACTIVE]|r %d own debuffs, %d other casts", totalOwnDebuffs, activeAuraCasts))
  DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff========================================|r")
end

