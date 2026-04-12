-- ============================================================
-- TalentSwapper.lua  --  Core addon
-- Save, load, and auto-swap talent builds per scenario.
-- ============================================================

TalentSwapper = TalentSwapper or {}

-- ── Constants ────────────────────────────────────────────────

local ADDON_NAME = "TalentSwapper"
local CHAT_PREFIX = "|cFF00BFFF[TalentSwapper]|r "

local CATEGORIES = {
    "Raid",
    "Mythic+",
    "PvP",
    "Open World",
    "Custom",
}
TalentSwapper.CATEGORIES = CATEGORIES

-- Cooldown so auto-detect doesn't spam (seconds)
local REMIND_COOLDOWN = 30
local lastRemindTime = 0
local lastRemindKey = nil

-- ── SavedVariables defaults ─────────────────────────────────

local function InitSavedVars()
    if not TalentSwapperDB then TalentSwapperDB = {} end
    local db = TalentSwapperDB

    -- builds[specID] = { { name, category, talentString, bossTag, dungeonTag }, ... }
    if db.builds       == nil then db.builds       = {} end
    if db.minimap      == nil then db.minimap       = { hide = false } end
    if db.autoDetect   == nil then db.autoDetect    = true end
    if db.reminderSound== nil then db.reminderSound = true end
end

-- ── Helpers ──────────────────────────────────────────────────

local function GetPlayerSpecID()
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local specID = GetSpecializationInfo(specIndex)
    return specID
end

local function GetSpecBuilds(specID)
    specID = specID or GetPlayerSpecID()
    if not specID then return {} end
    local key = tostring(specID)
    if not TalentSwapperDB.builds[key] then
        TalentSwapperDB.builds[key] = {}
    end
    return TalentSwapperDB.builds[key]
end
TalentSwapper.GetSpecBuilds = GetSpecBuilds

-- Map Blizzard class file tokens to Archon URL slugs
local CLASS_FILE_TO_SLUG = {
    DEATHKNIGHT = "death-knight",
    DEMONHUNTER = "demon-hunter",
    DRUID       = "druid",
    EVOKER      = "evoker",
    HUNTER      = "hunter",
    MAGE        = "mage",
    MONK        = "monk",
    PALADIN     = "paladin",
    PRIEST      = "priest",
    ROGUE       = "rogue",
    SHAMAN      = "shaman",
    WARLOCK     = "warlock",
    WARRIOR     = "warrior",
}

-- Get the recommended data table for the player's current class/spec.
-- Supports both the old single-spec format and new multi-spec format.
function TalentSwapper.GetRecommendedData()
    local rec = TalentSwapperRecommended
    if not rec then return nil end

    -- New multi-spec format: TalentSwapperRecommended.specs["class:spec"]
    if rec.specs then
        local specIndex = GetSpecialization()
        if not specIndex then return nil end
        local _, specName = GetSpecializationInfo(specIndex)
        local _, classFile = UnitClass("player")
        if not classFile or not specName then return nil end

        local classSlug = CLASS_FILE_TO_SLUG[classFile]
        if not classSlug then return nil end
        local specSlug = specName:lower():gsub(" ", "-")
        local key = classSlug .. ":" .. specSlug
        local specData = rec.specs[key]
        if specData then
            return {
                class = specData.class,
                spec = specData.spec,
                generatedAt = rec.generatedAt,
                encounters = specData.encounters,
            }
        end
        return nil
    end

    -- Old single-spec format (backwards compatible)
    if rec.encounters then
        return rec
    end

    return nil
end

-- ── Talent string capture / apply ───────────────────────────

function TalentSwapper.GetCurrentTalentString()
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        print(CHAT_PREFIX .. "|cFFFF4444Could not get active talent config.|r")
        return nil
    end
    local exportString = C_Traits.GenerateImportString(configID)
    if not exportString or exportString == "" then
        print(CHAT_PREFIX .. "|cFFFF4444Could not export talent string.|r")
        return nil
    end
    return exportString
end

-- Helper: get the talent tree ID for the current config
local function GetTreeID()
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then return nil end
    local configInfo = C_Traits.GetConfigInfo(configID)
    return configInfo and configInfo.treeIDs and configInfo.treeIDs[1]
end

