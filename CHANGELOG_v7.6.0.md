# pfUI Enhanced v7.6.0 - Changelog

## 🎯 CRITICAL FIX: Duplicate Debuff Display

**Release Date:** February 4, 2026

---

## ✅ Fixed Issues

### **Duplicate Debuff Display After Slot Shifts**
**Problem:**
After a debuff expired and slots shifted down, BuffWatch would sometimes show the same debuff twice (e.g., "Expose Armor" appearing in both Slot 2 and Slot 3).

**Root Cause:**
WoW 1.12.1 does NOT auto-shift debuff slots in the game engine:
- After Rupture (Slot 2) expires: Game shows Slot 1=Hemorrhage, Slot 2=[EMPTY], Slot 3=Expose Armor
- pfUI's allSlots correctly shifts: Slot 1=Hemorrhage, Slot 2=Expose Armor, Slot 3=nil
- BuffWatch scanned Slot 3, got stale data from GetUnitField → showed duplicate Expose Armor

**Solution:**
Use Blizzard's `UnitDebuff()` API as "source of truth" for slot existence:
- `UnitDebuff()` returns `nil` when slot is truly empty (no stale data)
- GetUnitField provides spell IDs but can have delayed updates
- allSlots provides accurate timer data
- Perfect combination! ✅

---

## 📋 Technical Changes

### **libs/libdebuff.lua (v7.6.0)**
- **FIXED:** Use Blizzard `UnitDebuff()` for slot existence check
- **FIXED:** Prevent stale GetUnitField data from triggering rescans
- **IMPROVED:** Throttled UNITDEBUFF READ logging (every 5s instead of spam)
- **IMPROVED:** Better SLOT MISMATCH handling with expired debuff cleanup
- **IMPROVED:** Validation consistency checks after slot shifts

### **modules/buffwatch.lua**
- **NO CHANGES:** Original version works perfectly with fixed libdebuff.lua

### **libs/libpredict.lua**
- **NO CHANGES:** Original version

---

## 🎮 How to Install

1. **Backup your current pfUI folder** (always!)
2. Replace these files:
   - `pfUI/libs/libdebuff.lua`
   - `pfUI/modules/buffwatch.lua` (optional, unchanged)
   - `pfUI/libs/libpredict.lua` (optional, unchanged)
3. `/reload` in-game
4. Test with multiple debuffs

---

## 🧪 Testing Performed

**Test Scenario:**
1. Applied 5 debuffs: Moonfire, Insect Swarm, Faerie Fire, Rake, Rip
2. Waited for debuffs to expire naturally
3. Observed slot shifting behavior

**Results:**
- ✅ NO duplicate debuffs displayed
- ✅ Correct slot shifting (6→5→4→3→2→1)
- ✅ No rescan spam in logs
- ✅ No flickering or disappearing timers
- ✅ All debuff timers accurate

---

## ⚠️ Known Limitations

### **AoE Channel Spells (Not a Bug)**
Hurricane, Blizzard, Rain of Fire show:
```
[INVALID CASTERGUID] slot=X Hurricane caster=nil
[INCONSISTENCY] Hurricane has INVALID casterGuid=nil
```

**This is NORMAL:** Nampower does not fire AURA_CAST events for channeled AoE spells. These debuffs are tracked via DEBUFF_ADDED_OTHER without casterGuid. This does NOT affect functionality or cause duplicate displays.

---

## 🚀 Future Plans (v7.7.0)

**Scanner-Based Timer Matching System:**
See `docs/LIBDEBUFF_REFACTOR_GUIDE.md` for details.

**Proof-of-Concept:** `docs/TimerMatchingTracker.lua` (fully functional!)

**Benefits:**
- Eliminate ALL rescan-based logic
- Pure event + scanner hybrid approach
- 100% accuracy for multi-caster scenarios
- Cleaner code architecture

**Status:** Ready for integration, requires larger refactor

---

## 📞 Support

**Project:** pfUI Enhanced for Turtle WoW  
**Version:** 7.6.0  
**Tested on:** Nampower v2.27.2, SuperWoW, UnitXP  

**Issues?** Please test with `/shifttest start` to generate debug logs.

---

## 🎉 Credits

**Developer:** Gunther  
**Special Thanks:** Community testers on Turtle WoW  

---

**Enjoy bug-free debuff tracking!** 🎯
