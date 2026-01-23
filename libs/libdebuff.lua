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
local hasNampower = GetNampowerVersion ~= nil

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

-- pendingCasts: [targetGUID][spellName] = {casterGuid, time} (temporary storage from UNIT_CASTEVENT)
local pendingCasts = {}

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
local debugStats = {
  enabled = false,
  aura_cast = 0,
  debuff_added_ours = 0,
  debuff_added_other = 0,
  debuff_removed_ours = 0,
  debuff_removed_other = 0,
  shift_down = 0,
  shift_up = 0,
}

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
  if debugStats.enabled then
    debugStats.shift_down = debugStats.shift_down + 1
  end
  
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

-- Shift all slots up when a new one is added
local function ShiftSlotsUp(guid, newSlot)
  if debugStats.enabled then
    debugStats.shift_up = debugStats.shift_up + 1
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
  if not ownDebuffs[guid] then return end
  
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

-- Initial scan of all debuff slots on target change
local function InitializeTargetSlots(guid)
  if not guid or not GetUnitField or not SpellInfo then return end
  
  -- Clear existing slots for this target
  allSlots[guid] = {}
  
  if debugStats.enabled then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ffff[INITIAL SCAN]|r Scanning target GUID=%s", GetDebugTimestamp(), DebugGuid(guid)))
  end
  
  local myGuid = GetPlayerGUID()
  local slotCount = 0
  
  -- Get all auras (buffs + debuffs) for this unit
  local auras = GetUnitField(guid, "aura")
  if not auras then 
    if debugStats.enabled then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[INITIAL SCAN]|r GetUnitField failed!")
    end
    return 
  end
  
  -- Scan debuff slots only (aura slots 33-48 = debuff slots 1-16)
  for auraSlot = 33, 48 do
    local spellId = auras[auraSlot]
    
    if spellId and spellId > 0 then
      -- Get spell name from ID
      local spellName = SpellInfo(spellId)
      
      if spellName and spellName ~= "" then
        slotCount = slotCount + 1
        
        -- Convert aura slot (33-48) to debuff slot (1-16)
        local debuffSlot = auraSlot - 32
        
        -- Check if this is our debuff
        local isOurs = false
        if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
          isOurs = true
          -- Update slot in ownDebuffs
          ownDebuffs[guid][spellName].slot = debuffSlot
          -- Update ownSlots
          ownSlots[guid] = ownSlots[guid] or {}
          ownSlots[guid][debuffSlot] = spellName
        end
        
        -- Add to allSlots (using debuff slot numbering)
        allSlots[guid][debuffSlot] = {
          spellName = spellName,
          casterGuid = isOurs and myGuid or nil, -- We only know caster for our debuffs
          isOurs = isOurs
        }
        
        if debugStats.enabled then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[SLOT INIT]|r slot=%d %s (ID=%d) isOurs=%s", 
            debuffSlot, spellName, spellId, tostring(isOurs)))
        end
      end
    end
  end
  
  if debugStats.enabled then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ffff[INITIAL SCAN DONE]|r Found %d debuff slots", GetDebugTimestamp(), slotCount))
  end
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

-- Cleanup out of range units (every 30s)
local function CleanupOutOfRangeUnits()
  local now = GetTime()
  if now - lastRangeCheck < 30 then return end
  lastRangeCheck = now
  
  for guid in pairs(ownDebuffs) do
    local exists = UnitExists and UnitExists(guid)
    if not exists then
      ownDebuffs[guid] = nil
      if ownSlots[guid] then ownSlots[guid] = nil end
      if allSlots[guid] then allSlots[guid] = nil end
      if allAuraCasts[guid] then allAuraCasts[guid] = nil end
      if objectsByGuid[guid] then objectsByGuid[guid] = nil end
    end
  end
end

-- Speichert die Ranks der zuletzt gecasteten Spells (bleibt länger als pending)
local lastCastRanks = {}

-- Speichert Spells die gefailed sind (miss/dodge/parry/etc.) für 1 Sekunde
local lastFailedSpells = {}

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
  -- paladin seal refresh
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

  -- Add Combat Log
  elseif event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE" or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
    local unit, effect = cmatch(arg1, AURAADDEDOTHERHARMFUL)
    if unit and effect then
      local unitlevel = UnitName("target") == unit and UnitLevel("target") or 0
      if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
        libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)  -- Explizit nil für rank
      end
    end

  -- Add Missing Buffs by Iteration
  elseif ( event == "UNIT_AURA" and arg1 == "target" ) or event == "PLAYER_TARGET_CHANGED" then
    for i=1, 16 do
      local effect, rank, texture, stacks, dtype, duration, timeleft = libdebuff:UnitDebuff("target", i)

      -- abort when no further debuff was found
      if not texture then return end

      if texture and effect and effect ~= "" then
        -- don't overwrite existing timers
        local unitlevel = UnitLevel("target") or 0
        local unit = UnitName("target")
        if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
          libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)  -- Explizit nil für rank
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
local lastUnitDebuffLog = {}
local UNITDEBUFF_LOG_THROTTLE = 5 -- seconds