-- Helper: convert parsed loadout content to ImportLoadoutEntryInfo table
local function ConvertToImportLoadoutEntryInfo(treeID, loadoutContent)
    local results = {}
    local treeNodes = C_Traits.GetTreeNodes(treeID)
    local configID = C_ClassTalents.GetActiveConfigID()
    local count = 1

    for i, treeNodeID in ipairs(treeNodes) do
        local indexInfo = loadoutContent[i]
        if indexInfo and indexInfo.isNodeSelected then
            local treeNode = C_Traits.GetNodeInfo(configID, treeNodeID)
            local isChoiceNode = treeNode.type == Enum.TraitNodeType.Selection
                or treeNode.type == Enum.TraitNodeType.SubTreeSelection
            local choiceNodeSelection = indexInfo.isChoiceNode and indexInfo.choiceNodeSelection or nil
            if isChoiceNode ~= indexInfo.isChoiceNode then
                choiceNodeSelection = 1
            end

            local result = {}
            result.nodeID = treeNode.ID
            result.ranksPurchased = indexInfo.isPartiallyRanked
                and indexInfo.partialRanksPurchased or treeNode.maxRanks
            result.selectionEntryID = isChoiceNode
                and treeNode.entryIDs[choiceNodeSelection] or nil
            results[count] = result
            count = count + 1
        end
    end

    return results
end

-- Helper: purchase all nodes from the entry info table
local function PurchaseLoadoutEntryInfo(configID, loadoutEntryInfo)
    local removed = 0
    for i, nodeEntry in pairs(loadoutEntryInfo) do
        local success = false
        if nodeEntry.selectionEntryID then
            success = C_Traits.SetSelection(configID, nodeEntry.nodeID, nodeEntry.selectionEntryID)
        elseif nodeEntry.ranksPurchased then
            for rank = 1, nodeEntry.ranksPurchased do
                success = C_Traits.PurchaseRank(configID, nodeEntry.nodeID)
            end
        end
        if success then
            removed = removed + 1
            loadoutEntryInfo[i] = nil
        end
    end
    return removed
end

-- Bit widths for the import/export header (v2 format)
local BIT_WIDTH_VERSION = 8
local BIT_WIDTH_SPEC_ID = 16
local BIT_WIDTH_RANKS_PURCHASED = 6

-- Read the loadout header ourselves (works for both v1 and v2)
local function ReadLoadoutHeader(importStream)
    local totalBits = importStream:GetNumberOfBits()
    -- Header: version(8) + specID(16) + treeHash(128) = 152 bits minimum
    if totalBits < (BIT_WIDTH_VERSION + BIT_WIDTH_SPEC_ID + 128) then
        return false, 0, 0, {}
    end
    local version = importStream:ExtractValue(BIT_WIDTH_VERSION)
    local specID = importStream:ExtractValue(BIT_WIDTH_SPEC_ID)
    local treeHash = {}
    for i = 1, 16 do
        treeHash[i] = importStream:ExtractValue(8)
    end
    return true, version, specID, treeHash
end

-- Read loadout content (v2 format — has isNodePurchased bit)
local function ReadLoadoutContentV2(importStream, treeID)
    local results = {}
    local treeNodes = C_Traits.GetTreeNodes(treeID)

    for i, nodeID in ipairs(treeNodes) do
        local nodeSelectedValue = importStream:ExtractValue(1)
        local isNodeSelected = nodeSelectedValue == 1
        local isNodePurchased = false
        local isPartiallyRanked = false
        local partialRanksPurchased = 0
        local isChoiceNode = false
        local choiceNodeSelection = 0

        if isNodeSelected then
            local nodePurchasedValue = importStream:ExtractValue(1)
            isNodePurchased = nodePurchasedValue == 1
            if isNodePurchased then
                local isPartiallyRankedValue = importStream:ExtractValue(1)
                isPartiallyRanked = isPartiallyRankedValue == 1
                if isPartiallyRanked then
                    partialRanksPurchased = importStream:ExtractValue(BIT_WIDTH_RANKS_PURCHASED)
                end
                local isChoiceNodeValue = importStream:ExtractValue(1)
                isChoiceNode = isChoiceNodeValue == 1
                if isChoiceNode then
                    choiceNodeSelection = importStream:ExtractValue(2)
                end
            end
        end

        results[i] = {
            isNodeSelected = isNodeSelected,
            isNodeGranted = isNodeSelected and not isNodePurchased,
            isPartiallyRanked = isPartiallyRanked,
            partialRanksPurchased = partialRanksPurchased,
            isChoiceNode = isChoiceNode,
            choiceNodeSelection = choiceNodeSelection + 1,  -- convert from 0-index
            nodeID = nodeID,
        }
    end

    return results
