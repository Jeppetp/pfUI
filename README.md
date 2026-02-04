# pfUI Enhanced v7.6.0 - Duplicate Debuff Fix

## 🎯 Was ist gefixt

### **HAUPTFIX: Duplicate Debuff Display**
- ✅ **Keine doppelten Debuffs mehr** nach Slot-Shifts (z.B. Expose Armor 2x)
- ✅ **Grace Period (0.5s)** verhindert Rescan-Spam nach DEBUFF_REMOVED
- ✅ **UnitOwnDebuff Sortierung** nach Slot statt pairs() - verhindert falsche Reihenfolge
- ✅ **Deduplication** verhindert doppelte DEBUFF_ADDED Events
- ✅ **libdebuff.objects Fallback Fix** verhindert stale data nach Slot-Shifts

### **Root Cause:**
WoW 1.12.1 shiftet Debuff-Slots NICHT automatisch:
- Game: Slot 1=Hemorrhage, Slot 2=[LEER], Slot 3=Expose Armor
- allSlots: Slot 1=Hemorrhage, Slot 2=Expose Armor, Slot 3=nil (WIR shiften!)
- **Problem:** BuffWatch scannte Slot 3 → alte Daten aus libdebuff.objects → Duplikat!
- **Lösung:** return nil statt libdebuff.objects Fallback wenn allSlots leer

---

## 📦 Installation

### **Dateien ersetzen:**

1. **libs/libdebuff.lua** → Ersetze in `pfUI/libs/`
2. **modules/buffwatch.lua** → Ersetze in `pfUI/modules/`
3. **libs/libpredict.lua** → Ersetze in `pfUI/libs/`

### **Nach Installation:**
1. `/reload` im Spiel
2. Teste mit mehreren Debuffs (Hemorrhage, Rupture, Expose Armor)
3. Warte bis einer expired
4. → Sollten keine Duplikate mehr auftauchen!

---

## 📋 Changelog v7.6.0

### **libdebuff.lua**
- **[FIX]** Grace Period (0.5s) nach DEBUFF_REMOVED → verhindert Rescan-Spam
- **[FIX]** UnitOwnDebuff sortiert nach Slot statt pairs() → korrekte Reihenfolge
- **[FIX]** Deduplication für DEBUFF_ADDED_OTHER Events
- **[FIX]** return nil statt libdebuff.objects Fallback → verhindert stale data
- **[CLEANUP]** lastDebuffRemoved Tracking für Grace Period

### **buffwatch.lua**
- **[UNCHANGED]** Original Version (keine Änderungen nötig!)

### **libpredict.lua**
- **[UNCHANGED]** Original Version (keine Änderungen nötig!)

---

## 🔧 Technische Details

### **Grace Period:**
```lua
// In UnitDebuff, nach allSlots Check:
local timeSinceRemoval = recentRemovals[guid] and (now - recentRemovals[guid]) or 999
if timeSinceRemoval < 0.5 then
  return nil  // Suppress rescan during grace period
end
```

**Warum:** WoW's `UnitDebuff()` API gibt alte Slot-Nummern für ~0.5s zurück nach DEBUFF_REMOVED. Grace Period verhindert Rescans während dieser Zeit.

### **UnitOwnDebuff Sortierung:**
```lua
// Statt pairs() direkt nutzen:
local sortedDebuffs = {}
for spellName, data in pairs(ownDebuffs[guid]) do
  table.insert(sortedDebuffs, {spellName = spellName, data = data})
end

table.sort(sortedDebuffs, function(a, b)
  return a.data.slot < b.data.slot
end)
```

**Warum:** `pairs()` garantiert KEINE Reihenfolge. Sortierung nach Slot sichert korrekte Position.

### **libdebuff.objects Fallback:**
```lua
// ALT (mit Bug):
if allSlots[guid] and allSlots[guid][id] then
  // return timer
else
  // Fall through zu libdebuff.objects ← STALE DATA!
end

// NEU (gefixt):
if allSlots[guid] and allSlots[guid][id] then
  // return timer
else
  return nil  ← Verhindert stale data!
end
```

**Warum:** Nach Slot-Shift enthält `libdebuff.objects` noch alte Slot-Nummern. `return nil` verhindert dass BuffWatch diese alten Daten bekommt.

---

## 🚀 Zukunft: Scanner-System (v7.7.0)

### **Was kommt als Nächstes:**
Die COMPLETE Lösung: Scanner-basiertes Timer-Matching (siehe `docs/LIBDEBUFF_REFACTOR_GUIDE.md`)

**Konzept:**
1. Scanner (GetUnitField alle 200ms) → aktuelle Slots
2. AURA_CAST Events → Timer-Daten
3. Slot-Assignment → matcht Timer zu Slots
4. **KEIN Rescan mehr nötig!**

**Proof-of-Concept:** `docs/TimerMatchingTracker.lua` (funktioniert perfekt!)

**Status:** Ready for Integration (größerer Refactor)

---

## 📞 Kontakt

**Developer:** Gunther  
**Project:** pfUI Enhanced for Turtle WoW  
**Version:** 7.6.0 (Duplicate Debuff Fix)  

**Bekannte Issues:**
- Rescan-Spam ist reduziert, aber nicht komplett weg (Grace Period hilft)
- Komplette Lösung: Scanner-System in v7.7.0

---

## ✅ Testing

**Test-Szenario:**
1. Apply Hemorrhage (Slot 1)
2. Apply Rupture (Slot 2)
3. Apply Expose Armor (Slot 3)
4. Warte bis Rupture expired
5. **Erwartetes Ergebnis:**
   - Hemorrhage: Slot 1
   - Expose Armor: Slot 2 (shifted down)
   - **KEIN doppeltes Expose Armor!** ✅

**Debug Commands:**
```lua
/shifttest start  -- Aktiviert Debug-Ausgaben
/shifttest stop   -- Deaktiviert Debug-Ausgaben
/shifttest dump   -- Zeigt aktuellen State
```

---

**Good luck! 🎯**
