-- ================================================================
-- deliveryVehicleUnlock.lua
-- Universal unlock flag activator for custom delivery vehicle types
-- ================================================================

local M = {}
local logTag = "deliveryVehicleUnlock"

local function pretty(msg)
  print(string.format("[%s] >>> %s", logTag, msg))
  log("I", logTag, msg)
end

-- List of unlock flags to always want to enable.
local flagsToUnlock = {
  "busVeh",     
  "pickupVeh"
    
}

local function unlockFlags()
  if career_modules_unlockFlags and career_modules_unlockFlags.setFlag then
    for _, flag in ipairs(flagsToUnlock) do
      career_modules_unlockFlags.setFlag(flag, true)
      pretty(flag .. " set to TRUE")
    end
  else
    pretty("unlockFlags module not ready yet, retrying...")
    core_jobsystem.create(function(job)
      local waited = 0
      while (not career_modules_unlockFlags or not career_modules_unlockFlags.setFlag) and waited < 10 do
        job.sleep(1)
        waited = waited + 1
      end
      if career_modules_unlockFlags and career_modules_unlockFlags.setFlag then
        for _, flag in ipairs(flagsToUnlock) do
          career_modules_unlockFlags.setFlag(flag, true)
          pretty(flag .. " set to TRUE (delayed)")
        end
      else
        pretty("unlockFlags module never became available.")
      end
    end)
  end
end

local function onCareerModulesActivated()
  unlockFlags()
end

M.onCareerModulesActivated = onCareerModulesActivated

print("[deliveryVehicleUnlock] >>> Loaded and waiting for career init...")
return M
