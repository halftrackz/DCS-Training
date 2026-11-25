-- Global tracking variables
local activeBogeys = {}
local interceptorMonitor = nil
local startProximityMonitor
local activeEscortPlayer = nil
local spawnCounter = 0

-- Returns true if the unit is controlled by a human player
local function isHumanPlayer(unitObj)
    if not unitObj or not unitObj.isExist or not unitObj:isExist() then
        return false
    end
    return unitObj.getPlayerName ~= nil and unitObj:getPlayerName() ~= nil
end

-- Helper to re-apply pure Circle orbit task (no autonomous AI target hunting)
local function applyCircleOrbitTask(controller, record)
    record.isAttacking = false
    record.targetUnitId = nil
    controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
    controller:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.ALLOW_ABORT_MISSION)
    controller:setTask({
        id = 'Orbit',
        params = {
            pattern = 'Circle',
            altitude = record.spawnAlt,
            speed = 230,
            point = {x = record.spawnX, y = record.spawnZ}
        }
    })
end

-- Deep-copies a Lua table so cloned payloads don't mutate the source template
local function deepCopy(orig)
    if type(orig) ~= "table" then
        return orig
    end
    local copy = {}
    for k, v in pairs(orig) do
        copy[deepCopy(k)] = deepCopy(v)
    end
    return copy
end

-- Searches env.mission for a group by exact name and returns its first unit's mission data
local function findMissionTemplateUnit(groupName)
    if not env or not env.mission or not env.mission.coalition then
        return nil
    end

    for _, coaData in pairs(env.mission.coalition) do
        if type(coaData) == "table" and coaData.country then
            for _, countryData in pairs(coaData.country) do
                if type(countryData) == "table" and countryData.plane and countryData.plane.group then
                    for _, grpData in pairs(countryData.plane.group) do
                        if grpData.name == groupName and grpData.units and grpData.units[1] then
                            return grpData.units[1]
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- Default payload used only if template lookup fails
local function getDefaultPayload(aircraftType)
    local fuel = 5000
    local chaff = 60
    local flare = 60

    if aircraftType == "Su-27" then
        fuel = 9400
        chaff = 96
        flare = 96
    elseif aircraftType == "MiG-29S" then
        fuel = 3380
        chaff = 30
        flare = 30
    elseif aircraftType == "FA-18C_hornet" then
        fuel = 4900
        chaff = 60
        flare = 60
    elseif aircraftType == "F-16C_50" then
        fuel = 3200
        chaff = 60
        flare = 60
    elseif aircraftType == "F-15ESE" then
        fuel = 6103
        chaff = 120
        flare = 60
    elseif aircraftType == "F-4E" or aircraftType == "F-4E-45MC" then
        fuel = 5000
        chaff = 60
        flare = 60
    elseif aircraftType == "A-10C_2" then
        fuel = 5000
        chaff = 120
        flare = 120
    end

    return {
        ["fuel"] = fuel,
        ["flare"] = flare,
        ["chaff"] = chaff,
        ["gun"] = 100,
        ["pylons"] = {}
    }
end

-- Clones template payload & skill from env.mission (never activating the template group) and sets a Circle orbit
local function cloneTemplateAsCircle(aircraftType, index, spawnX, spawnZ, spawnAlt, warnOnMissing)
    local templateName = "TMPL_" .. aircraftType
    local skill = "Veteran"
    local payload = nil

    local tmplUnitData = findMissionTemplateUnit(templateName)
    if tmplUnitData and tmplUnitData.payload then
        payload = deepCopy(tmplUnitData.payload)
        if tmplUnitData.skill then
            skill = tmplUnitData.skill
        end
    else
        payload = getDefaultPayload(aircraftType)
        if warnOnMissing then
            trigger.action.outText("TEMPLATE NOT FOUND, GOING TO DEFAULT (" .. templateName .. ")", 10)
        end
    end

    spawnCounter = spawnCounter + 1
    local groupName = "Bogey_" .. aircraftType .. "_" .. spawnCounter .. "_" .. math.random(1000, 9999)

    return {
        ["visible"] = true,
        ["taskSelected"] = true,
        ["name"] = groupName,
        ["category"] = Group.Category.AIRPLANE,
        ["task"] = "CAP",
        ["route"] = {
            ["points"] = {
                [1] = {
                    ["alt"] = spawnAlt,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["x"] = spawnX,
                    ["y"] = spawnZ,
                    ["speed"] = 230,
                    ["task"] = {
                        ["id"] = "Orbit",
                        ["params"] = {
                            ["pattern"] = "Circle",
                            ["altitude"] = spawnAlt,
                            ["speed"] = 230,
                            ["point"] = {
                                ["x"] = spawnX,
                                ["y"] = spawnZ
                            }
                        }
                    }
                }
            }
        },
        ["units"] = {
            [1] = {
                ["x"] = spawnX,
                ["y"] = spawnZ,
                ["alt"] = spawnAlt,
                ["speed"] = 230,
                ["heading"] = 0,
                ["type"] = aircraftType,
                ["name"] = groupName .. "_Unit_1",
                ["callsign"] = {["name"] = "Bogey " .. index},
                ["skill"] = skill,
                ["payload"] = payload
            }
        }
    }
