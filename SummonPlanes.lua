-- Global tracking variables
local activeBogeys = {}
local interceptorMonitor = nil
local startProximityMonitor
local activeEscortPlayer = nil

-- Spawns single-ship aircraft groups at An Nasiriyah airbase
local function spawnBogeyFlight(aircraftType, quantity)
    local airbaseObj = Airbase.getByName("An Nasiriyah")
    if not airbaseObj then
        trigger.action.outText("SPAWN ERROR: An Nasiriyah airbase not found on this map.", 10)
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

        local groupName = "Bogey_" .. aircraftType .. "_" .. math.random(1000, 9999)

        local groupData = {
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
                            ["id"] = "ComboTask",
                            ["params"] = {
                                ["tasks"] = {
                                    [1] = {
                                        ["enabled"] = true,
                                        ["auto"] = true,
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
                    ["callsign"] = {["name"] = "Bogey " .. i},
                    ["skill"] = "Veteran"
                }
            }
        }

        local spawnedGroup = coalition.addGroup(country.id.RUSSIA, Group.Category.AIRPLANE, groupData)
        if spawnedGroup then
            table.insert(activeBogeys, {
                group = spawnedGroup,
                infiniteFuelActive = true,
                isEscorting = false,
                spawnX = spawnX,
                spawnZ = spawnZ,
                spawnAlt = spawnAlt
            })
            
            -- Delayed schedule to apply AI settings and unlimited fuel
            timer.scheduleFunction(function(data)
                local grp = data.grp
                if grp and grp:isExist() then
                    local controller = grp:getController()
                    if controller then
                        controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_FREE)
                        controller:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.ALLOW_ABORT_MISSION)
                        controller:setCommand({ id = 'SetUnlimitedFuel', params = { value = true } })
                    end
                end
            end, {grp = spawnedGroup}, timer.getTime() + (i * 0.15))
            
            spawnedCount = spawnedCount + 1
        end
    end

    if spawnedCount > 0 then
        trigger.action.outText("SPAWN: " .. spawnedCount .. "x " .. aircraftType .. " (Veteran single ships) spawned over An Nasiriyah.", 10)
        if not interceptorMonitor then
            startProximityMonitor()
        end
    else
        trigger.action.outText("SPAWN ERROR: DCS rejected spawn table for " .. aircraftType .. ".", 10)
    end
end