end

-- Read loadout content (v1 format — no isNodePurchased bit)
local function ReadLoadoutContentV1(importStream, treeID)
    local results = {}
    local treeNodes = C_Traits.GetTreeNodes(treeID)

    for i, nodeID in ipairs(treeNodes) do
        local nodeSelectedValue = importStream:ExtractValue(1)
        local isNodeSelected = nodeSelectedValue == 1
        local isPartiallyRanked = false
        local partialRanksPurchased = 0
        local isChoiceNode = false
        local choiceNodeSelection = 0

        if isNodeSelected then
            local isPartiallyRankedValue = importStream:ExtractValue(1)
            isPartiallyRanked = isPartiallyRankedValue == 1
            if isPartiallyRanked then
                partialRanksPurchased = importStream:ExtractValue(BIT_WIDTH_RANKS_PURCHASED)
            end
            local isChoiceNodeValue = importStream:ExtractValue(1)
            isChoiceNode = isChoiceNodeValue == 1
            if isChoiceNode then
                choiceNodeSelection = importStream:ExtractValue(2)
            end
        end

        results[i] = {
            isNodeSelected = isNodeSelected,
            isNodeGranted = false,
            isPartiallyRanked = isPartiallyRanked,
            partialRanksPurchased = partialRanksPurchased,
            isChoiceNode = isChoiceNode,
            choiceNodeSelection = choiceNodeSelection + 1,
            nodeID = nodeID,
        }
    end

    return results
end

-- Pending import data (used by TRAIT_CONFIG_CREATED callback)
local pendingImport = nil

-- Apply talents to a specific configID (internal helper)
local function ApplyLoadoutToConfig(configID, treeID, loadoutEntryInfo)
    C_Traits.ResetTree(configID, treeID)
    while true do
        local removed = PurchaseLoadoutEntryInfo(configID, loadoutEntryInfo)
        if removed == 0 then break end
    end
end

function TalentSwapper.ApplyTalentString(talentString, profileName)
    if not talentString or talentString == "" then
        print(CHAT_PREFIX .. "|cFFFF4444No talent string to apply.|r")
        return false
    end

    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        print(CHAT_PREFIX .. "|cFFFF4444Could not get active talent config.|r")
        return false
    end

    local treeID = GetTreeID()
    if not treeID then
        print(CHAT_PREFIX .. "|cFFFF4444Could not determine talent tree.|r")
        return false
    end

    -- Parse import string ourselves (no dependency on Blizzard mixin)
    local importStream = ExportUtil.MakeImportDataStream(talentString)
    local headerValid, serializationVersion, specID, treeHash = ReadLoadoutHeader(importStream)

    if not headerValid then
        print(CHAT_PREFIX .. "|cFFFF4444Invalid talent string (bad header).|r")
        return false
    end

    local currentVersion = C_Traits.GetLoadoutSerializationVersion and C_Traits.GetLoadoutSerializationVersion() or 1
    if serializationVersion ~= currentVersion then
        print(CHAT_PREFIX .. "|cFFFF4444Talent string version mismatch (got v" .. serializationVersion .. ", need v" .. currentVersion .. ").|r")
        return false
    end

    if specID ~= PlayerUtil.GetCurrentSpecID() then
        print(CHAT_PREFIX .. "|cFFFF4444This talent string is for a different spec.|r")
        return false
    end

    -- Check if any existing loadout already matches this talent string
    local configIDs = C_ClassTalents.GetConfigIDsBySpecID(specID)
    if configIDs then
        for _, existingConfigID in ipairs(configIDs) do
            local existingString = C_Traits.GenerateImportString(existingConfigID)
            if existingString and existingString == talentString then
                local existingInfo = C_Traits.GetConfigInfo(existingConfigID)
                local existingName = existingInfo and existingInfo.name or "Unknown"
                print(CHAT_PREFIX .. "|cFFFFD700" .. existingName .. "|r already has this exact build. Skipping import.")
                return true
            end
        end
    end

    -- Parse loadout content using the right version reader
    local loadoutContent
    if serializationVersion >= 2 then
        loadoutContent = ReadLoadoutContentV2(importStream, treeID)
    else
        loadoutContent = ReadLoadoutContentV1(importStream, treeID)
    end

    local loadoutEntryInfo = ConvertToImportLoadoutEntryInfo(treeID, loadoutContent)

    -- Try to create a new loadout profile
    local name = profileName or ("TalentSwapper Import")
    if C_ClassTalents.CanCreateNewConfig and C_ClassTalents.CanCreateNewConfig() then
        pendingImport = {
            loadoutEntryInfo = loadoutEntryInfo,
            treeID = treeID,
            name = name,
        }
        local success = C_ClassTalents.RequestNewConfig(name)
        if success then
            print(CHAT_PREFIX .. "Creating new loadout profile |cFFFFD700" .. name .. "|r ...")
            return true
        else
            -- Failed to create, fall back to modifying current config
            pendingImport = nil
            print(CHAT_PREFIX .. "|cFFAAAA00Could not create new profile, loading into current loadout.|r")
        end
    else
        print(CHAT_PREFIX .. "|cFFAAAA00Max loadouts reached, loading into current loadout.|r")
    end

    -- Fallback: apply to the current active config
    ApplyLoadoutToConfig(configID, treeID, loadoutEntryInfo)
    print(CHAT_PREFIX .. "|cFF00FF00Talent build loaded!|r Open your talent tree and click |cFFFFD700Apply|r to confirm.")
    return true