function libdebuff:UnitDebuff(unit, id)
  local unitname = UnitName(unit)
  local unitlevel = UnitLevel(unit)
  local texture, stacks, dtype = UnitDebuff(unit, id)
  local duration, timeleft = nil, -1
  local rank = nil -- no backport
  local caster = nil -- experimental
  local effect

  if texture then
    scanner:SetUnitDebuff(unit, id)
    effect = scanner:Line(1) or ""
  end

  -- Nampower: Check slots with allSlots
  if hasNampower and UnitExists and effect then
    local _, guid = UnitExists(unit)
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
          DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ffff[UNITDEBUFF READ]|r slot=%d %s isOurs=%s caster=%s", 
            GetDebugTimestamp(), id, spellName, tostring(isOurs), DebugGuid(slotData.casterGuid)))
        end
      end
      
      -- Verify spell name matches (safety check)
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
          end
        else
          -- This slot is from another player - show their timer if available
          local otherCasterGuid = slotData.casterGuid
          
          if otherCasterGuid and allAuraCasts[guid] and allAuraCasts[guid][spellName] and allAuraCasts[guid][spellName][otherCasterGuid] then
            local data = allAuraCasts[guid][spellName][otherCasterGuid]
            local remaining = (data.startTime + data.duration) - GetTime()
            -- Only show timer if duration is known (not 0)
            if remaining > 0 and data.duration > 0 then
              duration = data.duration
              timeleft = remaining
              caster = "other"
              rank = data.rank
            end
          elseif debugStats.enabled and shouldLog then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[CASTER NOT IN ALLAURACASTS]|r %s caster=%s", 
              spellName, DebugGuid(otherCasterGuid)))
          end
        end
      end
    end
    return effect, rank, texture, stacks, dtype, duration, timeleft, caster
  end

  -- read level based debuff table
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

  return effect, rank, texture, stacks, dtype, duration, timeleft, caster
end

