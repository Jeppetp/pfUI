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
local enhancedDebuffs = {}  -- [targetGUID][spellName][casterGUID] = {cp, startTime, duration, rank, spellID}
local debuffSlots = {}  -- [targetGUID][slot] = {spellName, casterGUID}
local isEnhancedMode = false
local enhancedDebugEnabled = false -- Toggle via /edebug
local slotCacheDebugEnabled = false -- Toggle via /eslots
local debugSelfOnly = false -- Toggle via /edebug self
local hasNampower = GetNampowerVersion ~= nil
local currentComboPoints = 0
local lastSpentComboPoints = 0
local lastSpentTime = 0
local pendingCasts = {}  -- [targetGUID][spellName] = {spellID, casterGUID, timestamp}
local pendingSlotCache = {}  -- [targetGUID][spellID] = {spellName, timestamp} - Waiting for slot number

-- Event Deduplication
local lastProcessedEvents = {}  -- [eventHash] = timestamp
local EVENT_DEDUP_WINDOW = 0.15  -- 150ms window (optimized for performance)

-- Performance: Cache frequently accessed GUIDs
local cachedPlayerGUID = nil
local cachedGUIDs = {}  -- [unit] = {guid, timestamp}
local GUID_CACHE_DURATION = 1.0  -- Cache GUIDs for 1 second

-- Helper: Check if spell is in custom indicators (always track these)
local function IsCustomIndicator(spellName)
  if not pfUI_config or not pfUI_config.unitframes then return false end
  
  local units = {"target", "focus", "group", "raid"}
  for _, unit in ipairs(units) do
    if pfUI_config.unitframes[unit] and pfUI_config.unitframes[unit].custom_indicator then
      local customList = pfUI_config.unitframes[unit].custom_indicator
      if customList and customList ~= "" then
        for _, customName in pairs({strsplit("#", customList)}) do
          if string.lower(customName) == string.lower(spellName) then
            return true
          end
        end
      end
    end
  end
  
  return false
end

local function GetCachedGUID(unit)
  if unit == nil then
    return nil
  end
  
  local now = GetTime()
  local cached = cachedGUIDs[unit]
  
  if cached and (now - cached.timestamp) < GUID_CACHE_DURATION then
    return cached.guid
  end
  
  local _, guid = UnitExists(unit)
  if guid then
    cachedGUIDs[unit] = {guid = guid, timestamp = now}
  end
  return guid
end

local function GetPlayerGUID()
  if not cachedPlayerGUID then
    cachedPlayerGUID = GetCachedGUID("player")
  end
  return cachedPlayerGUID
end

-- Helper: Check if we should show debug message
local function ShouldDebug(casterGUID)
  if not enhancedDebugEnabled then
    return false
  end
  
  if debugSelfOnly then
    local playerGUID = GetPlayerGUID()
    return casterGUID == playerGUID
  end
  
  return true
end

-- Spell Cache: SpellID → {name, texture}
-- This prevents icon collisions where different spells share the same icon
local spellIDToData = nil
local CacheSpellData  -- Forward declaration

-- Legacy: Keep old buff_icons lookup for backward compatibility (used by legacy mode)
local nameToTexture = nil

local function GetTextureByName(spellName)
  if spellName == nil then
    return nil
  end
  
  if not nameToTexture then
    -- Build reverse index once
    nameToTexture = {}
    pfUI_cache.buff_icons = pfUI_cache.buff_icons or {}
    for texture, name in pairs(pfUI_cache.buff_icons) do
      nameToTexture[name] = texture
    end
  end
  return nameToTexture[spellName]
end

local function GetCachedSpellData(spellID, spellName)
  if not spellID then return nil end
  
  if not spellIDToData then
    -- Build cache once
    spellIDToData = {}
    pfUI_cache.spell_cache = pfUI_cache.spell_cache or {}
    
    -- Load from spell_cache
    for id, data in pairs(pfUI_cache.spell_cache) do
      spellIDToData[tonumber(id)] = data
    end
    
    -- MIGRATION: Convert old buff_icons format to new spell_cache
    -- Old format: [texture] = name
    -- New format: [spellID] = {name, texture}
    -- We can't migrate without spellID, so old entries remain for legacy mode
    if pfUI_cache.buff_icons then
      -- Keep buff_icons for legacy mode compatibility
    end
  end
  
  -- Check if we have this spell cached by spellID
  local cached = spellIDToData[spellID]
  if cached then
    return cached.texture
  end
  
  -- AUTO-MIGRATION: If not in spell_cache but exists in old buff_icons by name
  -- and we now have spellID, migrate it!
  if spellName then
    local oldTexture = GetTextureByName(spellName)
    if oldTexture then
      -- Found in old cache - migrate to new format!
      CacheSpellData(spellID, spellName, oldTexture)
      if slotCacheDebugEnabled or enhancedDebugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[Migration]|r " .. spellName .. " (ID:" .. spellID .. ") migrated from buff_icons to spell_cache")
      end
      return oldTexture
    end
  end
  
  return nil
end

CacheSpellData = function(spellID, spellName, texture)
  if not spellID or not spellName or not texture then return end
  
  -- Initialize cache
  pfUI_cache.spell_cache = pfUI_cache.spell_cache or {}
  spellIDToData = spellIDToData or {}
  
  -- Check if already cached
  if pfUI_cache.spell_cache[tostring(spellID)] then
    return -- Already cached
  end
  
  -- Save to SavedVariables
  pfUI_cache.spell_cache[tostring(spellID)] = {
    name = spellName,
    texture = texture
  }
  
  -- Update runtime cache so GetCachedSpellData finds it
  spellIDToData[spellID] = {
    name = spellName,
    texture = texture
  }
  
  if slotCacheDebugEnabled or enhancedDebugEnabled then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Cache]|r " .. spellName .. " (ID:" .. spellID .. ") saved to spell_cache")
  end
end

-- Speichert die Ranks der zuletzt gecasteten Spells (bleibt länger als pending)
local lastCastRanks = {}

-- Speichert Spells die gefailed sind (miss/dodge/parry/etc.) für 1 Sekunde
local lastFailedSpells = {}

-- Carnage Talent Detection (Druid Feral, Tab 2, Slot 17)
local carnageRank = 0  -- 0, 1, or 2

local function UpdateCarnageTalent()
  -- Only check for Druids
  if class ~= "DRUID" then return end
  
  local _, _, _, _, rank = GetTalentInfo(2, 17)  -- Tab 2 (Feral), Slot 17 (Carnage)
  carnageRank = rank or 0
  
  if enhancedDebugEnabled then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Carnage]|r Talent detected: " .. carnageRank .. "/2")
  end
end

-- Helper: GUID Validation (with caching)
local guidValidationCache = {}
local function IsValidGUID(guid)
  if guid == nil then
    return false
  end
  
  if guidValidationCache[guid] ~= nil then
    return guidValidationCache[guid]
  end
  
  local valid = true
  if guid == "0x0000000000000000" or 
    guid == "0x000000000" or 
    guid == "0" or 
    guid == "" then
    valid = false
  end
  
  guidValidationCache[guid] = valid
  return valid
end

-- Helper: Check if GUID is NPC/Creature (not player/pet)
local function IsNPCGUID(guid)
  if not guid or type(guid) ~= "string" then return false end
  -- NPC/Creature GUIDs start with 0xF1 (creatures) or other non-player prefixes
  -- Player GUIDs start with 0x00 (followed by realm/character ID)
  local prefix = string.sub(guid, 1, 4)
  return prefix == "0xF1" or prefix == "0xF5"  -- Creature/NPC
end