end

-- ── Save / Load / Delete ────────────────────────────────────

function TalentSwapper.SaveBuild(name, category, bossTag, dungeonTag)
    local specID = GetPlayerSpecID()
    if not specID then
        print(CHAT_PREFIX .. "You need to be in a specialization to save a build.")
        return false
    end

    local talentString = TalentSwapper.GetCurrentTalentString()
    if not talentString then return false end

    local builds = GetSpecBuilds(specID)

    -- Overwrite if same name exists
    for i, build in ipairs(builds) do
        if build.name == name then
            builds[i] = {
                name         = name,
                category     = category or "Custom",
                talentString = talentString,
                bossTag      = bossTag or "",
                dungeonTag   = dungeonTag or "",
            }
            print(CHAT_PREFIX .. "Updated build |cFFFFD700" .. name .. "|r")
            return true
        end
    end

    table.insert(builds, {
        name         = name,
        category     = category or "Custom",
        talentString = talentString,
        bossTag      = bossTag or "",
        dungeonTag   = dungeonTag or "",
    })
    print(CHAT_PREFIX .. "Saved build |cFFFFD700" .. name .. "|r")
    return true
end

function TalentSwapper.LoadBuild(index)
    local builds = GetSpecBuilds()
    local build = builds[index]
    if not build then
        print(CHAT_PREFIX .. "Build not found.")
        return false
    end
    print(CHAT_PREFIX .. "Loading |cFFFFD700" .. build.name .. "|r ...")
    return TalentSwapper.ApplyTalentString(build.talentString, build.name)
end

function TalentSwapper.DeleteBuild(index)
    local builds = GetSpecBuilds()
    local build = builds[index]
    if not build then
        print(CHAT_PREFIX .. "Build not found.")
        return false
    end
    local name = build.name
    table.remove(builds, index)
    print(CHAT_PREFIX .. "Deleted build |cFFFFD700" .. name .. "|r")
    return true
end

function TalentSwapper.RenameBuild(index, newName)
    local builds = GetSpecBuilds()
    local build = builds[index]
    if not build then return false end
    local oldName = build.name
    build.name = newName
    print(CHAT_PREFIX .. "Renamed |cFFFFD700" .. oldName .. "|r → |cFFFFD700" .. newName .. "|r")
    return true
end

-- ── Auto-detection ──────────────────────────────────────────