end

-- Spawns single-ship aircraft groups at Rota Intl airbase
local function spawnBogeyFlight(aircraftType, quantity)
    local airbaseObj = Airbase.getByName("Rota Intl")
    if not airbaseObj then
        trigger.action.outText("SPAWN ERROR: Rota Intl airbase not found on this map.", 10)
        return
    end

    local basePos = airbaseObj:getPosition().p
    local baseCoordX = basePos.x
    local baseCoordZ = basePos.z
    local baseElevation = basePos.y
    
    local spawnedCount = 0

    -- Loop to spawn each aircraft as an independent single-ship group
    for i = 1, quantity do
        local scatterX = math.random(-2000, 2000)
        local scatterZ = math.random(-2000, 2000)
        
        local spawnX = baseCoordX + scatterX
        local spawnZ = baseCoordZ + scatterZ
        local spawnAlt = baseElevation + 5000 + (i * 60)

        -- Only show the missing-template warning once per spawn batch (on i == 1)
        local groupData = cloneTemplateAsCircle(aircraftType, i, spawnX, spawnZ, spawnAlt, i == 1)
        local spawnedGroup = coalition.addGroup(country.id.RUSSIA, Group.Category.AIRPLANE, groupData)

        if spawnedGroup then
            table.insert(activeBogeys, {
                group = spawnedGroup,
                isEscorting = false,
                isAttacking = false,
                targetUnitId = nil,
                spawnX = spawnX,
                spawnZ = spawnZ,
                spawnAlt = spawnAlt
            })
            
            -- Delayed schedule to apply initial hold-fire orbit settings until a Blue player approaches
            timer.scheduleFunction(function(data)
                pcall(function()
                    local grp = data.grp
                    if grp and grp:isExist() then
                        local controller = grp:getController()
                        if controller then
                            controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                            controller:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.ALLOW_ABORT_MISSION)
                        end
                    end
                end)
                return nil
            end, {grp = spawnedGroup}, timer.getTime() + (i * 0.15))
            
            spawnedCount = spawnedCount + 1
        end
    end

    if spawnedCount > 0 then
        trigger.action.outText("SPAWN: " .. spawnedCount .. "x " .. aircraftType .. " (single ships) spawned over Rota Intl.", 10)
        if not interceptorMonitor then
            startProximityMonitor()
        end
    else
        trigger.action.outText("SPAWN ERROR: DCS rejected spawn table for " .. aircraftType .. ".", 10)
    end
end