-- Helper: Get Name from GUID (SuperWoW support)
local function GetNameFromGUID(guid)
  if not guid then return "UNKNOWN" end
  
  local playerGUID = GetPlayerGUID()
  if guid == playerGUID then
    return "YOU"
  end
  
  -- SuperWoW: GUID direkt als Unit-String nutzen!
  return UnitName(guid) or "OTHER"
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
  ["Mortal Strike"] = true, -- Healing reduction, shares with Wound Poison
  
  -- Rogue
  ["Expose Armor"] = true,
  ["Wound Poison"] = true, -- Healing reduction, shares with Mortal Strike
  
  -- Druid
  ["Faerie Fire"] = true,
  ["Faerie Fire (Feral)"] = true,
  ["Demoralizing Roar"] = true,
  
  -- Hunter
  ["Hunter's Mark"] = true,
  ["Scorpid Sting"] = true,
  
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
  
  -- Shaman
  ["Stormstrike"] = true, -- Nature vulnerability
  
  -- Mage
  ["Winter's Chill"] = true,
  ["Improved Scorch"] = true,
  ["Fire Vulnerability"] = true, -- from Improved Scorch
  
  -- Paladin Judgements
  ["Judgement of Wisdom"] = true,
  ["Judgement of Light"] = true,
  ["Judgement of the Crusader"] = true,
  ["Judgement of Justice"] = true,
}

-- Tracked Buffs (for buff indicator support in Enhanced Mode)
local trackedBuffs = {
  -- Druid HoTs
  ["Rejuvenation"] = true,
  ["Regrowth"] = true,
  
  -- Priest HoTs
  ["Renew"] = true,
  
  -- Paladin
  ["Blessing of Protection"] = true,
  ["Blessing of Freedom"] = true,
  
  -- Shaman
  ["Water Shield"] = true,
  ["Lightning Shield"] = true,
}

-- Shared Buffs (can only exist once per target, show timer from ANY caster)
local sharedBuffs = {
  -- Druid HoTs (only 1 per target)
  ["Rejuvenation"] = true,
  ["Regrowth"] = true,
  ["Regrowth (HoT)"] = true, -- separate HoT portion
  ["Abolish Poison"] = true,
  
  -- Priest
  ["Renew"] = true,
  ["Abolish Disease"] = true,
  ["Power Word: Shield"] = true,
  ["Power Word: Fortitude"] = true,
  ["Divine Spirit"] = true,
  ["Fear Ward"] = true,
  ["Prayer of Fortitude"] = true,
  ["Prayer of Spirit"] = true,
  
  -- Druid
  ["Mark of the Wild"] = true,
  ["Gift of the Wild"] = true,
  ["Thorns"] = true,
  ["Omen of Clarity"] = true,
  
  -- Paladin Blessings (only 1 per type per target)
  ["Blessing of Kings"] = true,
  ["Blessing of Might"] = true,
  ["Blessing of Wisdom"] = true,
  ["Blessing of Salvation"] = true,
  ["Blessing of Sanctuary"] = true,
  ["Blessing of Light"] = true,
  ["Blessing of Protection"] = true,
  ["Blessing of Freedom"] = true,
  ["Greater Blessing of Kings"] = true,
  ["Greater Blessing of Might"] = true,
  ["Greater Blessing of Wisdom"] = true,
  ["Greater Blessing of Salvation"] = true,
  ["Greater Blessing of Sanctuary"] = true,
  ["Greater Blessing of Light"] = true,
  
  -- Shaman
  ["Water Shield"] = true,
  ["Lightning Shield"] = true,
  ["Earthliving Weapon"] = true,
  
  -- Mage
  ["Arcane Intellect"] = true,
  ["Arcane Brilliance"] = true,
  ["Dampen Magic"] = true,
  ["Amplify Magic"] = true,
  
  -- Warlock
  ["Demon Skin"] = true,
  ["Demon Armor"] = true,
  
  -- Misc
  ["Drink"] = true, -- drinking buff
  ["Food"] = true,  -- eating buff
}

-- Combo Point Finishers Database
local comboFinishers = {
  ["Kidney Shot"] = { base = 1, perCP = 1 },
  ["Slice and Dice"] = { base = 9, perCP = 3 },
  ["Rupture"] = { base = 6, perCP = 2 },
  ["Rip"] = { base = 8, perCP = 2 },
  ["Rake"] = { base = 9, perCP = 0 },
  ["Ferocious Bite"] = { base = 0, perCP = 0, isRefresher = true },
  ["Eviscerate"] = { base = 0, perCP = 0 }
}

-- Helper: Get Stored Combo Points
local function GetStoredComboPoints(spellName)
  if not spellName or not comboFinishers[spellName] then return 0 end
  
  if lastSpentComboPoints > 0 and (GetTime() - lastSpentTime) < 1 then
    return lastSpentComboPoints
  end
  
  return 0
end

-- Helper: Calculate Real Duration with CP
local function CalculateRealDuration(spellName, baseDuration, comboPoints)
  if comboPoints == 0 then
    return baseDuration
  end
  
  local finisher = comboFinishers[spellName]
  if finisher then
    local seconds = finisher.base + (finisher.perCP * comboPoints)
    return seconds * 1000
  end
  
  return baseDuration
end

function libdebuff:GetDuration(effect, rank)
  if L["debuffs"][effect] then
    local rank = rank and tonumber((string.gsub(rank, RANK, ""))) or 0
    local rank = L["debuffs"][effect][rank] and rank or libdebuff:GetMaxRank(effect)
    local duration = L["debuffs"][effect][rank]

    if effect == L["dyndebuffs"]["Rupture"] then
      -- Rupture: +2 sec per combo point
      duration = duration + GetComboPoints()*2
    elseif effect == L["dyndebuffs"]["Kidney Shot"] then
      -- Kidney Shot: +1 sec per combo point
      duration = duration + GetComboPoints()*1
    elseif effect == "Rip" or effect == L["dyndebuffs"]["Rip"] then
      -- Rip (Turtle WoW): 10s base + 2s per additional combo point
      -- Base in table is 8, so: 8 + CP*2 = 10/12/14/16/18
      duration = 8 + GetComboPoints()*2
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
      local _,_,_,_,count = GetTalentInfo(2,1)
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

-- Check if Enhanced Mode is active
local function UpdateEnhancedMode()
  local wasActive = isEnhancedMode
  isEnhancedMode = C.unitframes.enhanced_tracking == "1" and hasNampower
  
  if isEnhancedMode and not wasActive then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Enhanced Debuff Tracking activated")
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Type |cffaaffaa/edebug|r to toggle detailed debug logging")
  elseif not isEnhancedMode and wasActive then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Enhanced Debuff Tracking deactivated")
    
    -- Reset all debufffilter settings to "off" when Enhanced is disabled
    local unitframes = { "player", "target", "focus", "group", "grouptarget", "grouppet", "raid", "ttarget", "pet", "ptarget", "fallback", "tttarget" }
    for _, unit in pairs(unitframes) do
      if C.unitframes[unit] and C.unitframes[unit].debufffilter and C.unitframes[unit].debufffilter ~= "off" then
        C.unitframes[unit].debufffilter = "off"
      end
    end
    
    if C.buffbar and C.buffbar.tdebuff and C.buffbar.tdebuff.debufffilter and C.buffbar.tdebuff.debufffilter ~= "off" then
      C.buffbar.tdebuff.debufffilter = "off"
    end
    
    if C.nameplates and C.nameplates.debufffilter and C.nameplates.debufffilter ~= "off" then
      C.nameplates.debufffilter = "off"
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Debuff filters reset to 'Show All Debuffs'")
  end
end

