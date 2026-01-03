-- ================================
-- Bus Work 
-- ================================
print("[bus] parsing bus.lua...")

if not core_groundMarkers and not rawget(_G, "core_groundMarkers") then
  print("[bus] Core not ready yet, deferring gameplay_bus initialization...")
  return {
    onExtensionLoaded = function()
      print("[bus] Retrying gameplay_bus load after core init...")
      extensions.reload('career_modules_bus')
    end
  }
end

local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities'}

local core_groundMarkers = require('core/groundMarkers')
local core_vehicles      = require('core.vehicles')

-- ================================
-- STATE
-- ================================
local currentStopIndex        = nil
local stopTriggers            = {}
local dwellTimer              = nil
local dwellDuration           = 10
local consecutiveStops        = 0
local currentRouteActive      = false
local accumulatedReward       = 0
local passengersOnboard       = 0
local activeBusID             = nil
local routeInitialized        = false
local totalStopsCompleted     = 0
local routeCooldown           = 0
local currentVehiclePartsTree = nil

-- Stop-settle state
local stopMonitorActive       = false
local stopSettleTimer         = 0
local stopSettleDelay         = 2.5

-- Rough ride / tips
local roughRide               = 0
local lastVelocity            = nil
local tipTotal                = 0

-- Boarding / deboarding tallies (per stop)
local trueBoarding            = 0
local trueDeboarding          = 0

-- Coroutine for realistic animation
local boardingCoroutine       = nil

-- forward declaration 
local isBus

-- ================================
-- CAPACITY DETECTION
-- ================================
local function specificCapacityCases(partName)
  if partName:find("capsule") and partName:find("seats") then
    if partName:find("sd12m") then return 25
    elseif partName:find("sd18m") then return 41
    elseif partName:find("sd105") then return 21
    elseif partName:find("sd_seats") then return 33
    elseif partName:find("dd105") then return 29
    elseif partName:find("sd195") then return 43
    elseif partName:find("lhd_artic_seats_upper") then return 77
    elseif partName:find("lhd_artic_seats") then return 30
    elseif partName:find("lh_seats_upper") then return 53
    elseif partName:find("lh_seats") then return 17
    elseif partName:find("lhd_seats_upper") then return 53
    elseif partName:find("lhd_seats") then return 17
    elseif partName:find("rhd_artic_seats_upper") then return 77
    elseif partName:find("rhd_artic_seats") then return 30
    end
  end

  if partName:find("schoolbus_seats_R_c") then return 10 end
  if partName:find("schoolbus_seats_L_c") then return 10 end
  if partName:find("limo_seat") then return 8 end

  return nil
end

local function cyclePartsTree(partData, seatingCapacity)
  for _, part in pairs(partData) do
    local partName = part.chosenPartName or ""

    if partName:find("seat") and not partName:find("cargo") and not partName:find("captains") then
      local seatSize = 1
      if partName:find("seats") then
        seatSize = 3
      elseif partName:find("ext") then
        seatSize = 2
      elseif partName:find("skin") then
        seatSize = 0
      end

      seatSize = specificCapacityCases(partName) or seatSize
      seatingCapacity = seatingCapacity + seatSize
    end

    if part.children then
      seatingCapacity = cyclePartsTree(part.children, seatingCapacity)
    end

    if partName == "pickup" then
      seatingCapacity = math.max(seatingCapacity, 7)
    end
  end

  return seatingCapacity
end

local function calculateSeatingCapacity()
  if not currentVehiclePartsTree then return 20 end
  return math.max(1, cyclePartsTree({currentVehiclePartsTree}, 0))
end

local function retrievePartsTree()
  currentVehiclePartsTree = nil
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand([[
      local partsTree = v.config.partsTree
      obj:queueGameEngineLua('career_modules_bus.returnPartsTree(' .. serialize(partsTree) .. ')')
    ]])
  end
end