-- Monitor function for player death and Blue-player-only engagement
startProximityMonitor = function()
    if interceptorMonitor then return end
    
    interceptorMonitor = timer.scheduleFunction(function(_, time)
        pcall(function()
            -- Checks if the escorting player died and sends AI back to Circle orbit
            if activeEscortPlayer then
                if not activeEscortPlayer:isExist() then
                    trigger.action.outText("[RADIO] RED LEADER DOWN: Player aircraft destroyed. All escort flights returning to Circle orbit.", 10)
                    for _, record in ipairs(activeBogeys) do
                        if record.group and record.group:isExist() then
                            record.isEscorting = false
                            local controller = record.group:getController()
                            if controller then
                                applyCircleOrbitTask(controller, record)
                            end
                        end
                    end
                    activeEscortPlayer = nil
                end
            end

            local bluePlayers = coalition.getPlayers(coalition.side.BLUE)

            -- Clean up dead groups and engage Blue human players only within 25 NM
            for i = #activeBogeys, 1, -1 do
                local record = activeBogeys[i]
                local grp = record and record.group
                
                if not grp or not grp:isExist() then
                    table.remove(activeBogeys, i)
                else
                    local controller = grp:getController()
                    local grpLeader = grp:getUnit(1)
                    
                    if controller and grpLeader and grpLeader:isExist() and not record.isEscorting then
                        local grpPos = grpLeader:getPosition().p
                        local closestBluePlayer = nil
                        local minBlueDist = 999999
                        
                        if bluePlayers then
                            for _, pUnit in ipairs(bluePlayers) do
                                if isHumanPlayer(pUnit) then
                                    local pPos = pUnit:getPosition().p
                                    local distNM = math.sqrt((grpPos.x - pPos.x)^2 + (grpPos.z - pPos.z)^2) / 1852
                                    if distNM < minBlueDist then
                                        minBlueDist = distNM
                                        closestBluePlayer = pUnit
                                    end
                                end
                            end
                        end
                        
                        -- Engage closest Blue human player when within 25 NM
                        if minBlueDist <= 25 and closestBluePlayer then
                            local targetId = closestBluePlayer:getID()
                            if not record.isAttacking or record.targetUnitId ~= targetId then
                                record.isAttacking = true
                                record.targetUnitId = targetId
                                controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_FREE)
                                controller:setTask({
                                    id = 'AttackUnit',
                                    params = {
                                        unitId = targetId,
                                        groupAttack = true
                                    }
                                })
                            end
                        elseif record.isAttacking and (not closestBluePlayer or minBlueDist > 30) then
                            -- Return to Circle orbit once Blue player is dead or beyond 30 NM
                            applyCircleOrbitTask(controller, record)
                        end
                    end
                end
            end
        end)

        -- Stop monitoring loop when no active bogeys remain
        if #activeBogeys == 0 then
            interceptorMonitor = nil
            return nil 
        end

        return time + 3
    end, {}, timer.getTime() + 3)
end

-- Builds F10 radio menu tree for spawning aircraft
local rootMenu = missionCommands.addSubMenu("Spawn Bogeys (Rota Intl Circle)")

local function createAircraftMenu(displayName, typeName)
    local jetMenu = missionCommands.addSubMenu(displayName, rootMenu)
    
    missionCommands.addCommand("Spawn 1 Ship", jetMenu, function()
        spawnBogeyFlight(typeName, 1)
    end)
    
    missionCommands.addCommand("Spawn 2 Ship", jetMenu, function()
        spawnBogeyFlight(typeName, 2)
    end)
    
    missionCommands.addCommand("Spawn 4 Ship", jetMenu, function()
        spawnBogeyFlight(typeName, 4)
    end)
end

createAircraftMenu("F-4E-45MC Phantom", "F-4E-45MC")
createAircraftMenu("F/A-18C Hornet", "FA-18C_hornet")
createAircraftMenu("F-16C Blk 50", "F-16C_50")
createAircraftMenu("F-15E S4+ Strike Eagle", "F-15ESE")
createAircraftMenu("A-10C II Warthog", "A-10C_2")
createAircraftMenu("MiG-29S Fulcrum", "MiG-29S")
createAircraftMenu("Su-27 Flanker", "Su-27")

-- F10 Coalition menu for player escort commands
local redMenu = missionCommands.addSubMenuForCoalition(coalition.side.RED, "Red Flight Commands")