local function ShouldRemind(key)
    local now = GetTime()
    if key == lastRemindKey and (now - lastRemindTime) < REMIND_COOLDOWN then
        return false
    end
    lastRemindTime = now
    lastRemindKey = key
    return true
end

local function FindBuildByBoss(bossName)
    local builds = GetSpecBuilds()
    local lower = bossName:lower()
    for i, build in ipairs(builds) do
        if build.bossTag and build.bossTag ~= "" then
            if build.bossTag:lower() == lower or build.name:lower():find(lower, 1, true) then
                return i, build
            end
        end
    end
    return nil, nil
end

local function FindBuildByDungeon(instanceName)
    local builds = GetSpecBuilds()
    local lower = instanceName:lower()
    for i, build in ipairs(builds) do
        if build.dungeonTag and build.dungeonTag ~= "" then
            if build.dungeonTag:lower() == lower or build.name:lower():find(lower, 1, true) then
                return i, build
            end
        end
    end
    return nil, nil
end
TalentSwapper.FindBuildByBoss = FindBuildByBoss
TalentSwapper.FindBuildByDungeon = FindBuildByDungeon

local function OnTargetChanged()
    if not TalentSwapperDB.autoDetect then return end
    if not UnitExists("target") then return end

    -- Check if target is a boss-level mob
    local classification = UnitClassification("target")
    if classification ~= "worldboss" and classification ~= "rareelite" and classification ~= "elite" then
        -- Also check for dungeon/raid boss via boss frames
        local isBoss = false
        for i = 1, 5 do
            if UnitIsUnit("target", "boss" .. i) then
                isBoss = true
                break
            end
        end
        if not isBoss then return end
    end

    local targetName = UnitName("target")
    if not targetName then return end

    local buildIdx, build = FindBuildByBoss(targetName)
    if build and ShouldRemind("boss:" .. targetName) then
        if TalentSwapperDB.reminderSound then
            PlaySound(SOUNDKIT.RAID_WARNING)
        end
        TalentSwapper.ShowReminder(build.name, buildIdx, targetName)
    end
end

local function OnZoneChanged()
    if not TalentSwapperDB.autoDetect then return end

    local instanceName, instanceType = GetInstanceInfo()
    -- Only trigger in party/raid instances
    if instanceType ~= "party" and instanceType ~= "raid" then return end
    if not instanceName or instanceName == "" then return end

    local buildIdx, build = FindBuildByDungeon(instanceName)
    if build and ShouldRemind("zone:" .. instanceName) then
        if TalentSwapperDB.reminderSound then
            PlaySound(SOUNDKIT.RAID_WARNING)
        end
        TalentSwapper.ShowReminder(build.name, buildIdx, instanceName)
    end
end

-- ── Slash commands ──────────────────────────────────────────