-- Monitor function for player death, fuel limits, and auto-engagement
startProximityMonitor = function()
    if interceptorMonitor then return end
    
    interceptorMonitor = timer.scheduleFunction(function(_, time)
        -- Checks if the escorting player died and sends AI back to CAP
        if activeEscortPlayer then
            if not activeEscortPlayer:isExist() then
                trigger.action.outTextForCoalition(coalition.side.RED, "[RADIO] RED LEADER DOWN: Player aircraft destroyed. All escort flights returning to CAP orbit.", 10)
                for _, record in ipairs(activeBogeys) do
                    if record.group and record.group:isExist() then
                        record.isEscorting = false
                        local controller = record.group:getController()
                        if controller then
                            controller:setTask({
                                id = 'ComboTask',
                                params = {
                                    tasks = {
                                        [1] = {
                                            enabled = true,
                                            auto = true,
                                            id = 'Orbit',
                                            params = {
                                                pattern = 'Circle',
                                                altitude = record.spawnAlt,
                                                speed = 230,
                                                point = {x = record.spawnX, y = record.spawnZ}
                                            }
                                        }
                                    }
                                }
                            })
                            controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_FREE)
                            controller:setCommand({ id = 'SetUnlimitedFuel', params = { value = false } })
                        end
                    end
                end
                activeEscortPlayer = nil
            end
        end

        local redPlayers = coalition.getPlayers(1)

        -- Clean up dead groups and calculate distances to players
        for i = #activeBogeys, 1, -1 do
            local record = activeBogeys[i]
            local grp = record and record.group
            
            if not grp or not grp:isExist() then
                table.remove(activeBogeys, i)
            else
                local controller = grp:getController()
                local grpLeader = grp:getUnit(1)
                
                if controller and grpLeader and grpLeader:isExist() then
                    local grpPos = grpLeader:getPosition().p
                    local bluePlayers = coalition.getPlayers(2)
                    
                    local minDistanceAnyPlayer = 999999
                    local closestBluePlayer = nil
                    local minBlueDist = 999999
                    
                    if redPlayers then
                        for _, pUnit in ipairs(redPlayers) do
                            if pUnit and pUnit:isExist() then
                                local pPos = pUnit:getPosition().p
                                local distNM = math.sqrt((grpPos.x - pPos.x)^2 + (grpPos.z - pPos.z)^2) / 1852
                                if distNM < minDistanceAnyPlayer then
                                    minDistanceAnyPlayer = distNM
                                end
                            end
                        end
                    end
                    
                    if bluePlayers then
                        for _, pUnit in ipairs(bluePlayers) do
                            if pUnit and pUnit:isExist() then
                                local pPos = pUnit:getPosition().p
                                local distNM = math.sqrt((grpPos.x - pPos.x)^2 + (grpPos.z - pPos.z)^2) / 1852
                                if distNM < minDistanceAnyPlayer then
                                    minDistanceAnyPlayer = distNM
                                end
                                if distNM < minBlueDist then
                                    minBlueDist = distNM
                                    closestBluePlayer = pUnit
                                end
                            end
                        end
                    end
                    
                    -- Disables infinite fuel if player gets within 50 NM
                    if not record.isEscorting and record.infiniteFuelActive and minDistanceAnyPlayer <= 50 then
                        record.infiniteFuelActive = false
                        controller:setCommand({ id = 'SetUnlimitedFuel', params = { value = false } })
                    end
                    
                    -- Auto attacks Blue aircraft if within 25 NM while not escorting
                    if not record.isEscorting and minBlueDist <= 25 and closestBluePlayer then
                        controller:pushTask({
                            id = 'AttackUnit',
                            params = {
                                unitId = closestBluePlayer:getID(),
                                groupAttack = true
                            }
                        })
                    end
                end
            end
        end

        -- Stop monitoring loop when no active bogeys remain
        if #activeBogeys == 0 then
            interceptorMonitor = nil
            return nil 
        end

        return time + 3
    end, {}, timer.getTime() + 3)
end

-- Builds F10 radio menu tree for spawning aircraft
local rootMenu = missionCommands.addSubMenu("Spawn Bogeys (An Nasiriyah CAP)")

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

createAircraftMenu("F-4E Phantom", "F-4E")
createAircraftMenu("F/A-18C Hornet", "FA-18C_hornet")
createAircraftMenu("F-16C Blk 50", "F-16C_50")
createAircraftMenu("F-14B Tomcat", "F-14B")
createAircraftMenu("A-10C II Warthog", "A-10C_2")
createAircraftMenu("MiG-29S Fulcrum", "MiG-29S")
createAircraftMenu("Su-27 Flanker", "Su-27")

-- F10 Coalition menu for player escort commands
local redMenu = missionCommands.addSubMenuForCoalition(coalition.side.RED, "Red Flight Commands")