-- Orders all active flights to join the player in a tight wingtip V-wedge formation
missionCommands.addCommandForCoalition(coalition.side.RED, "Escort All Active Flights", redMenu, function()
    local ok, err = pcall(function()
        local redPlayers = coalition.getPlayers(coalition.side.RED)
        if not redPlayers or #redPlayers == 0 then
            trigger.action.outText("REJOIN ERROR: No active Red player aircraft found.", 8)
            return
        end

        local playerUnit = redPlayers[1]
        local playerGroup = playerUnit and playerUnit:getGroup()

        if not playerGroup then
            trigger.action.outText("REJOIN ERROR: Could not resolve Red player group.", 8)
            return
        end

        if #activeBogeys == 0 then
            trigger.action.outText("REJOIN ERROR: No active bogey flights currently spawned.", 8)
            return
        end

        activeEscortPlayer = playerUnit
        local escortedCount = 0
        local playerGrpId = playerGroup:getID()

        for idx, record in ipairs(activeBogeys) do
            local grp = record.group
            if grp and grp:isExist() then
                local controller = grp:getController()
                if controller then
                    record.isEscorting = true
                    record.isAttacking = false
                    record.targetUnitId = nil

                    -- Tight wingtip V-wedge: alternates right (+Z) and left (-Z), stepping back (-X) and slightly up (+Y)
                    local sideMultiplier = (idx % 2 == 0) and -1 or 1
                    local slotIndex = math.ceil(idx / 2)
                    
                    local offsetX_Behind    = -20 * slotIndex
                    local offsetY_Altitude  = 5 * slotIndex
                    local offsetZ_RightLeft = (25 * slotIndex) * sideMultiplier

                    controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                    controller:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.PASSIVE_DEFENCE)
                    controller:setTask({
                        id = 'Follow',
                        params = {
                            groupId = playerGrpId,
                            pos = {x = offsetX_Behind, y = offsetY_Altitude, z = offsetZ_RightLeft},
                            lastWptIndexFlag = false
                        }
                    })

                    escortedCount = escortedCount + 1
                end
            end
        end

        if escortedCount > 0 then
            local msg = "[RADIO] RED LEADER: Rejoin tight wedge! [RADIO] BOGEY FLIGHTS (" .. escortedCount .. "): Rejoin confirmed, forming tight V-wedge on your wing (Hold Fire active)."
            env.info(msg)
            trigger.action.outText(msg, 10)
        else
            trigger.action.outText("REJOIN ERROR: Active bogeys no longer exist.", 8)
        end
    end)

    if not ok then
        trigger.action.outText("ESCORT SCRIPT ERROR: " .. tostring(err), 12)
        env.error("ESCORT SCRIPT ERROR: " .. tostring(err))
    end
end)

-- Command: Set ROE to Weapons Free for escorting flights
missionCommands.addCommandForCoalition(coalition.side.RED, "Fire at will", redMenu, function()
    local count = 0
    for _, record in ipairs(activeBogeys) do
        if record.isEscorting and record.group and record.group:isExist() then
            local controller = record.group:getController()
            if controller then
                controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_FREE)
                controller:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.ALLOW_ABORT_MISSION)
                count = count + 1
            end
        end
    end
    if count > 0 then
        trigger.action.outText("[RADIO] RED LEADER: Fire at will! [RADIO] BOGEY FLIGHTS: Wilco, engaging targets (Weapon Free).", 8)
    else
        trigger.action.outText("COMMAND ERROR: No flights currently assigned as wingmen.", 5)
    end
end)

-- Command: Set ROE to Hold Fire for escorting flights
missionCommands.addCommandForCoalition(coalition.side.RED, "Hold fire", redMenu, function()
    local count = 0
    for _, record in ipairs(activeBogeys) do
        if record.isEscorting and record.group and record.group:isExist() then
            local controller = record.group:getController()
            if controller then
                controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                controller:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.PASSIVE_DEFENCE)
                count = count + 1
            end
        end
    end
    if count > 0 then
        trigger.action.outText("[RADIO] RED LEADER: Hold fire. [RADIO] BOGEY FLIGHTS: Copy, holding fire and maintaining tight wedge.", 8)
    else
        trigger.action.outText("COMMAND ERROR: No flights currently assigned as wingmen.", 5)
    end
end)

-- Command: Release escorting flights back to Circle orbit
missionCommands.addCommandForCoalition(coalition.side.RED, "Return to Circle", redMenu, function()
    activeEscortPlayer = nil
    for _, record in ipairs(activeBogeys) do
        if record.group and record.group:isExist() then
            record.isEscorting = false
            local controller = record.group:getController()
            if controller then
                applyCircleOrbitTask(controller, record)
            end
        end
    end

    trigger.action.outText("[RADIO] RED LEADER: Return to Circle. [RADIO] BOGEY FLIGHTS: Copy, returning to Rota Intl Circle orbit.", 8)
end)

env.info("Rota Intl Coalition-Aware Circle Spawner Loaded Successfully.")