SLASH_TALENTSWAPPER1 = "/talentswapper"
SLASH_TALENTSWAPPER2 = "/ts"
SlashCmdList["TALENTSWAPPER"] = function(msg)
    msg = msg:lower():trim()
    if msg == "" or msg == "show" then
        TalentSwapper.ToggleMainFrame()
    elseif msg == "help" then
        print(CHAT_PREFIX .. "Commands:")
        print("  |cFFFFFF00/ts|r              — Open TalentSwapper")
        print("  |cFFFFFF00/ts save <name>|r  — Quick-save current build")
        print("  |cFFFFFF00/ts list|r         — List saved builds for current spec")
        print("  |cFFFFFF00/ts load <#>|r     — Load build by number")
        print("  |cFFFFFF00/ts delete <#>|r   — Delete build by number")
        print("  |cFFFFFF00/ts auto|r         — Toggle auto-detection")
        print("  |cFFFFFF00/ts minimap|r      — Toggle minimap button")
        print("  |cFFFFFF00/ts reset|r        — Reset window position")
        print("  |cFFFFFF00/ts status|r       — Show recommended build coverage (dev)")
    elseif msg:sub(1, 5) == "save " then
        local name = msg:sub(6):trim()
        if name == "" then
            print(CHAT_PREFIX .. "Usage: /ts save My Build Name")
        else
            TalentSwapper.SaveBuild(name, "Custom")
        end
    elseif msg == "list" then
        local builds = GetSpecBuilds()
        if #builds == 0 then
            print(CHAT_PREFIX .. "No builds saved for this spec.")
        else
            print(CHAT_PREFIX .. "Saved builds:")
            for i, build in ipairs(builds) do
                local tags = ""
                if build.bossTag and build.bossTag ~= "" then
                    tags = tags .. " |cFFFF8800[Boss: " .. build.bossTag .. "]|r"
                end
                if build.dungeonTag and build.dungeonTag ~= "" then
                    tags = tags .. " |cFF8888FF[Dungeon: " .. build.dungeonTag .. "]|r"
                end
                print("  |cFFFFFF00" .. i .. "|r. |cFFFFD700" .. build.name .. "|r  (" .. build.category .. ")" .. tags)
            end
        end
    elseif msg:sub(1, 5) == "load " then
        local idx = tonumber(msg:sub(6):trim())
        if not idx then
            print(CHAT_PREFIX .. "Usage: /ts load 1")
        else
            TalentSwapper.LoadBuild(idx)
        end
    elseif msg:sub(1, 7) == "delete " then
        local idx = tonumber(msg:sub(8):trim())
        if not idx then
            print(CHAT_PREFIX .. "Usage: /ts delete 1")
        else
            TalentSwapper.DeleteBuild(idx)
        end
    elseif msg == "minimap" then
        TalentSwapperDB.minimap.hide = not TalentSwapperDB.minimap.hide
        if TalentSwapperDB.minimap.hide then icon:Hide("TalentSwapper") else icon:Show("TalentSwapper") end
        print(CHAT_PREFIX .. "Minimap button: " .. (TalentSwapperDB.minimap.hide and "|cFFFF4444hidden|r" or "|cFF44FF44shown|r"))
    elseif msg == "auto" then
        TalentSwapperDB.autoDetect = not TalentSwapperDB.autoDetect
        local state = TalentSwapperDB.autoDetect and "|cFF00FF00ON|r" or "|cFFFF4444OFF|r"
        print(CHAT_PREFIX .. "Auto-detection: " .. state)
    elseif msg == "reset" then
        TalentSwapperDB.posX = nil
        TalentSwapperDB.posY = nil
        print(CHAT_PREFIX .. "Window position reset.")
    elseif msg == "status" then
        -- Developer tool: show recommended build coverage for all specs
        local ALL_SPECS = {
            ["death-knight"] = {"blood", "frost", "unholy"},
            ["demon-hunter"] = {"havoc", "vengeance"},
            ["druid"]        = {"balance", "feral", "guardian", "restoration"},
            ["evoker"]       = {"augmentation", "devastation", "preservation"},
            ["hunter"]       = {"beast-mastery", "marksmanship", "survival"},
            ["mage"]         = {"arcane", "fire", "frost"},
            ["monk"]         = {"brewmaster", "mistweaver", "windwalker"},
            ["paladin"]      = {"holy", "protection", "retribution"},
            ["priest"]       = {"discipline", "holy", "shadow"},
            ["rogue"]        = {"assassination", "outlaw", "subtlety"},
            ["shaman"]       = {"elemental", "enhancement", "restoration"},
            ["warlock"]      = {"affliction", "demonology", "destruction"},
            ["warrior"]      = {"arms", "fury", "protection"},
        }
        local rec = TalentSwapperRecommended
        local specs = rec and rec.specs or {}
        local totalSpecs, withData, totalBuilds = 0, 0, 0
        local missing = {}

        print(CHAT_PREFIX .. "=== Recommended Build Coverage ===")
        if rec and rec.generatedAt then
            print(CHAT_PREFIX .. "Data generated: |cFFFFD700" .. rec.generatedAt .. "|r")
        end

        local classOrder = {"death-knight","demon-hunter","druid","evoker","hunter","mage","monk","paladin","priest","rogue","shaman","warlock","warrior"}
        for _, cls in ipairs(classOrder) do
            local specList = ALL_SPECS[cls]
            local clsDisplay = cls:gsub("-", " "):gsub("(%a)([%w_']*)", function(a,b) return a:upper()..b end)
            local parts = {}
            for _, sp in ipairs(specList) do
                totalSpecs = totalSpecs + 1
                local key = cls .. ":" .. sp
                local data = specs[key]
                local spDisplay = sp:gsub("-", " "):gsub("(%a)([%w_']*)", function(a,b) return a:upper()..b end)
                if data and data.encounters then
                    local builds = 0
                    local raid, mplus = 0, 0
                    for _, enc in pairs(data.encounters) do
                        local n = enc.builds and #enc.builds or 0
                        builds = builds + n
                        if enc.category == "Raid" and n > 0 then raid = raid + 1 end
                        if enc.category == "Mythic+" and n > 0 then mplus = mplus + 1 end
                    end
                    totalBuilds = totalBuilds + builds
                    if builds > 0 then
                        withData = withData + 1
                        table.insert(parts, string.format("|cFF00FF44%s|r(%d R:%d M:%d)", spDisplay, builds, raid, mplus))
                    else
                        table.insert(parts, "|cFFFF4444" .. spDisplay .. "|r(0)")
                        table.insert(missing, clsDisplay .. " " .. spDisplay)
                    end
                else
                    table.insert(parts, "|cFFFF4444" .. spDisplay .. "|r(--)")
                    table.insert(missing, clsDisplay .. " " .. spDisplay)
                end
            end
            print("  |cFFFFD700" .. clsDisplay .. ":|r  " .. table.concat(parts, "  "))
        end

        print(CHAT_PREFIX .. string.format("Coverage: |cFF00FF44%d|r/%d specs  |  |cFFFFD700%d|r total builds", withData, totalSpecs, totalBuilds))
        if #missing > 0 then
            print(CHAT_PREFIX .. "|cFFFF4444Missing:|r " .. table.concat(missing, ", "))
        end
    else
        print(CHAT_PREFIX .. "Unknown command. Try |cFFFFFF00/ts help|r")
    end