local cache = {}
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
        if timeleft > -1 then
          cache[spellName] = true
          if count == id then
            local texture = data.texture or "Interface\\Icons\\Spell_Shadow_CurseOfTongues"
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
  frame:RegisterEvent("UNIT_CASTEVENT")
  frame:RegisterEvent("AURA_CAST_ON_SELF")
  frame:RegisterEvent("AURA_CAST_ON_OTHER")
  frame:RegisterEvent("DEBUFF_ADDED_OTHER")
  frame:RegisterEvent("DEBUFF_REMOVED_OTHER")
  frame:RegisterEvent("PLAYER_TARGET_CHANGED")
  
  frame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
      GetPlayerGUID()
      UpdateCarnageRank()
      
    elseif event == "PLAYER_TALENT_UPDATE" then
      UpdateCarnageRank()
      
    elseif event == "PLAYER_COMBO_POINTS" then
      if class ~= "DRUID" then return end
      local current = GetComboPoints("player", "target") or 0
      if current < currentComboPoints then
        lastSpentComboPoints = currentComboPoints
        lastSpentTime = GetTime()
      end
      currentComboPoints = current
      
    elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
      local spellId = arg1
      local casterGuid = arg2
      local targetGuid = arg3
      local durationMs = arg8
      
      -- SpellInfo returns: name, rank, texture, minrange, maxrange
      if not SpellInfo then return end
      
      local spellName, spellRankString, texture = SpellInfo(spellId)
      if not spellName then return end
      
      -- Duplicate filter: Same spell + caster + target within 0.1s
      local now = GetTime()
      local signature = string.format("%s:%s:%s", tostring(spellId), tostring(casterGuid), tostring(targetGuid))
      if signature == lastEventSignature and (now - lastEventTime) < 0.1 then
        return -- Duplicate, skip!
      end
      lastEventSignature = signature
      lastEventTime = now
      
      -- Fallback texture
      if not texture then
        texture = arg5 or (pfUI_cache and pfUI_cache.debuff_icons and pfUI_cache.debuff_icons[spellName]) or "Interface\\Icons\\Spell_Shadow_CurseOfTongues"
      end
      
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
      
      -- CP-based spells: GetDuration (ONLY for our casts!)
      if isOurs and duration == 0 and combopointAbilities[spellName] then
        duration = libdebuff:GetDuration(spellName, rankNum)
      end
      
      -- CP-based spells: Force duration=0 for other players (unknown duration!)
      if not isOurs and combopointAbilities[spellName] then
        duration = 0
        
        if debugStats.enabled then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[CP-ABILITY OTHER]|r %s duration forced to 0 (unknown)", spellName))
        end
      end
      
      -- Store ALL aura casts (nested by casterGuid for multiple same-spell debuffs)
      if targetGuid and targetGuid ~= "" and targetGuid ~= "0x0000000000000000" then
        allAuraCasts[targetGuid] = allAuraCasts[targetGuid] or {}
        allAuraCasts[targetGuid][spellName] = allAuraCasts[targetGuid][spellName] or {}
        
        if debugStats.enabled and IsCurrentTarget(targetGuid) then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ffff[AURA_CAST STORE]|r %s caster=%s isOurs=%s", 
            GetDebugTimestamp(), spellName, DebugGuid(casterGuid), tostring(isOurs)))
        end
        
        -- Check if this is a self-overwrite spell (clears all OTHER casters)
        if selfOverwriteDebuffs[spellName] then
          if debugStats.enabled and IsCurrentTarget(targetGuid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[SELF-OVERWRITE CHECK]|r %s is in selfOverwriteDebuffs", spellName))
          end
          
          -- Clear all OTHER casters (keep ours if we're recasting)
          local oldCasters = {}
          for otherCaster in pairs(allAuraCasts[targetGuid][spellName]) do
            if otherCaster ~= casterGuid then
              table.insert(oldCasters, otherCaster)
              
              if debugStats.enabled then
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
                
                if debugStats.enabled then
                  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[ALLSLOTS OVERWRITE]|r slot=%d updated to caster=%s isOurs=%s", 
                    slot, DebugGuid(casterGuid), tostring(isOurs)))
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
            
            if debugStats.enabled then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[OWNDBUFFS CLEARED]|r %s removed (not ours anymore)", spellName))
            end
          end
          
          if debugStats.enabled and table.getn(oldCasters) == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[SELF-OVERWRITE SKIP]|r No other casters found to clear")
          end
        end
        
        allAuraCasts[targetGuid][spellName][casterGuid] = {
          startTime = startTime,
          duration = duration, -- Will be 0 for other players' CP spells
          rank = spellRankString
        }
        
        -- CRITICAL: Force refresh Target Frame AFTER adding to allAuraCasts!
        if selfOverwriteDebuffs[spellName] and pfUI and pfUI.uf and pfUI.uf.target then
          pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
          
          if debugStats.enabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[TARGET REFRESHED]|r RefreshUnit called")
          end
        end
        
        -- Check if this spell overwrites another variant (e.g., Faerie Fire <-> Faerie Fire (Feral))
        if debuffOverwritePairs[spellName] then
          local otherVariant = debuffOverwritePairs[spellName]
          
          if debugStats.enabled then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[OVERWRITE CHECK]|r %s -> %s for caster %s", 
              spellName, otherVariant, DebugGuid(casterGuid)))
          end
          
          -- Remove the other variant from allAuraCasts (for THIS caster only!)
          if allAuraCasts[targetGuid][otherVariant] and allAuraCasts[targetGuid][otherVariant][casterGuid] then
            allAuraCasts[targetGuid][otherVariant][casterGuid] = nil
            
            if debugStats.enabled then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[OVERWRITE CLEARED]|r Removed %s for caster %s", 
                otherVariant, DebugGuid(casterGuid)))
            end
          elseif debugStats.enabled then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[OVERWRITE SKIP]|r No %s found for caster %s", 
              otherVariant, DebugGuid(casterGuid)))
          end
        end
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
      data.rank = spellRankString
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
      
    elseif event == "UNIT_CASTEVENT" then
      local casterGuid = arg1
      local targetGuid = arg2
      local castEvent = arg3
      local spellId = arg4
      
      -- Nur "CAST" Events (nicht "START", "FAIL", etc.)
      if castEvent ~= "CAST" then return end
      
      local spellName = SpellInfo and SpellInfo(spellId)
      if not spellName then return end
      
      -- Store in pendingCasts for later use in DEBUFF_ADDED
      if targetGuid then
        pendingCasts[targetGuid] = pendingCasts[targetGuid] or {}
        pendingCasts[targetGuid][spellName] = {
          casterGuid = casterGuid,
          time = GetTime()
        }
      end
      
      -- Carnage: Ferocious Bite refresht Rip & Rake (nur für uns)
      if class == "DRUID" and carnageRank == 2 and spellName == "Ferocious Bite" then
        local myGuid = GetPlayerGUID()
        if myGuid and casterGuid == myGuid then
          -- Refresh in ownDebuffs
          if targetGuid and ownDebuffs[targetGuid] then
            if ownDebuffs[targetGuid]["Rip"] then
              ownDebuffs[targetGuid]["Rip"].startTime = GetTime()
            end
            if ownDebuffs[targetGuid]["Rake"] then
              ownDebuffs[targetGuid]["Rake"].startTime = GetTime()
            end
          end
        end
      end
      
    elseif event == "DEBUFF_ADDED_OTHER" then
      local guid, slot, spellId, stacks = arg1, arg2, arg3, arg4
      
      local spellName = SpellInfo and SpellInfo(spellId)
      if not spellName then return end
      
      if debugStats.enabled and IsCurrentTarget(guid) then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cff00ff00[DEBUFF_ADDED]|r slot=%d %s stacks=%d guid=%s", 
          GetDebugTimestamp(), slot, spellName, stacks, DebugGuid(guid)))
      end
      
      -- Skip if unit is dead
      if UnitIsDead and UnitIsDead(guid) then return end
      
      -- Get casterGuid from pendingCasts (UNIT_CASTEVENT)
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
      
      if debugStats.enabled then
        if isOurs then
          debugStats.debuff_added_ours = debugStats.debuff_added_ours + 1
        else
          debugStats.debuff_added_other = debugStats.debuff_added_other + 1
        end
      end
      
      -- ALWAYS shift if ANY slot >= this slot exists
      allSlots[guid] = allSlots[guid] or {}
      ownSlots[guid] = ownSlots[guid] or {}
      
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
      
      -- Add to allSlots (for ALL debuffs)
      allSlots[guid][slot] = {
        spellName = spellName,
        casterGuid = casterGuid,
        isOurs = isOurs
      }
      
      if debugStats.enabled and IsCurrentTarget(guid) then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[ALLSLOTS SET]|r slot=%d %s caster=%s isOurs=%s", 
          slot, spellName, DebugGuid(casterGuid), tostring(isOurs)))
      end
      
      -- Add to ownSlots if ours
      if isOurs then
        ownSlots[guid][slot] = spellName
        ownDebuffs[guid][spellName].slot = slot
      end
      
      -- Cleanup orphaned debuffs
      CleanupOrphanedDebuffs(guid)
      CleanupPendingCasts()
      
    elseif event == "DEBUFF_REMOVED_OTHER" then
      local guid, slot, spellId = arg1, arg2, arg3
      
      local spellName = SpellInfo and SpellInfo(spellId) or "?"
      
      -- Skip if unit is dead (cleanup handled separately)
      if UnitIsDead and UnitIsDead(guid) then return end
      
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
        
        if debugStats.enabled and IsCurrentTarget(guid) then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("%s |cffff0000[DEBUFF_REMOVED]|r slot=%d %s caster=%s", 
            GetDebugTimestamp(), slot, spellName, DebugGuid(removedCasterGuid)))
        end
        
        -- Also remove from allAuraCasts
        if removedCasterGuid and allAuraCasts[guid] and allAuraCasts[guid][spellName] then
          if allAuraCasts[guid][spellName][removedCasterGuid] then
            allAuraCasts[guid][spellName][removedCasterGuid] = nil
            
            if debugStats.enabled and IsCurrentTarget(guid) then
              DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[AURACAST CLEARED]|r Removed %s for caster %s from allAuraCasts", 
                spellName, DebugGuid(removedCasterGuid)))
            end
          elseif debugStats.enabled and IsCurrentTarget(guid) then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[AURACAST MISSING]|r %s caster %s not found in allAuraCasts", 
              spellName, DebugGuid(removedCasterGuid)))
          end
        end
        
        allSlots[guid][slot] = nil
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
      
      -- Cleanup
      CleanupOrphanedDebuffs(guid)
      
    elseif event == "PLAYER_TARGET_CHANGED" then
      -- Initialize slots when targeting a new unit
      if not UnitExists then return end
      local _, targetGuid = UnitExists("target")
      
      if targetGuid and targetGuid ~= "" and targetGuid ~= "0x0000000000000000" then
        InitializeTargetSlots(targetGuid)
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

-- Debug command: /shifttest
_G.SLASH_SHIFTTEST1 = "/shifttest"
_G.SlashCmdList["SHIFTTEST"] = function(msg)
  msg = string.lower(msg or "")
  
  if msg == "start" then
    debugStats.enabled = true
    -- Reset stats
    for k in pairs(debugStats) do
      if k ~= "enabled" then debugStats[k] = 0 end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ShiftTest]|r Tracking STARTED")
    
  elseif msg == "stop" then
    debugStats.enabled = false
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