-- Orders all active flights to join the player in a wedge formation
missionCommands.addCommandForCoalition(coalition.side.RED, "Escort All Active Flights", redMenu, function()
    local redPlayers = coalition.getPlayers(1)
    if not redPlayers or #redPlayers == 0 then
        trigger.action.outTextForCoalition(coalition.side.RED, "REJOIN ERROR: No active Red player aircraft found.", 5)
        return
    end

    local playerUnit = redPlayers[1]
    local playerGroup = playerUnit and playerUnit:getGroup()

    if playerGroup and #activeBogeys > 0 then
        activeEscortPlayer = playerUnit
        
        trigger.action.outTextForCoalition(coalition.side.RED, "[RADIO] RED LEADER: Requesting all active flights rejoin formation...", 5)

        local escortedCount = 0
        local playerGrpId = playerGroup:getID()

        for idx, record in ipairs(activeBogeys) do
            local grp = record.group
            if grp and grp:isExist() then
                local controller = grp:getController()
                if controller then
                    record.isEscorting = true

                    -- Alternates left/right offsets (-Z / +Z) and steps backward (-X) for wedge shape
                    local sideMultiplier = (idx % 2 == 0) and -1 or 1
                    local slotIndex = math.ceil(idx / 2)
                    
                    local offsetX_Behind    = -20 - ((slotIndex - 1) * 35)
                    local offsetY_Altitude  = (slotIndex - 1) * 15
                    local offsetZ_RightLeft = (110 + ((slotIndex - 1) * 110)) * sideMultiplier

                    controller:setTask({
                        id = 'Follow',
                        params = {
                            groupId = playerGrpId,
                            pos = {x = offsetX_Behind, y = offsetY_Altitude, z = offsetZ_RightLeft},
                            speed = 380,
                            lastWptIndexFlag = false
                        }
                    })

                    controller:setCommand({ id = 'SetUnlimitedFuel', params = { value = true } })
                    controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                    controller:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.ALLOW_ABORT_MISSION)
                    escortedCount = escortedCount + 1
                end
            end
        end

        if escortedCount > 0 then
            timer.scheduleFunction(function()
                trigger.action.outTextForCoalition(coalition.side.RED, "[RADIO] BOGEY FLIGHTS: Rejoin confirmed. Symmetric Wedge spread locked on (Hold Fire active).", 8)
            end, {}, timer.getTime() + 2)
        end
    else
        trigger.action.outTextForCoalition(coalition.side.RED, "REJOIN ERROR: No active bogey flights currently spawned.", 5)
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
                count = count + 1
            end
        end
    end
    if count > 0 then
        trigger.action.outTextForCoalition(coalition.side.RED, "[RADIO] RED LEADER: Fire at will! [RADIO] BOGEY FLIGHTS: Wilco, engaging targets (Weapon Free).", 8)
    else
        trigger.action.outTextForCoalition(coalition.side.RED, "COMMAND ERROR: No flights currently assigned as wingmen.", 5)
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
                count = count + 1
            end
        end
    end
    if count > 0 then
        trigger.action.outTextForCoalition(coalition.side.RED, "[RADIO] RED LEADER: Hold fire. [RADIO] BOGEY FLIGHTS: Copy, holding fire and maintaining formation.", 8)
    else
        trigger.action.outTextForCoalition(coalition.side.RED, "COMMAND ERROR: No flights currently assigned as wingmen.", 5)
    end
end)

-- Command: Release escorting flights back to CAP orbit
missionCommands.addCommandForCoalition(coalition.side.RED, "Return to CAP", redMenu, function()
    local resetCount = 0
    for _, record in ipairs(activeBogeys) do
        if record.group and record.group:isExist() then
            record.isEscorting = false
            activeEscortPlayer = nil
            local controller = record.group:getController()
            if controller then
                controller:setTask({
                    id = 'ComboTask',
                    params = {
                        tasks = {
                            [1] = {
                                enabled = true,
                                auto = true,
                                id = 'Orbit',
                                params = {
                                    pattern = 'Circle',
                                    altitude = record.spawnAlt,
                                    speed = 230,
                                    point = {x = record.spawnX, y = record.spawnZ}
                                }
                            }
                        }
                    }
                })
                controller:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_FREE)
                controller:setCommand({ id = 'SetUnlimitedFuel', params = { value = false } })
                resetCount = resetCount + 1
            end
        end
    end

    trigger.action.outTextForCoalition(coalition.side.RED, "[RADIO] RED LEADER: Return to CAP. [RADIO] BOGEY FLIGHTS: Copy, returning to An Nasiriyah orbit.", 8)
end)

env.info("An Nasiriyah Coalition-Aware CAP Spawner Loaded Successfully.")