end

-- ── Minimap button (LibDataBroker + LibDBIcon) ─────────────

local LDB  = LibStub("LibDataBroker-1.1")
local icon = LibStub("LibDBIcon-1.0")

local TalentSwapperLDB = LDB:NewDataObject("TalentSwapper", {
    type = "data source",
    text = "TalentSwapper",
    icon = "Interface\\Icons\\ability_marksmanship",
    OnClick = function(_, button)
        if button == "LeftButton" then
            TalentSwapper.ToggleMainFrame()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("|cFF00BFFFTalentSwapper|r")
        tooltip:AddLine("Left-Click to open/close.", 1, 1, 1)
        local specID = GetPlayerSpecID()
        if specID then
            local builds = GetSpecBuilds(specID)
            tooltip:AddLine("|cFFAAAAAA" .. #builds .. " builds saved|r")
        end
        local autoState = TalentSwapperDB.autoDetect and "|cFF00FF00ON|r" or "|cFFFF4444OFF|r"
        tooltip:AddLine("|cFFAAAAAAAAuto-detect: " .. autoState .. "|r")
    end,
})

-- ── Events ──────────────────────────────────────────────────

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("TRAIT_CONFIG_CREATED")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitSavedVars()
        icon:Register("TalentSwapper", TalentSwapperLDB, TalentSwapperDB.minimap)
        local specID = GetPlayerSpecID()
        local count = specID and #GetSpecBuilds(specID) or 0
        print(CHAT_PREFIX .. "Loaded - |cFFFFD700" .. count .. "|r builds saved. Type |cFFFFFF00/ts|r to open.")

    elseif event == "TRAIT_CONFIG_CREATED" then
        if pendingImport then
            local pi = pendingImport
            pendingImport = nil
            -- Delay to let WoW finish switching to the new config
            C_Timer.After(0.5, function()
                -- Use the active config (WoW switches to the new one automatically)
                local activeConfigID = C_ClassTalents.GetActiveConfigID()
                if activeConfigID then
                    ApplyLoadoutToConfig(activeConfigID, pi.treeID, pi.loadoutEntryInfo)
                    print(CHAT_PREFIX .. "|cFF00FF00New loadout profile created!|r Open your talent tree, select |cFFFFD700" .. pi.name .. "|r, and click |cFFFFD700Apply|r.")
                else
                    print(CHAT_PREFIX .. "|cFFFF4444Failed to apply talents to new profile.|r")
                end
            end)
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        OnTargetChanged()

    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        -- Small delay to let instance info populate
        C_Timer.After(1, OnZoneChanged)
    end
end)