-- Debug Toggle Command
_G.SLASH_PFEDEBUG1 = "/edebug"
_G.SlashCmdList.PFEDEBUG = function(msg)
  if msg == "self" then
    debugSelfOnly = not debugSelfOnly
    if debugSelfOnly then
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Debug Self-Only |cff00ff00ENABLED|r (only shows YOUR casts)")
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Debug Self-Only |cffff0000DISABLED|r (shows all casts)")
    end
  else
    enhancedDebugEnabled = not enhancedDebugEnabled
    if enhancedDebugEnabled then
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Enhanced Debug |cff00ff00ENABLED|r")
      DEFAULT_CHAT_FRAME:AddMessage("|cff888888Shows: Source (Nampower/Calculated), Aura Types, GUIDs|r")
      DEFAULT_CHAT_FRAME:AddMessage("|cff888888Use '/edebug self' to filter only YOUR casts|r")
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Enhanced Debug |cffff0000DISABLED|r")
    end
  end
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
libdebuff:RegisterEvent("ADDON_LOADED")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
libdebuff:RegisterEvent("PLAYER_TARGET_CHANGED")
libdebuff:RegisterEvent("SPELLCAST_STOP")
libdebuff:RegisterEvent("UNIT_AURA")
-- Enhanced Mode Events (Nampower)
if hasNampower then
  libdebuff:RegisterEvent("AURA_CAST_ON_SELF")
  libdebuff:RegisterEvent("AURA_CAST_ON_OTHER")
  libdebuff:RegisterEvent("AURA_FADE")
  libdebuff:RegisterEvent("UNIT_CASTEVENT")
  libdebuff:RegisterEvent("PLAYER_COMBO_POINTS")
  libdebuff:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
  -- Slot-based cache learning
  libdebuff:RegisterEvent("DEBUFF_ADDED_SELF")
  libdebuff:RegisterEvent("BUFF_ADDED_SELF")
  libdebuff:RegisterEvent("DEBUFF_ADDED_OTHER")
  libdebuff:RegisterEvent("BUFF_ADDED_OTHER")
end

-- Carnage Talent Events (Druid only)
if class == "DRUID" then
  libdebuff:RegisterEvent("PLAYER_ENTERING_WORLD")
  libdebuff:RegisterEvent("CHARACTER_POINTS_CHANGED")
end

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

-- Slash Command: /eslots - Toggle slot cache debug
_G.SLASH_PFESLOTS1 = "/eslots"
_G.SlashCmdList.PFESLOTS = function(msg)
  slotCacheDebugEnabled = not slotCacheDebugEnabled
  if slotCacheDebugEnabled then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Slot Cache Debug |cff00ff00ENABLED|r")
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888→ Shows: Slot returned → Scanning slot → Icon found → Saved|r")
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99pfUI:|r Slot Cache Debug |cffff0000DISABLED|r")
  end
end

-- Enhanced Mode: Combo Point Tracking
local function OnComboPointsChanged()
  if not isEnhancedMode then return end
  
  local newCP = GetComboPoints()
  if newCP ~= currentComboPoints then
    local oldCP = currentComboPoints
    currentComboPoints = newCP
    
    if enhancedDebugEnabled then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff3333[CP Debug]|r " .. oldCP .. " -> " .. newCP)
    end
    
    if newCP == 0 and oldCP > 0 then
      lastSpentComboPoints = oldCP
      lastSpentTime = GetTime()
      if enhancedDebugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff3333[CP Debug]|r SPENT! Saved " .. oldCP .. " CP")
      end
    end
  end
end

-- Enhanced Mode: Apply Scheduled Debuff (after delay check) - ONLY ONCE!
local function ApplyScheduledDebuff(targetGUID, spellName)
  if not pendingCasts[targetGUID] or not pendingCasts[targetGUID][spellName] then
    if enhancedDebugEnabled then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Enhanced]|r CANCELLED: " .. spellName .. " (resist detected)")
    end
    return
  end
  
  local pending = pendingCasts[targetGUID][spellName]
  local casterGUID = pending.casterGUID
  local comboPoints = pending.comboPoints
  local duration = pending.duration / 1000
  local rank = pending.rank
  local spellID = pending.spellID
  
  -- Calculate real duration with CP scaling
  if comboPoints and comboPoints > 0 then
    if spellName == "Rip" then
      duration = 8 + (comboPoints * 2)
    elseif spellName == "Rupture" then
      duration = 6 + (comboPoints * 2)
    elseif spellName == "Kidney Shot" then
      duration = 1 + comboPoints
    end
  end
  
  local now = GetTime()
  local playerGUID = GetPlayerGUID()
  
  if not enhancedDebuffs[targetGUID] then
    enhancedDebuffs[targetGUID] = {}
  end
  if not enhancedDebuffs[targetGUID][spellName] then
    enhancedDebuffs[targetGUID][spellName] = {}
  end
  
  local existing = enhancedDebuffs[targetGUID][spellName][casterGUID]
  
  -- RANK PROTECTION
  if existing and existing.rank and rank and rank > 0 then
    local existingIsActive = existing.startTime and existing.duration and (existing.startTime + existing.duration) > now
    if existingIsActive and rank < existing.rank then
      if enhancedDebugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Enhanced]|r BLOCKED: Rank " .. rank .. " cannot overwrite Rank " .. existing.rank)
      end
      pendingCasts[targetGUID][spellName] = nil
      return
    end
  end
  
  -- SHARED DEBUFFS: Remove other casters
  if sharedDebuffs[spellName] then
    for otherCasterGUID, data in pairs(enhancedDebuffs[targetGUID][spellName]) do
      if otherCasterGUID ~= casterGUID then
        enhancedDebuffs[targetGUID][spellName][otherCasterGUID] = nil
        if enhancedDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff6600[Enhanced]|r REMOVED: " .. spellName .. " from other caster (shared)")
        end
      end
    end
  end
  
  enhancedDebuffs[targetGUID][spellName][casterGUID] = {
    cp = comboPoints or 0,
    startTime = now,
    duration = duration,
    rank = rank,
    spellID = spellID
  }
  
  local rankStr = rank and (" | Rank: " .. rank) or ""
  if ShouldDebug(casterGUID) then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Enhanced]|r APPLIED: " .. spellName .. rankStr .. " | CP: " .. (comboPoints or 0) .. " | Duration: " .. duration .. "s")
  end
  
  -- Clear pending
  pendingCasts[targetGUID][spellName] = nil
  
  -- UI Refresh
  if pfUI and pfUI.uf and pfUI.uf.target then
    pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
  end
end

-- Enhanced Mode: Schedule Debuff Application with Ping Delay
local function ScheduleDebuffApplication(targetGUID, spellName, comboPoints, duration, casterGUID, rank, spellID)
  if not targetGUID or not spellName or not casterGUID or not duration or not spellID then return end
  
  -- Calculate ping-based delay (like Cursive)
  local delay = 0.2
  local _, _, nping = GetNetStats()
  if nping and nping > 0 and nping < 500 then
    delay = 0.05 + (nping / 1000.0)
  end
  
  -- Store pending cast
  if not pendingCasts[targetGUID] then
    pendingCasts[targetGUID] = {}
  end
  pendingCasts[targetGUID][spellName] = {
    spellID = spellID,
    casterGUID = casterGUID,
    comboPoints = comboPoints,
    duration = duration,
    rank = rank,
    timestamp = GetTime()
  }
  
  if enhancedDebugEnabled then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Enhanced]|r SCHEDULED: " .. spellName .. " (delay: " .. string.format("%.3f", delay) .. "s)")
  end
  
  -- Schedule actual application after delay
  QueueFunction(function()
    ApplyScheduledDebuff(targetGUID, spellName)
  end, delay)
end

-- Enhanced Mode: Ferocious Bite Refresh (Cursive-Style)
local function RefreshDebuffsOnBite(targetGUID, biteComboPoints, casterGUID)
  if not targetGUID or biteComboPoints ~= 5 then return end
  
  local playerGUID = GetPlayerGUID()
  if casterGUID ~= playerGUID or not enhancedDebuffs[targetGUID] then return end
  
  -- Carnage Check: Only refresh with Carnage 2/2
  if carnageRank < 2 then
    if enhancedDebugEnabled then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff6600[Bite]|r Carnage " .. carnageRank .. "/2 - NO refresh (need 2/2)")
    end
    return
  end
  
  -- Carnage 2/2: ALWAYS refresh at 5 CP (100% chance)
  if enhancedDebugEnabled then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Bite]|r Carnage 2/2 - Refreshing Rip/Rake (5 CP)")
  end
  
  -- Refresh Rip
  if enhancedDebuffs[targetGUID]["Rip"] and enhancedDebuffs[targetGUID]["Rip"][playerGUID] then
    local ripData = enhancedDebuffs[targetGUID]["Rip"][playerGUID]
    local timeLeft = (ripData.startTime + ripData.duration) - GetTime()
    if timeLeft > 0 then
      ripData.startTime = GetTime()
      ripData.duration = ripData.duration + 0.001  -- Cursive trick for UI update
      if enhancedDebugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Bite]|r REFRESHED Rip (" .. ripData.cp .. " CP)")
      end
    end
  end
  
  -- Refresh Rake
  if enhancedDebuffs[targetGUID]["Rake"] and enhancedDebuffs[targetGUID]["Rake"][playerGUID] then
    local rakeData = enhancedDebuffs[targetGUID]["Rake"][playerGUID]
    local timeLeft = (rakeData.startTime + rakeData.duration) - GetTime()
    if timeLeft > 0 then
      rakeData.startTime = GetTime()
      rakeData.duration = rakeData.duration + 0.001
      if enhancedDebugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Bite]|r REFRESHED Rake")
      end
    end
  end
  
  -- Force UI refresh
  if pfUI and pfUI.uf and pfUI.uf.target then
    pfUI.uf.target.update_aura = true
    pfUI.uf:RefreshUnit(pfUI.uf.target, "all")
    
    if enhancedDebugEnabled then
      DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Bite Debug]|r Triggered UI refresh!")
    end
  end