function M.returnPartsTree(partsTree)
  currentVehiclePartsTree = partsTree
  local seats = calculateSeatingCapacity()
  M.vehicleCapacity = math.max(1, seats)

  local capOverride = nil

  local function checkPartTreeForKeywords(tree)
    for k, v in pairs(tree) do
      if type(k) == "string" then
        local name = string.lower(k)
        -- MD & Prison variants
        if name:find("schoolbus_interior_b") then
          capOverride = 24
          print("[bus] MD60 short bus detected via partsTree → capacity 24")
          return
        elseif name:find("schoolbus_interior_c") then
          capOverride = 40
          print("[bus] MD70 long bus detected via partsTree → capacity 40")
          return
        elseif name:find("prisonbus") then
          capOverride = 20
          print("[bus] Prison bus variant detected via partsTree → capacity 20")
          return
        -- City bus
        elseif name:find("citybus_seats") or name:find("citybus") then
          capOverride = 44
          print("[bus] City bus detected via partsTree → capacity 44")
          return
        -- VanBus variants 
        elseif name:find("dm_vanbus") or name:find("vanbus") or name:find("van_bus") or name:find("vanbusframe") then
          capOverride = 24
          print("[bus] VanBus detected via partsTree → capacity 24")
          return
        end
      end
      if type(v) == "table" then checkPartTreeForKeywords(v) end
    end
  end

  checkPartTreeForKeywords(partsTree)

  if capOverride then
    M.vehicleCapacity = capOverride
  elseif M.vehicleCapacity <= 12 then
    M.vehicleCapacity = 12
    print("[bus] Generic or van-based transport detected → fallback capacity 12")
  end

  print(string.format("[bus] Vehicle seating capacity detected: %d seats", M.vehicleCapacity))
  ui_message(string.format("Vehicle seating capacity detected: %d passengers.", M.vehicleCapacity), 5, "info", "info")
end

-- ================================
-- UTILITIES
-- ================================
isBus = function(vehicle)
  return vehicle and core_vehicles.getVehicleLicenseText(vehicle) == "BUS"
end

local function getNextTrigger()
  if not currentStopIndex then return nil end
  return stopTriggers[currentStopIndex]
end

local function showNextStopMarker()
  local trigger = getNextTrigger()
  if not trigger then return end
  core_groundMarkers.resetAll()
  core_groundMarkers.setPath(trigger:getPosition())
end

-- ================================
-- ROUTE END 
-- ================================
local function endRoute(reason, payout)
  currentRouteActive = false
  dwellTimer = nil
  routeInitialized = false
  core_groundMarkers.resetAll()

  local msg = "Shift ended."
  if reason then msg = msg .. " (" .. reason .. ")" end

  local reputationGain = 0

  if payout and payout > 0 then
    local basePay = accumulatedReward
    local tipsEarned = tipTotal
    local bonusPay = math.max(0, payout - (basePay + tipsEarned))

    reputationGain = math.floor(payout / 500)

    msg = msg .. string.format(
      "\nStops completed: %d" ..
      "\nBase pay:   $%d" ..
      "\nTips:       $%d" ..
      "\nBonus:      $%d" ..
      "\n--------------------" ..
      "\nTotal payout: $%d" ..
      "\nReputation gained: +%d",
      totalStopsCompleted, basePay, tipsEarned, bonusPay, payout,
      reputationGain
    )
  else
    msg = msg .. "\nNo payout earned."
  end

  ui_message(msg, 8, "info", "info")
  print("[bus] " .. msg:gsub("\n", " "))

  -- Reset displays
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand([[
      if controller and controller.onGameplayEvent then
        controller.onGameplayEvent("bus_onRouteChange", {
          routeId="00", routeID="00", direction="Not in Service", tasklist={}
        })
      end
    ]])
  end

  -- Rewards
  if payout and payout > 0 and career_career and career_career.isActive()
     and career_modules_payment and career_modules_payment.reward then
    career_modules_payment.reward({
      money={amount=payout},
      beamXP={amount=math.floor(payout/10)},  -- XP unchanged
      busWorkReputation={amount=reputationGain}
    },{
      label=string.format("Bus Route Earnings: $%d", payout),
      tags={"transport","bus","gameplay"}
    },true)
  end

  accumulatedReward, passengersOnboard, totalStopsCompleted, tipTotal = 0,0,0,0
  roughRide, lastVelocity, activeBusID = 0,nil,nil
end