end

-- Performance: Periodic cleanup of old buffs (runs every 5 seconds)
local lastCleanupTime = 0
local CLEANUP_INTERVAL = 5  -- seconds

libdebuff:SetScript("OnUpdate", function()
  local now = GetTime()
  
  -- Only run cleanup every 5 seconds
  if (now - lastCleanupTime) < CLEANUP_INTERVAL then
    return
  end
  lastCleanupTime = now
  
  -- Cleanup old buffs from enhancedDebuffs
  if isEnhancedMode then
    for targetGUID, spells in pairs(enhancedDebuffs) do
      for spellName, casters in pairs(spells) do
        for casterGUID, data in pairs(casters) do
          if data.startTime and data.duration then
            -- Remove buffs 10 seconds after expiry (quick cleanup)
            if (data.startTime + data.duration + 10) < now then
              enhancedDebuffs[targetGUID][spellName][casterGUID] = nil
            end
          end
        end
        
        -- Remove empty caster tables
        local hasCasters = false
        for _ in pairs(casters) do
          hasCasters = true
          break
        end
        if not hasCasters then
          enhancedDebuffs[targetGUID][spellName] = nil
        end
      end
      
      -- Remove empty target tables
      local hasSpells = false
      for _ in pairs(spells) do
        hasSpells = true
        break
      end
      if not hasSpells then
        enhancedDebuffs[targetGUID] = nil
      end
    end
  end
  
  -- Cleanup old GUID cache entries
  for unit, data in pairs(cachedGUIDs) do
    if (now - data.timestamp) > 10 then  -- Remove entries older than 10s
      cachedGUIDs[unit] = nil
    end
  end
  
  -- Cleanup old dedup entries
  for hash, timestamp in pairs(lastProcessedEvents) do
    if (now - timestamp) > 1 then  -- Remove entries older than 1s
      lastProcessedEvents[hash] = nil
    end
  end
end)

-- Gather Data by Events
libdebuff:SetScript("OnEvent", function()
  -- Initialize spell_cache on addon load
  if event == "ADDON_LOADED" and arg1 == "pfUI" then
    -- Ensure spell_cache exists in pfUI_cache BEFORE pfUI overwrites it
    pfUI_cache.spell_cache = pfUI_cache.spell_cache or {}
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[libdebuff]|r spell_cache initialized (" .. table.getn(pfUI_cache.spell_cache) .. " entries)")
    return
  end
  
  -- Carnage Talent Events (Druid only)
  if event == "PLAYER_ENTERING_WORLD" or event == "CHARACTER_POINTS_CHANGED" then
    UpdateCarnageTalent()
  end
  
  -- Update Enhanced Mode status
  UpdateEnhancedMode()
  
  -- Enhanced Mode: Handle Nampower Events
  if isEnhancedMode then
    if event == "PLAYER_COMBO_POINTS" then
      OnComboPointsChanged()
      return
      
    elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
      local spellID = arg1
      local casterGUID = arg2
      local targetGUID = arg3
      local auraType = arg4
      local duration = arg8
      
      -- VALIDATION: Check all GUIDs
      if not spellID or spellID <= 0 then return end
      if not IsValidGUID(casterGUID) or not IsValidGUID(targetGUID) then 
        if enhancedDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[GUID ERROR]|r Invalid GUID in AURA_CAST - Caster: " .. tostring(casterGUID) .. " Target: " .. tostring(targetGUID))
        end
        return 
      end
      
      -- PERFORMANCE: Early exit for NPC→NPC events (don't care about mob buffs)
      if IsNPCGUID(casterGUID) and IsNPCGUID(targetGUID) then
        return  -- NPC buffing another NPC, skip completely
      end
      
      -- WICHTIG: PlayerGUID ZUERST holen!
      local playerGUID = GetPlayerGUID()
      if not playerGUID then return end
      
      local spellName, spellRank = SpellInfo(spellID)
      if not spellName then return end
      
      -- CACHE LEARNING: Only cache spells with positive duration (skip mounts, toggles, instant-no-buff)
      -- Duration > 0 means it's a real buff/debuff worth caching
      -- NEW: Use slot-based learning instead of scanning all slots!
      local cachedTexture = GetCachedSpellData(spellID, spellName)
      if not cachedTexture and duration and duration > 0 then
        -- Mark this spell as pending for slot-based cache learning
        if not pendingSlotCache[targetGUID] then
          pendingSlotCache[targetGUID] = {}
        end
        pendingSlotCache[targetGUID][spellID] = {
          spellName = spellName,
          timestamp = GetTime()
        }
        
        if slotCacheDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Slot Cache]|r Pending: " .. spellName .. " (ID:" .. spellID .. ") - waiting for slot...")
        end
      end
      
      -- Filter: Only track OWN casts + SHARED debuffs + SHARED buffs + CUSTOM INDICATORS + LOCALE TABLE ENTRIES
      -- ENHANCED MODE EXTENSION: Check if spell is in locale table as fallback for unknown spells
      -- This allows tracking of passive procs and other spells that Nampower doesn't provide duration for
      local isInLocaleTable = false
      if L and L["debuffs"] and L["debuffs"][spellName] then
        isInLocaleTable = true
      end
      
      if casterGUID ~= playerGUID and not sharedDebuffs[spellName] and not sharedBuffs[spellName] and not IsCustomIndicator(spellName) and not isInLocaleTable then
        if enhancedDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[SKIP]|r " .. spellName .. " - Not from player and not shared/custom/locale")
        end
        return
      end
      
      -- Event Deduplication
      local eventHash = targetGUID .. spellID .. casterGUID .. tostring(duration)
      if lastProcessedEvents[eventHash] and (GetTime() - lastProcessedEvents[eventHash]) < EVENT_DEDUP_WINDOW then
        if enhancedDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff6600[DEDUP]|r Skipped duplicate event for " .. spellName)
        end
        return
      end
      lastProcessedEvents[eventHash] = GetTime()
      
      -- Filter: Ignore auras without duration (shapeshifts, stances, etc.)
      -- These return duration = -0.0 (negative zero!)
      if duration and duration < 0 then 
        if enhancedDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SKIP]|r " .. spellName .. " - Toggle buff (duration < 0)")
        end
        return 
      end
      
      -- Filter: Skip pure buffs without any effect (Type 1), EXCEPT tracked or shared buffs
      if (not auraType or auraType == 1) and not trackedBuffs[spellName] and not sharedBuffs[spellName] then
        if enhancedDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SKIP]|r " .. spellName .. " - Pure buff (Type 1), not tracked")
        end
        return 
      end
      
      local rankNum = 0
      if spellRank and spellRank ~= "" then
        local _, _, num = string.find(spellRank, "(%d+)")
        rankNum = tonumber(num) or 0
      end
      
      local comboPoints = 0
      local durationSource = "NAMPOWER"
      
      -- CP-based duration calculation (ONLY for player!)
      if not duration or duration == 0 then
        durationSource = "CALCULATED"
        if casterGUID == playerGUID then
          if spellName == "Rip" then
            local cp = GetStoredComboPoints(spellName)
            if cp == 0 then cp = GetComboPoints() end
            duration = (8 + cp * 2) * 1000
            comboPoints = cp
          elseif spellName == "Rupture" then
            local cp = GetStoredComboPoints(spellName)
            if cp == 0 then cp = GetComboPoints() end
            duration = (6 + cp * 2) * 1000
            comboPoints = cp
          elseif spellName == "Kidney Shot" then
            local cp = GetStoredComboPoints(spellName)
            if cp == 0 then cp = GetComboPoints() end
            duration = (1 + cp) * 1000
            comboPoints = cp
          else
            -- ENHANCED MODE EXTENSION: LOCALE FALLBACK for player casts
            -- Uses same locale tables as Legacy Mode (L["debuffs"])
            -- This allows tracking spells that Nampower doesn't provide duration for
            -- NOTE: Can be removed to revert to strict NAMPOWER-only tracking
            if L and L["debuffs"] and L["debuffs"][spellName] then
              local localeDuration = L["debuffs"][spellName][rankNum] or L["debuffs"][spellName][0]
              if localeDuration and localeDuration > 0 then
                duration = localeDuration * 1000  -- Convert seconds to milliseconds
                durationSource = "LOCALE"
                if enhancedDebugEnabled then
                  DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[LOCALE FALLBACK]|r " .. spellName .. " - Duration: " .. localeDuration .. "s (Rank " .. rankNum .. ")")
                end
              else
                if enhancedDebugEnabled then
                  DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SKIP]|r " .. spellName .. " - No duration in locale table")
                end
                return
              end
            else
              if enhancedDebugEnabled then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SKIP]|r " .. spellName .. " - Not found in locale debuffs")
              end
              return
            end
          end
        else
          -- ENHANCED MODE EXTENSION: LOCALE FALLBACK for non-player casters
          -- Allows tracking of debuffs/buffs from other players when Nampower has no duration
          -- Example: Passive procs like Vindication from Paladins
          -- NOTE: Can be removed to revert to strict NAMPOWER-only tracking
          if L and L["debuffs"] and L["debuffs"][spellName] then
            local localeDuration = L["debuffs"][spellName][rankNum] or L["debuffs"][spellName][0]
            if localeDuration and localeDuration > 0 then
              duration = localeDuration * 1000  -- Convert seconds to milliseconds
              durationSource = "LOCALE"
              if enhancedDebugEnabled then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[LOCALE FALLBACK]|r " .. spellName .. " - Duration: " .. localeDuration .. "s (Non-player, Rank " .. rankNum .. ")")
              end
            else
              if enhancedDebugEnabled then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SKIP]|r " .. spellName .. " - No duration in locale table (non-player)")
              end
              return
            end
          else
            if enhancedDebugEnabled then
              DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SKIP]|r " .. spellName .. " - Not found in locale debuffs (non-player)")
            end
            return
          end
        end
      end
      
      -- Track CP for player's CP-based spells
      if casterGUID == playerGUID and comboFinishers[spellName] then
        if comboPoints == 0 then
          comboPoints = GetStoredComboPoints(spellName)
          if comboPoints == 0 then
            comboPoints = GetComboPoints()
          end
        end
      end
      
      -- DIREKT ANWENDEN - Nampower gibt uns EXAKTE Daten!
      local now = GetTime()
      
      if not enhancedDebuffs[targetGUID] then
        enhancedDebuffs[targetGUID] = {}
      end
      if not enhancedDebuffs[targetGUID][spellName] then
        enhancedDebuffs[targetGUID][spellName] = {}
      end
      
      local existing = enhancedDebuffs[targetGUID][spellName][casterGUID]
      
      -- RANK PROTECTION
      if existing and existing.rank and rankNum and rankNum > 0 then
        local existingIsActive = existing.startTime and existing.duration and (existing.startTime + existing.duration) > now
        if existingIsActive and rankNum < existing.rank then
          if enhancedDebugEnabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Enhanced]|r BLOCKED: Rank " .. rankNum .. " cannot overwrite Rank " .. existing.rank)
          end
          return
        end
      end
      
      -- SHARED BUFFS: Check if ANY caster has higher rank
      if sharedBuffs[spellName] and rankNum and rankNum > 0 then
        for otherCasterGUID, data in pairs(enhancedDebuffs[targetGUID][spellName]) do
          if otherCasterGUID ~= casterGUID and data.rank and data.rank > 0 then
            local otherIsActive = data.startTime and data.duration and (data.startTime + data.duration) > now
            if otherIsActive and rankNum < data.rank then
              if enhancedDebugEnabled then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Enhanced]|r BLOCKED: Your Rank " .. rankNum .. " cannot overwrite other caster's Rank " .. data.rank .. " (shared buff)")
              end
              return
            end
          end
        end
      end
      
      -- SHARED BUFFS: Remove other casters (same logic as shared debuffs)
      if sharedBuffs[spellName] then
        for otherCasterGUID, data in pairs(enhancedDebuffs[targetGUID][spellName]) do
          if otherCasterGUID ~= casterGUID then
            enhancedDebuffs[targetGUID][spellName][otherCasterGUID] = nil
            if enhancedDebugEnabled then
              DEFAULT_CHAT_FRAME:AddMessage("|cffff6600[Enhanced]|r REMOVED: " .. spellName .. " from other caster (shared buff)")
            end
          end
        end
      end
      
      -- SHARED DEBUFFS: Remove other casters
      if sharedDebuffs[spellName] then
        for otherCasterGUID, data in pairs(enhancedDebuffs[targetGUID][spellName]) do
          if otherCasterGUID ~= casterGUID then
            enhancedDebuffs[targetGUID][spellName][otherCasterGUID] = nil
            if enhancedDebugEnabled then
              DEFAULT_CHAT_FRAME:AddMessage("|cffff6600[Enhanced]|r REMOVED: " .. spellName .. " from other caster (shared)")
            end
          end
        end
      end
      
      -- SPEICHERN
      -- Cache lookup (learning already happened above, before filter)
      local learnedTexture = GetCachedSpellData(spellID, spellName)
      if not learnedTexture then
        -- Fallback to old buff_icons cache
        learnedTexture = GetTextureByName(spellName)
      end
      
      enhancedDebuffs[targetGUID][spellName][casterGUID] = {
        cp = comboPoints or 0,
        startTime = now,
        duration = duration / 1000,
        rank = rankNum,
        spellID = spellID,
        texture = learnedTexture
      }
      
      -- DEBUG: Track Rejuvenation
      if spellName == "Rejuvenation" and enhancedDebugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[REJUV TRACKED]|r From: " .. (casterGUID == playerGUID and "YOU" or "OTHER") .. " Duration: " .. (duration/1000) .. "s Rank: " .. rankNum)
      end
      
      -- CP Sync Check: Wenn wir Finisher sind und CP noch 0, warte kurz und update
      if comboFinishers[spellName] and casterGUID == playerGUID and comboPoints == 0 then
        QueueFunction(function()
          local storedCP = GetStoredComboPoints(spellName)
          if storedCP > 0 and enhancedDebuffs[targetGUID] and 
            enhancedDebuffs[targetGUID][spellName] and
            enhancedDebuffs[targetGUID][spellName][casterGUID] then
            enhancedDebuffs[targetGUID][spellName][casterGUID].cp = storedCP
            -- Duration neu berechnen
            local realDur = CalculateRealDuration(spellName, duration, storedCP)
            enhancedDebuffs[targetGUID][spellName][casterGUID].duration = realDur / 1000
            
            if enhancedDebugEnabled then
              DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CP SYNC]|r Updated " .. spellName .. " CP: " .. storedCP .. " Duration: " .. (realDur/1000) .. "s")
            end
            
            -- UI Refresh
            if pfUI and pfUI.uf and pfUI.uf.target then
              pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
            end
          end
        end, 0.1)
      end
      
      local rankStr = rankNum > 0 and (" | Rank: " .. rankNum) or ""
      local isPlayer = (casterGUID == playerGUID)
      local casterName = isPlayer and "YOU" or GetNameFromGUID(casterGUID)
      
      if ShouldDebug(casterGUID) then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00-----------------------------------------------|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff66ff[Debuff Applied]|r " .. spellName .. rankStr)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Caster:|r " .. casterName .. " |cff888888(" .. casterGUID .. ")|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00Target:|r " .. GetNameFromGUID(targetGUID) .. " |cff888888(" .. targetGUID .. ")|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8800Duration:|r " .. string.format("%.1fs", duration/1000) .. " |cff888888[Source: " .. durationSource .. "]|r")
        if comboPoints > 0 then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff3333Combo Points:|r " .. comboPoints)
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888Aura Type:|r " .. (auraType or "nil"))
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00-----------------------------------------------|r")
      end
      
      -- SOFORT UI REFRESH (kein Delay!)
      if pfUI and pfUI.uf and pfUI.uf.target then
        pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
      end
      
      return
    
    elseif event == "AURA_FADE" then
      local spellID = arg1
      local casterGUID = arg2
      local targetGUID = arg3
      
      if not spellID then return end
      if not IsValidGUID(casterGUID) or not IsValidGUID(targetGUID) then 
        if enhancedDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[GUID ERROR]|r Invalid GUID in AURA_FADE")
        end
        return 
      end
      
      local spellName = SpellInfo(spellID)
      if not spellName then return end
      
      -- Remove the specific debuff from this caster
      if enhancedDebuffs[targetGUID] and enhancedDebuffs[targetGUID][spellName] then
        if enhancedDebuffs[targetGUID][spellName][casterGUID] then
          enhancedDebuffs[targetGUID][spellName][casterGUID] = nil
          if enhancedDebugEnabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Enhanced]|r FADED: " .. spellName)
          end
          
          -- Cleanup empty tables
          local hasAnyCaster = false
          for _ in pairs(enhancedDebuffs[targetGUID][spellName]) do
            hasAnyCaster = true
            break
          end
          
          if not hasAnyCaster then
            enhancedDebuffs[targetGUID][spellName] = nil
          end
          
          -- Clear slot mapping for this target
          if debuffSlots[targetGUID] then
            for slot, slotData in pairs(debuffSlots[targetGUID]) do
              if slotData.spellName == spellName and slotData.casterGUID == casterGUID then
                debuffSlots[targetGUID][slot] = nil
                if enhancedDebugEnabled then
                  DEFAULT_CHAT_FRAME:AddMessage("|cffff6600[Slot]|r Cleared slot " .. slot .. " for " .. spellName)
                end
              end
            end
          end
          
          -- Trigger slot remapping if this is current target
          local _, currentTargetGUID = UnitExists("target")
          if currentTargetGUID == targetGUID then
            -- Rebuild slot mapping immediately
            if debuffSlots[targetGUID] then
              for slot = 1, 16 do
                debuffSlots[targetGUID][slot] = nil
              end
            end
            
            for slot = 1, 16 do
              local texture = UnitDebuff("target", slot)
              if texture then
                scanner:SetUnitDebuff("target", slot)
                local scanSpellName = scanner:Line(1)
                
                if scanSpellName and enhancedDebuffs[targetGUID] and enhancedDebuffs[targetGUID][scanSpellName] then
                  local now = GetTime()
                  local bestCaster = nil
                  local bestRemaining = -1
                  
                  for scanCasterGUID, data in pairs(enhancedDebuffs[targetGUID][scanSpellName]) do
                    if data.startTime and data.duration then
                      local remaining = (data.startTime + data.duration) - now
                      if remaining > 0 and remaining > bestRemaining then
                        bestCaster = scanCasterGUID
                        bestRemaining = remaining
                      end
                    end
                  end
                  
                  if bestCaster then
                    if not debuffSlots[targetGUID] then
                      debuffSlots[targetGUID] = {}
                    end
                    debuffSlots[targetGUID][slot] = {
                      spellName = scanSpellName,
                      casterGUID = bestCaster
                    }
                  end
                end
              else
                break
              end
            end
            
            if enhancedDebugEnabled then
              DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Slot]|r Remapped slots after AURA_FADE")
            end
          end
          
          -- UI Refresh
          if pfUI and pfUI.uf and pfUI.uf.target then
            pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
          end
        end
      end
      return
      
    elseif event == "UNIT_CASTEVENT" then
      local casterGUID = arg1
      local targetGUID = arg2
      local eventType = arg3
      local spellID = arg4
      
      if eventType ~= "CAST" then return end
      if not IsValidGUID(casterGUID) then return end
      if not spellID or spellID <= 0 then return end
      
      local spellName = SpellInfo and SpellInfo(spellID)
      if not spellName then return end
      
      local playerGUID = GetPlayerGUID()
      
      -- FEROCIOUS BITE REFRESH: Only for own casts
      if casterGUID ~= playerGUID then return end
      
      if spellName == "Ferocious Bite" then
        local cp = GetStoredComboPoints(spellName)
        if cp == 0 then cp = GetComboPoints() end
        
        -- Validate targetGUID before refresh
        if IsValidGUID(targetGUID) then
          RefreshDebuffsOnBite(targetGUID, cp, casterGUID)
        end
      end
      return
      
    elseif event == "DEBUFF_ADDED_SELF" or event == "BUFF_ADDED_SELF" or 
           event == "DEBUFF_ADDED_OTHER" or event == "BUFF_ADDED_OTHER" then
      -- Slot-based cache learning: We got the slot number!
      local targetGUID = arg1
      local slot = arg2
      local spellID = arg3
      
      if not targetGUID or not slot or not spellID then return end
      
      -- OPTIMIZATION: Skip already cached spells (no work needed)
      if pfUI_cache.spell_cache and pfUI_cache.spell_cache[tostring(spellID)] then
        return  -- Already cached, nothing to do
      end
      
      if slotCacheDebugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[" .. event .. "]|r Target:" .. tostring(targetGUID) .. " Slot:" .. tostring(slot) .. " SpellID:" .. tostring(spellID))
      end
      
      -- Check if this spell is pending for cache learning
      if pendingSlotCache[targetGUID] and pendingSlotCache[targetGUID][spellID] then
        local pendingData = pendingSlotCache[targetGUID][spellID]
        local spellName = pendingData.spellName
        
        if slotCacheDebugEnabled then
          DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[Slot Cache]|r Slot " .. slot .. " returned → " .. spellName .. " (ID:" .. spellID .. ")")
        end
        
        -- Scan ONLY this specific slot!
        local texture = nil
        local playerGUID = GetPlayerGUID()
        
        -- Determine which unit to scan
        local isSelf = (event == "BUFF_ADDED_SELF" or event == "DEBUFF_ADDED_SELF")
        local isBuff = (event == "BUFF_ADDED_SELF" or event == "BUFF_ADDED_OTHER")
        
        if isSelf then
          -- Scan player
          if isBuff then
            texture = UnitBuff("player", slot)
          else
            texture = UnitDebuff("player", slot)
          end
        else
          -- Scan other player (SuperWoW GUID or target)
          if UnitExists(targetGUID) then
            if isBuff then
              texture = UnitBuff(targetGUID, slot)
            else
              texture = UnitDebuff(targetGUID, slot)
            end
          elseif UnitExists("target") then
            local _, currentTargetGUID = UnitExists("target")
            if currentTargetGUID == targetGUID then
              if isBuff then
                texture = UnitBuff("target", slot)
              else
                texture = UnitDebuff("target", slot)
              end
            end
          end
        end
        
        if texture then
          if slotCacheDebugEnabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Slot Cache]|r Scanning slot " .. slot .. " → Icon: " .. texture)
          end
          
          -- Cache it!
          CacheSpellData(spellID, spellName, texture)
          
          if slotCacheDebugEnabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Slot Cache]|r ✓ SAVED: " .. spellName .. " (ID:" .. spellID .. ") → spell_cache")
          end
        else
          if slotCacheDebugEnabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Slot Cache]|r ✗ Slot " .. slot .. " scan failed for " .. spellName)
          end
        end
        
        -- Clean up pending entry
        pendingSlotCache[targetGUID][spellID] = nil
      end
      return
      
    elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
      -- Detect resists and cancel pending casts
      local resistPatterns = {
        "Your (.+) was resisted by",
        "Your (.+) missed",
        "Your (.+) was dodged",
        "Your (.+) is parried by",
        "Your (.+) failed",
        "Your (.+) was blocked by"
      }
      
      for _, pattern in ipairs(resistPatterns) do
        local _, _, spellName = string.find(arg1, pattern)
        if spellName then
          -- Cancel all pending casts of this spell
          for targetGUID, spells in pairs(pendingCasts) do
            if spells[spellName] then
              if enhancedDebugEnabled then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Enhanced]|r RESIST detected: " .. spellName)
              end
              spells[spellName] = nil
            end
          end
          break
        end
      end
      return
    end
  end
  
  -- Legacy Mode: Original libdebuff events
  if event == "CHAT_MSG_COMBAT_SELF_HITS" then
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

  elseif event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE" or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
    local unit, effect = cmatch(arg1, AURAADDEDOTHERHARMFUL)
    if unit and effect then
      local unitlevel = UnitName("target") == unit and UnitLevel("target") or 0
      if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
        libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)
      end
    end

  elseif ( event == "UNIT_AURA" and arg1 == "target" ) or event == "PLAYER_TARGET_CHANGED" then
    -- Throttle UNIT_AURA to max 10 Hz (every 100ms) to prevent tooltip scan spam
    -- PLAYER_TARGET_CHANGED always processes immediately
    local now = GetTime()
    if event == "UNIT_AURA" then
      if not this.lastUnitAuraUpdate then
        this.lastUnitAuraUpdate = 0
      end
      if (now - this.lastUnitAuraUpdate) < 0.1 then
        return  -- Skip this update, too soon (throttled)
      end
      this.lastUnitAuraUpdate = now
    end
    
    -- Enhanced Mode: ALWAYS rebuild slot mapping on UNIT_AURA
    if isEnhancedMode then
      local _, targetGUID = UnitExists("target")
      local playerGUID = GetPlayerGUID()
      
      if targetGUID and IsValidGUID(targetGUID) then
        -- Initialize debuffSlots for this target
        if not debuffSlots[targetGUID] then
          debuffSlots[targetGUID] = {}
        end
        
        -- CRITICAL: Clear ALL old slot mappings first
        for slot = 1, 16 do
          debuffSlots[targetGUID][slot] = nil
        end
        
        local now = GetTime()
        
        -- First pass: Build list of what's actually visible + track by spell name
        local visibleDebuffs = {}  -- [spellName] = {slot1, slot2, ...}
        
        for slot = 1, 16 do
          local texture = UnitDebuff("target", slot)
          if texture then
            scanner:SetUnitDebuff("target", slot)
            local spellName = scanner:Line(1)
            
            if spellName then
              if not visibleDebuffs[spellName] then
                visibleDebuffs[spellName] = {}
              end
              table.insert(visibleDebuffs[spellName], slot)
            end
          else
            break
          end
        end
        
        -- CLEANUP: Remove expired debuffs AFTER knowing what's visible
        if enhancedDebuffs[targetGUID] then
          for spellName, casters in pairs(enhancedDebuffs[targetGUID]) do
            -- Only cleanup if spell is NOT visible anymore
            if not visibleDebuffs[spellName] then
              for casterGUID, data in pairs(casters) do
                if data.startTime and data.duration then
                  local remaining = (data.startTime + data.duration) - now
                  if remaining <= -0.5 then
                    enhancedDebuffs[targetGUID][spellName][casterGUID] = nil
                    if enhancedDebugEnabled then
                      DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Cleanup]|r EXPIRED: " .. spellName .. " from " .. (casterGUID == playerGUID and "YOU" or "OTHER"))
                    end
                  end
                end
              end
              
              -- Remove empty spell tables
              local hasAnyCaster = false
              for _ in pairs(casters) do
                hasAnyCaster = true
                break
              end
              if not hasAnyCaster then
                enhancedDebuffs[targetGUID][spellName] = nil
              end
            end
          end
        end
        
        -- Second pass: Match slots to casters
        if enhancedDebuffs[targetGUID] then
          for spellName, slots in pairs(visibleDebuffs) do
            if enhancedDebuffs[targetGUID][spellName] then
              -- Collect active casters for this spell, sorted by remaining time (longest first)
              local activeCasters = {}
              
              for casterGUID, data in pairs(enhancedDebuffs[targetGUID][spellName]) do
                if data.startTime and data.duration then
                  local remaining = (data.startTime + data.duration) - now
                  if remaining > -0.5 then  -- Allow 0.5s grace period
                    table.insert(activeCasters, {
                      casterGUID = casterGUID,
                      remaining = remaining,
                      isPlayer = (casterGUID == playerGUID)
                    })
                  end
                end
              end
              
              -- Sort: Player's debuffs ALWAYS first, then by remaining time
              table.sort(activeCasters, function(a, b)
                -- CRITICAL: Player MUST come first!
                if a.isPlayer and not b.isPlayer then
                  return true  -- a (player) comes before b (other)
                elseif not a.isPlayer and b.isPlayer then
                  return false  -- b (player) comes before a (other)
                end
                -- Both same type: sort by remaining time
                return a.remaining > b.remaining
              end)
              
              -- Assign slots to casters in order
              for i, slot in ipairs(slots) do
                if activeCasters[i] then
                  debuffSlots[targetGUID][slot] = {
                    spellName = spellName,
                    casterGUID = activeCasters[i].casterGUID
                  }
                  
                  if enhancedDebugEnabled then
                    local casterStr = activeCasters[i].isPlayer and "YOU" or "OTHER"
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[Slot Map]|r Slot " .. slot .. " = " .. spellName .. " (" .. string.format("%.1f", activeCasters[i].remaining) .. "s) from " .. casterStr)
                  end
                else
                  -- More visible slots than tracked casters - should not happen
                  if enhancedDebugEnabled then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Slot Map ERROR]|r Slot " .. slot .. " = " .. spellName .. " but no caster data!")
                  end
                end
              end
            end
          end
        end
      end
    end
  
    -- Legacy Mode
    if not isEnhancedMode then
      for i=1, 16 do
        local effect, rank, texture, stacks, dtype, duration, timeleft = libdebuff:UnitDebuff("target", i)
        if not texture then return end
        if texture and effect and effect ~= "" then
          local unitlevel = UnitLevel("target") or 0
          local unit = UnitName("target")
          if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
            libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)
          end
        end
      end
    end

  elseif event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" or event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
    for _, msg in pairs(libdebuff.rp) do
      local effect = cmatch(arg1, msg)
      if effect then
        lastFailedSpells[effect] = { time = GetTime() }
        if libdebuff.pending[3] == effect then
          libdebuff:RemovePending()
          return
        elseif lastspell and lastspell.start_old and lastspell.effect == effect then
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
  if isEnhancedMode then return end
  if not id then return end
  
  -- Nampower akzeptiert jetzt spellId direkt!
  local rawEffect, rank
  if type(id) == "number" then
    rawEffect, rank = GetSpellName(id, bookType or BOOKTYPE_SPELL)
  elseif type(id) == "string" then
    rawEffect, rank = GetSpellName(id)
  end
  
  if not rawEffect then return end
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = tonumber(num) or 0
  end
  
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