-- ================================
-- ROUTE INITIALIZATION
-- ================================
local function initRoute()
  stopTriggers = {}
  -- Collect any trigger named *_bs_## so it works on any map prefix.
  local triggerObjects = scenetree.findClassObjects("BeamNGTrigger") or {}
  for _, obj in ipairs(triggerObjects) do
    local trigger = obj
    if type(obj) == "string" then trigger = scenetree.findObject(obj) end
    if trigger then
      local name = trigger:getName() or ""
      if name:match("_bs_%d+$") then
        table.insert(stopTriggers, trigger)
      end
    end
  end
  if #stopTriggers == 0 then
    ui_message("No bus stops found on this map.", 5, "error", "error")
    return
  end

  table.sort(stopTriggers, function(a, b)
    return (tonumber(string.match(a:getName(), "%d+")) or 0)
        < (tonumber(string.match(b:getName(), "%d+")) or 0)
  end)

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return end

  local vehiclePos = vehicle:getPosition()
  local nearestIndex, nearestDist = 1, math.huge
  for i, t in ipairs(stopTriggers) do
    local stopNum = tonumber(string.match(t:getName(), "%d+")) or 0
    if stopNum ~= 16 then
      local d = (t:getPosition() - vehiclePos):length()
      if d < nearestDist then
        nearestDist, nearestIndex = d, i
      end
    end
  end

  currentStopIndex, consecutiveStops, dwellTimer, accumulatedReward, totalStopsCompleted =
      nearestIndex, 0, nil, 0, 0
  currentRouteActive, routeInitialized, passengersOnboard, routeCooldown = true, true, 0, 0
  tipTotal, roughRide, lastVelocity = 0, 0, nil

  core_groundMarkers.setPath(stopTriggers[currentStopIndex]:getPosition())
  ui_message(
      string.format("Bus route started at Stop %02d. Proceed sequentially through all stops.", nearestIndex),
      6, "info", "info")

  -- Build route data for the bus controller 
  local routeData = {routeId = "ALO", routeID = "ALO", direction = "Aloha Express", tasklist = {}}
  for i, t in ipairs(stopTriggers) do
    local label
    if i == 1 then
      label = "Route Start"
    else
      label = string.format("Stop %02d", i - 1)
    end
    table.insert(routeData.tasklist, {t:getName(), label})
  end

  vehicle:queueLuaCommand(string.format([[
    if controller and controller.onGameplayEvent then
      controller.onGameplayEvent("bus_setLineInfo", %s)
    end
  ]], dumps(routeData)))