hooksecurefunc("CastSpellByName", function(effect, target)
  if isEnhancedMode then return end
  if not effect or effect == "" then return end
  
  -- GetSpellName akzeptiert jetzt auch Spell-Namen direkt
  local rawEffect, rank = GetSpellName(effect)
  if not rawEffect then return end
  
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = tonumber(num) or 0
  end
  
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

hooksecurefunc("UseAction", function(slot, target, button)
  if isEnhancedMode then return end
  if GetActionText(slot) or not IsCurrentAction(slot) then return end
  if not slot or slot <= 0 then return end
  
  scanner:SetAction(slot)
  local rawEffect, rank = scanner:Line(1)
  if not rawEffect then return end
  
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = tonumber(num) or 0
  end
  
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

function libdebuff:UnitDebuff(unit, id)
  local unitname = UnitName(unit)
  local unitlevel = UnitLevel(unit)
  local texture, stacks, dtype = UnitDebuff(unit, id)
  local duration, timeleft = nil, -1
  local rank = nil
  local caster = nil
  local effect

  if texture then
    scanner:SetUnitDebuff(unit, id)
    effect = scanner:Line(1) or ""
  end

  -- Enhanced Mode: Use slot-based matching
  if isEnhancedMode and effect then
    local _, unitGUID = UnitExists(unit)
    local playerGUID = GetPlayerGUID()
    
    if unitGUID and IsValidGUID(unitGUID) and debuffSlots[unitGUID] and debuffSlots[unitGUID][id] then
      local slotData = debuffSlots[unitGUID][id]
      local spellName = slotData.spellName
      local casterGUID = slotData.casterGUID
      
      -- Verify the spell name matches
      if spellName == effect and enhancedDebuffs[unitGUID] and enhancedDebuffs[unitGUID][spellName] then
        local data = enhancedDebuffs[unitGUID][spellName][casterGUID]
        
        if data and data.startTime and data.duration then
          local now = GetTime()
          local remaining = (data.startTime + data.duration) - now
          
          if remaining > 0 then
            duration = data.duration
            timeleft = remaining
            caster = (casterGUID == playerGUID) and "player" or nil
            return effect, rank, texture, stacks, dtype, duration, timeleft, caster
          end
        end
      end
    end
    
    -- Fallback: No slot match found
    return effect, rank, texture, stacks, dtype, nil, -1, nil
  end

  -- Legacy Mode: ONLY if Enhanced Mode is OFF
  if not isEnhancedMode then
    local data = libdebuff.objects[unitname] and libdebuff.objects[unitname][unitlevel]
    data = data or libdebuff.objects[unitname] and libdebuff.objects[unitname][0]

    if data and data[effect] then
      if data[effect].duration and data[effect].start and data[effect].duration + data[effect].start > GetTime() then
        duration = data[effect].duration
        timeleft = duration + data[effect].start - GetTime()
        caster = data[effect].caster
      else
        data[effect] = nil
      end
    end
  end

  return effect, rank, texture, stacks, dtype, duration, timeleft, caster
end

-- Helper function to expose enhancedDebuffs table for direct scanning
function libdebuff:GetEnhancedDebuffs(targetGUID)
  if not isEnhancedMode or not targetGUID then return nil end
  return enhancedDebuffs[targetGUID]
end

-- Helper function to check if a buff/debuff is shared
function libdebuff:IsSharedAura(spellName)
  if not spellName then return false end
  return sharedBuffs[spellName] or sharedDebuffs[spellName]
end

-- Helper function to check if enhanced debug is enabled
function libdebuff:IsDebugEnabled()
  return enhancedDebugEnabled
end

local cache = {}
function libdebuff:UnitOwnDebuff(unit, id)
  -- clean cache
  for k, v in pairs(cache) do cache[k] = nil end

  -- detect own debuffs
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

function libdebuff:UnitSmartDebuff(unit, id)
  -- clean cache
  for k, v in pairs(cache) do cache[k] = nil end

  -- detect own debuffs + shared debuffs (Enhanced Mode logic)
  local count = 1
  for i=1,16 do
    local effect, rank, texture, stacks, dtype, duration, timeleft, caster = libdebuff:UnitDebuff(unit, i)
    -- Show if: own debuff OR shared debuff (CoA, Sunder, etc.)
    if effect and not cache[effect] and (caster == "player" or sharedDebuffs[effect]) then
      cache[effect] = true

      if count == id then
        return effect, rank, texture, stacks, dtype, duration, timeleft, caster
      else
        count = count + 1
      end
    end
  end
end

function libdebuff:UnitBuff(unit, id)
  local unitname = UnitName(unit)
  local unitlevel = UnitLevel(unit)
  local texture, stacks = UnitBuff(unit, id)
  local duration, timeleft = nil, -1
  local rank = nil
  local caster = nil
  local effect

  -- Enhanced Mode: Texture match first (FAST), then tooltip fallback (LEARNING)
  if isEnhancedMode and texture then
    local _, unitGUID = UnitExists(unit)
    local playerGUID = GetPlayerGUID()
    
    if unitGUID and IsValidGUID(unitGUID) and enhancedDebuffs[unitGUID] then
      local now = GetTime()
      local bestData = nil
      local bestRemaining = 0
      local bestCaster = nil
      local bestSpellName = nil
      local bestCasterGUID = nil
      
      -- PHASE 1: Try texture match (FAST - no tooltip!)
      for spellName, casters in pairs(enhancedDebuffs[unitGUID]) do
        local isShared = sharedBuffs[spellName] or sharedDebuffs[spellName]
        
        if isShared then
          for casterGUID, data in pairs(casters) do
            if data and data.texture and data.texture == texture and data.startTime and data.duration then
              local remaining = (data.startTime + data.duration) - now
              if remaining > 0 and remaining > bestRemaining then
                bestRemaining = remaining
                bestData = data
                bestCaster = (casterGUID == playerGUID) and "player" or "other"
                bestSpellName = spellName
                bestCasterGUID = casterGUID
              end
            end
          end
        else
          local data = casters[playerGUID]
          if data and data.texture and data.texture == texture and data.startTime and data.duration then
            local remaining = (data.startTime + data.duration) - now
            if remaining > 0 and remaining > bestRemaining then
              bestRemaining = remaining
              bestData = data
              bestCaster = "player"
              bestSpellName = spellName
              bestCasterGUID = playerGUID
            end
          end
        end
      end
      
      -- PHASE 2: No texture match? Try tooltip scan (LEARNING)
      if not bestData then
        scanner:SetUnitBuff(unit, id)
        effect = scanner:Line(1) or ""
        
        if effect and enhancedDebuffs[unitGUID][effect] then
          local isShared = sharedBuffs[effect] or sharedDebuffs[effect]
          
          if isShared then
            for casterGUID, data in pairs(enhancedDebuffs[unitGUID][effect]) do
              if data and data.startTime and data.duration then
                local remaining = (data.startTime + data.duration) - now
                if remaining > 0 and remaining > bestRemaining then
                  bestRemaining = remaining
                  bestData = data
                  bestCaster = (casterGUID == playerGUID) and "player" or "other"
                  bestSpellName = effect
                  bestCasterGUID = casterGUID
                end
              end
            end
          else
            local data = enhancedDebuffs[unitGUID][effect][playerGUID]
            if data and data.startTime and data.duration then
              local remaining = (data.startTime + data.duration) - now
              if remaining > 0 then
                bestRemaining = remaining
                bestData = data
                bestCaster = "player"
                bestSpellName = effect
                bestCasterGUID = playerGUID
              end
            end
          end
          
          -- LEARN: Cache texture for next time!
          if bestData and bestCasterGUID then
            enhancedDebuffs[unitGUID][effect][bestCasterGUID].texture = texture
            
            -- Save to new spell_cache with spellID
            local spellID = bestData.spellID
            if spellID then
              CacheSpellData(spellID, effect, texture)
            else
              -- Fallback: Save to old buff_icons for legacy compatibility
              pfUI_cache.buff_icons = pfUI_cache.buff_icons or {}
              if not pfUI_cache.buff_icons[texture] then
                pfUI_cache.buff_icons[texture] = effect
                nameToTexture = nil -- Invalidate cache
                if enhancedDebugEnabled then
                  DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Cache]|r " .. effect .. " texture saved to legacy buff_icons (no spellID)")
                end
              end
            end
          end
        end
      end
      
      -- Return result
      if bestData then
        duration = bestData.duration
        timeleft = bestRemaining
        caster = bestCaster
        effect = bestSpellName
        return effect, rank, texture, stacks, nil, duration, timeleft, caster
      end
    end
  end
  
  -- Legacy Mode: Use Tooltip Scanner
  if texture then
    scanner:SetUnitBuff(unit, id)
    effect = scanner:Line(1) or ""
  end

  -- Legacy/Player buffs: No tracking
  return effect, rank, texture, stacks, nil, nil, -1, nil
end

-- add libdebuff to pfUI API
pfUI.api.libdebuff = libdebuff