end
-- ================================
-- PROCESS STOP 
-- ================================
local function processStop(vehicle, dtSim)
    if not currentRouteActive or not currentStopIndex then return end
    if routeCooldown > 0 then return end

    local trigger = getNextTrigger()
    if not trigger then return end

    local dist = (vehicle:getPosition() - trigger:getPosition()):length()

    ------------------------------------------------------------
    -- MUST BE IN STOP RADIUS
    ------------------------------------------------------------
    if dist <= 5 then
        local velocity = vehicle:getVelocity():length()

        -- Must be fully stopped
        if velocity > 0.5 then
            ui_message("Come to a complete stop before passengers can board.", 2, "info", "info")
            dwellTimer = nil
            stopMonitorActive = false
            stopSettleTimer = 0
            return
        end

        -- Stop monitoring and settle
        if not stopMonitorActive then
            stopMonitorActive = true
            stopSettleTimer = 0
            ui_message("Please come to a complete stop and open doors to begin boarding", 2.5, "info", "bus")
        else
            stopSettleTimer = stopSettleTimer + (dtSim or 0.033)
        end

        -- Must remain still for settle delay
        if stopSettleTimer < stopSettleDelay then
            dwellTimer = nil
            return
        end

        ------------------------------------------------------------
        -- START DWELL (Initialize boarding + deboarding)
        ------------------------------------------------------------
        if not dwellTimer then
            dwellTimer = 0
            consecutiveStops = consecutiveStops + 1
            totalStopsCompleted = totalStopsCompleted + 1

            -- Notify bus controller 
            vehicle:queueLuaCommand(string.format([[
                if controller and controller.onGameplayEvent then
                    controller.onGameplayEvent("bus_onAtStop",{triggerName=%q})
                end
            ]], trigger:getName()))

            -- Final stop?
            local isFinalStop = (trigger == stopTriggers[#stopTriggers])

            if isFinalStop then
                trueBoarding = 0
                trueDeboarding = passengersOnboard
                dwellDuration = math.max(6, trueDeboarding * 0.6)
            else
                trueBoarding = math.random(3, 12)
                trueDeboarding = (passengersOnboard > 0)
                    and math.random(1, math.min(passengersOnboard, 6))
                    or 0

                dwellDuration =
                    math.random(8, 12)
                    + (trueBoarding * 0.8)
                    + (trueDeboarding * 0.5)
            end

            ------------------------------------------------------------
            -- Initialize animation coroutine (REALISTIC TIMING)
            ------------------------------------------------------------
            boardingCoroutine = coroutine.create(function()

                --------------------------------------------------------
                -- PHASE 1 — DEBOARDING 
                --------------------------------------------------------
                if trueDeboarding > 0 then
                    for i = trueDeboarding, 1, -1 do
                        ui_message(string.format(
                            "Stop %d\nDeboarding: %d\nBoarding: 0",
                            currentStopIndex, i
                        ), 2, "bus", "bus_anim")

                        local t = 0
                        while t < 2 do
                            coroutine.yield()
                            t = t + (dtSim or 0.033)
                        end
                    end
                else
                    ui_message(string.format(
                        "Stop %d\nDeboarding: 0\nBoarding: 0",
                        currentStopIndex
                    ), 1, "bus", "bus_anim")
                end

                --------------------------------------------------------
                -- PHASE 2 — BOARDING 
                --------------------------------------------------------
                if trueBoarding > 0 then
                    for i = 1, trueBoarding do
                        ui_message(string.format(
                            "Stop %d\nDeboarding: 0\nBoarding: %d",
                            currentStopIndex, i
                        ), 2, "bus", "bus_anim")

                        local t = 0
                        while t < 2 do
                            coroutine.yield()
                            t = t + (dtSim or 0.033)
                        end
                    end
                else
                    ui_message(string.format(
                        "Stop %d\nDeboarding: 0\nBoarding: 0",
                        currentStopIndex
                    ), 1, "bus", "bus_anim")
                end

			--------------------------------------------------------
			-- FINAL POST-BOARDING MESSAGE
			--------------------------------------------------------
				local newCount = math.min(
					math.max(0, passengersOnboard + trueBoarding - trueDeboarding),
					M.vehicleCapacity or 20
				)

				ui_message(string.format(
					"Stop %d complete!\nPassengers onboard: %d",
					currentStopIndex, newCount
				), 4, "bus", "bus_done")

				--------------------------------------------------------
				-- SHOW EARNINGS / TIPS / REPUTATION 
				--------------------------------------------------------
				local base = 300
				local bonusMultiplier = 1 + (consecutiveStops / #stopTriggers) * 3
				local payout = math.floor(base * bonusMultiplier)

				local reputationGain = math.floor(payout / 500)

				ui_message(string.format(
					"Earnings this stop:\n" ..
					"Base pay: $%d\n" ..
					"Tips this stop: $%d\n" ..
					"Reputation gained: +%d\n" ..
					"Total tips so far: $%d",
					payout, tipsEarned or 0, reputationGain, tipTotal
				), 10, "info", "bus_payout")

            end)

        end -- dwell init

        ------------------------------------------------------------
        -- DWELL TIMER (controls WHEN boarding finishes)
        ------------------------------------------------------------
        dwellTimer = dwellTimer + (dtSim or 0.033)

        if dwellTimer >= dwellDuration then
            print(string.format("[bus] Dwell complete at stop %d", currentStopIndex))

            --------------------------------------------------------
            -- FINALIZE passenger count
            --------------------------------------------------------
            passengersOnboard = math.min(
                math.max(0, passengersOnboard + trueBoarding - trueDeboarding),
                M.vehicleCapacity or 20
            )

            --------------------------------------------------------
            -- PAYOUT CALCULATION
            --------------------------------------------------------
            local base = 300
            local bonusMultiplier = 1 + (consecutiveStops / #stopTriggers) * 3
            local payout = math.floor(base * bonusMultiplier)
            accumulatedReward = accumulatedReward + payout

            --------------------------------------------------------
            -- TIP CALCULATION (ONLY if deboarders)
            --------------------------------------------------------
            local tipsEarned = 0
            if trueDeboarding > 0 then
                local avgRough = roughRide / math.max(1, dwellDuration)
                if avgRough < 0 then avgRough = 0 end

                local tipPerPassenger = math.max(0, 8 - avgRough) * 2
                tipsEarned = math.floor(tipPerPassenger * trueDeboarding * 40)
                tipTotal = tipTotal + tipsEarned
            end

            print(string.format(
                "[bus] Tips: +%d   TotalTips=%d",
                tipsEarned, tipTotal
            ))

            roughRide = 0

            --------------------------------------------------------
            -- RESET STOP STATE
            --------------------------------------------------------
            dwellTimer = nil
            stopMonitorActive = false
            stopSettleTimer = 0

            vehicle:queueLuaCommand(string.format([[
                if controller and controller.onGameplayEvent then
                  controller.onGameplayEvent("bus_onDepartedStop",{triggerName=%q})
                end
            ]], trigger:getName()))

            --------------------------------------------------------
            -- MOVE TO NEXT STOP
            --------------------------------------------------------
            if trigger == stopTriggers[#stopTriggers] then
                -- Loop bonus
                local loopBonus = math.floor(accumulatedReward * 0.5)
                accumulatedReward = accumulatedReward + loopBonus
                local totalPotential = accumulatedReward + tipTotal

                ui_message(string.format(
                    "All passengers unloaded.\nLoop complete! Bonus +$%d (+50%%)\nRoute earnings so far: $%d\nTips: $%d\nTotal potential payout: $%d",
                    loopBonus, accumulatedReward, tipTotal, totalPotential
                ), 6, "info", "info")

                passengersOnboard = 0
                trueBoarding = 0
                trueDeboarding = 0

                routeCooldown = 10
                currentStopIndex = 1
                showNextStopMarker()

            else
                currentStopIndex = currentStopIndex + 1
                showNextStopMarker()
                ui_message(string.format("Proceed to Stop %02d.", currentStopIndex), 4, "info", "bus_next")
            end
        end

    ------------------------------------------------------------
    -- PLAYER MOVED AWAY FROM STOP → CANCEL DWELL
    ------------------------------------------------------------
    else
        dwellTimer = nil
        stopMonitorActive = false
        stopSettleTimer = 0
    end
end
-- ================================
-- VEHICLE SWITCH 
-- ================================
function M.onVehicleSwitched(oldId, newId)
    local newVeh = be:getObjectByID(newId)
    local oldVeh = be:getObjectByID(oldId)

    -- Leaving the active bus ends the route
    if currentRouteActive and activeBusID and oldId == activeBusID then
        local payout = accumulatedReward + tipTotal
        if payout > 100000 then payout = 100000 end
        endRoute("player exited the bus", payout)
    end

    if newVeh and isBus(newVeh) then
        activeBusID = newId
        ui_message("Shift started. Welcome in! Drive careful out there.", 5, "info", "info")
        retrievePartsTree()
        initRoute()
    end
end

-- ================================
-- EXTENSION LOADED
-- ================================
local function onExtensionLoaded()
    ui_message("Bus module loaded. Enter a BUS vehicle to begin your route.", 3, "info", "info")
    print("[bus] Extension loaded.")
    extensions.load("career_modules_bus")
end

-- ================================
-- UPDATE LOOP
-- ================================
function M.onUpdate(dtReal, dtSim, dtRaw)
    -- Route cooldown between loops
    if routeCooldown > 0 then
        routeCooldown = math.max(0, routeCooldown - (dtSim or 0))
        return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle or not isBus(vehicle) or not routeInitialized then return end

    ------------------------------------------------------------
    -- Advance the REALISTIC BOARDING ANIMATION coroutine
    ------------------------------------------------------------
    if boardingCoroutine
       and coroutine.status(boardingCoroutine) ~= "dead" then

        local ok, err = coroutine.resume(boardingCoroutine)
        if not ok then
            print("[bus] Boarding animation coroutine error: " .. tostring(err))
            boardingCoroutine = nil
        end
    end

    ------------------------------------------------------------
    -- Rough ride tracking
    ------------------------------------------------------------
    local velocity = vehicle:getVelocity()

    if lastVelocity then
        local deltaVel = velocity - lastVelocity
        local safeDt = (dtSim and dtSim > 0) and dtSim or 0.01
        local accel = deltaVel:length() / safeDt
        local accelThreshold = 3.5

        if accel > accelThreshold then
            roughRide = roughRide + (accel - accelThreshold) * safeDt * 10
        end
    end

    lastVelocity = velocity

    ------------------------------------------------------------
    -- Core stop logic
    ------------------------------------------------------------
    processStop(vehicle, dtSim)
end

M.onExtensionLoaded = onExtensionLoaded
return M
