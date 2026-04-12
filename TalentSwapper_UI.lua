-- ============================================================
-- TalentSwapper_UI.lua  --  Main frame & reminder toast
-- ============================================================

local FRAME_WIDTH  = 520
local FRAME_HEIGHT = 520
local ROW_HEIGHT   = 28
local CHAT_PREFIX  = "|cFF00BFFF[TalentSwapper]|r "

local mainFrame, scrollChild, buildRows
local selectedCategory = nil  -- nil = show all
local activeTab = "mybuilds"  -- "mybuilds" or "recommended"

-- Recommended panel (toggled by tab buttons)
local recPanel

-- ── Category colors ─────────────────────────────────────────

local CATEGORY_COLORS = {
    ["Raid"]       = { r = 1.0, g = 0.5, b = 0.1 },
    ["Mythic+"]    = { r = 0.5, g = 0.5, b = 1.0 },
    ["PvP"]        = { r = 0.9, g = 0.2, b = 0.2 },
    ["Open World"] = { r = 0.3, g = 0.9, b = 0.3 },
    ["Custom"]     = { r = 0.7, g = 0.7, b = 0.7 },
}

-- ── Reminder toast ──────────────────────────────────────────

local reminderFrame

local function CreateReminderFrame()
    if reminderFrame then return reminderFrame end

    local f = CreateFrame("Frame", "TalentSwapperReminder", UIParent, "BackdropTemplate")
    f:SetSize(340, 80)
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.15, 0.92)
    f:SetBackdropBorderColor(0, 0.75, 1, 0.8)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("LEFT", f, "LEFT", 12, 0)
    icon:SetTexture("Interface\\Icons\\ability_marksmanship")
    f.icon = icon

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, 2)
    title:SetText("|cFF00BFFFTalentSwapper|r")
    f.title = title

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    text:SetPoint("RIGHT", f, "RIGHT", -80, 0)
    text:SetWordWrap(true)
    f.text = text

    local swapBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    swapBtn:SetSize(60, 24)
    swapBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    swapBtn:SetText("Swap")
    f.swapBtn = swapBtn

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Auto-hide after 15 seconds
    f.timer = nil
    f:SetScript("OnShow", function(self)
        if self.timer then self.timer:Cancel() end
        self.timer = C_Timer.NewTimer(15, function() self:Hide() end)
    end)
    f:SetScript("OnHide", function(self)
        if self.timer then self.timer:Cancel(); self.timer = nil end
    end)

    f:Hide()
    reminderFrame = f
    return f
end

function TalentSwapper.ShowReminder(buildName, buildIndex, matchContext)
    local f = CreateReminderFrame()
    f.text:SetText("Build |cFFFFD700" .. buildName .. "|r matches\n|cFFAAAAAA" .. matchContext .. "|r")
    f.swapBtn:SetScript("OnClick", function()
        TalentSwapper.LoadBuild(buildIndex)
        f:Hide()
    end)
    f:Show()
end

-- ── Main frame ──────────────────────────────────────────────

local function CreateMainFrame()
    if mainFrame then return mainFrame end

    local f = CreateFrame("Frame", "TalentSwapperFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        TalentSwapperDB.posX = x
        TalentSwapperDB.posY = y
    end)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
    f:SetBackdropBorderColor(0, 0.75, 1, 0.6)

    -- Restore position
    if TalentSwapperDB.posX and TalentSwapperDB.posY then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", TalentSwapperDB.posX, TalentSwapperDB.posY)
    end

    -- Title
    local titleBar = f:CreateTexture(nil, "ARTWORK")
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    titleBar:SetColorTexture(0, 0.4, 0.6, 0.4)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("|cFF00BFFFTalentSwapper|r")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- ── Top-level tabs: My Builds | Recommended ─────────────
    local myBuildsTabBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    myBuildsTabBtn:SetSize(120, 24)
    myBuildsTabBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -36)
    myBuildsTabBtn:SetText("|cFFFFFFFFMy Builds|r")

    local recTabBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    recTabBtn:SetSize(140, 24)
    recTabBtn:SetPoint("LEFT", myBuildsTabBtn, "RIGHT", 4, 0)
    recTabBtn:SetText("Recommended")

    -- Category filter tabs
    local tabY = -68
    local allBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    allBtn:SetSize(55, 22)
    allBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, tabY)
    allBtn:SetText("All")

    allBtn:SetScript("OnClick", function()
        selectedCategory = nil
        TalentSwapper.RefreshBuildList()
    end)

    local prevTab = allBtn
    local catFilterBtns = {}
    for _, cat in ipairs(TalentSwapper.CATEGORIES) do
        local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        btn:SetSize(70, 22)
        btn:SetPoint("LEFT", prevTab, "RIGHT", 4, 0)
        btn:SetText(cat)
        btn:SetScript("OnClick", function()
            selectedCategory = cat
            TalentSwapper.RefreshBuildList()
        end)
        table.insert(catFilterBtns, btn)
        prevTab = btn
    end

    -- Scroll frame for build list
    local scrollFrame = CreateFrame("ScrollFrame", "TalentSwapperScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 12, tabY - 30)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 100)


    scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 50, 1)
    scrollFrame:SetScrollChild(scrollChild)

    buildRows = {}

    -- ── Bottom buttons ──────────────────────────────────────

    -- Save build row
    local nameInput = CreateFrame("EditBox", "TalentSwapperNameInput", f, "InputBoxTemplate")
    nameInput:SetSize(160, 22)
    nameInput:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 66)
    nameInput:SetAutoFocus(false)
    nameInput:SetMaxLetters(40)
    nameInput:SetFontObject("ChatFontNormal")
    nameInput.Instructions = nameInput:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    nameInput.Instructions:SetPoint("LEFT", nameInput, "LEFT", 6, 0)
    nameInput.Instructions:SetText("Build name...")
    nameInput:SetScript("OnTextChanged", function(self)
        if self:GetText() == "" then
            self.Instructions:Show()
        else
            self.Instructions:Hide()
        end
    end)
    f.nameInput = nameInput

    -- Category dropdown (simple cycling button)
    local catBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    catBtn:SetSize(80, 22)
    catBtn:SetPoint("LEFT", nameInput, "RIGHT", 6, 0)
    catBtn.catIndex = 1
    catBtn:SetText(TalentSwapper.CATEGORIES[1])
    catBtn:SetScript("OnClick", function(self)
        self.catIndex = (self.catIndex % #TalentSwapper.CATEGORIES) + 1
        self:SetText(TalentSwapper.CATEGORIES[self.catIndex])
    end)
    f.catBtn = catBtn

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetSize(70, 22)
    saveBtn:SetPoint("LEFT", catBtn, "RIGHT", 6, 0)
    saveBtn:SetText("Save")
    saveBtn:SetScript("OnClick", function()
        local name = nameInput:GetText():trim()
        if name == "" then
            print(CHAT_PREFIX .. "Enter a build name first.")
            return
        end
        local cat = TalentSwapper.CATEGORIES[catBtn.catIndex]
        TalentSwapper.SaveBuild(name, cat)
        nameInput:SetText("")
        nameInput:ClearFocus()
        TalentSwapper.RefreshBuildList()
    end)

    -- Tag row (boss / dungeon auto-detect tags)
    local bossInput = CreateFrame("EditBox", "TalentSwapperBossInput", f, "InputBoxTemplate")
    bossInput:SetSize(150, 22)
    bossInput:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 38)
    bossInput:SetAutoFocus(false)
    bossInput:SetMaxLetters(60)
    bossInput:SetFontObject("ChatFontNormal")
    bossInput.Instructions = bossInput:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    bossInput.Instructions:SetPoint("LEFT", bossInput, "LEFT", 6, 0)
    bossInput.Instructions:SetText("Boss name tag...")
    bossInput:SetScript("OnTextChanged", function(self)
        if self:GetText() == "" then self.Instructions:Show() else self.Instructions:Hide() end
    end)
    f.bossInput = bossInput

    local dungeonInput = CreateFrame("EditBox", "TalentSwapperDungeonInput", f, "InputBoxTemplate")
    dungeonInput:SetSize(150, 22)
    dungeonInput:SetPoint("LEFT", bossInput, "RIGHT", 6, 0)
    dungeonInput:SetAutoFocus(false)
    dungeonInput:SetMaxLetters(60)
    dungeonInput:SetFontObject("ChatFontNormal")
    dungeonInput.Instructions = dungeonInput:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    dungeonInput.Instructions:SetPoint("LEFT", dungeonInput, "LEFT", 6, 0)
    dungeonInput.Instructions:SetText("Dungeon name tag...")
    dungeonInput:SetScript("OnTextChanged", function(self)
        if self:GetText() == "" then self.Instructions:Show() else self.Instructions:Hide() end
    end)
    f.dungeonInput = dungeonInput

    -- Auto-detect toggle
    local autoBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    autoBtn:SetSize(90, 22)
    autoBtn:SetPoint("LEFT", dungeonInput, "RIGHT", 6, 0)
    local function UpdateAutoText()
        if TalentSwapperDB.autoDetect then
            autoBtn:SetText("|cFF00FF00Auto: ON|r")
        else
            autoBtn:SetText("|cFFFF4444Auto: OFF|r")
        end
    end
    autoBtn:SetScript("OnClick", function()
        TalentSwapperDB.autoDetect = not TalentSwapperDB.autoDetect
        UpdateAutoText()
    end)
    f.autoBtn = autoBtn
    f.updateAutoText = UpdateAutoText

    -- Import/Export row
    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetSize(100, 22)
    importBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 10)
    importBtn:SetText("Import String")
    importBtn:SetScript("OnClick", function()
        TalentSwapper.ShowImportExportDialog("import")
    end)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(100, 22)
    exportBtn:SetPoint("LEFT", importBtn, "RIGHT", 6, 0)
    exportBtn:SetText("Export Current")
    exportBtn:SetScript("OnClick", function()
        local str = TalentSwapper.GetCurrentTalentString()
        if str then
            TalentSwapper.ShowImportExportDialog("export", str)
        end
    end)

    -- Override save to also include tags
    saveBtn:SetScript("OnClick", function()
        local name = nameInput:GetText():trim()
        if name == "" then
            print(CHAT_PREFIX .. "Enter a build name first.")
            return
        end
        local cat = TalentSwapper.CATEGORIES[catBtn.catIndex]
        local boss = bossInput:GetText():trim()
        local dungeon = dungeonInput:GetText():trim()
        TalentSwapper.SaveBuild(name, cat, boss, dungeon)
        nameInput:SetText("")
        bossInput:SetText("")
        dungeonInput:SetText("")
        nameInput:ClearFocus()
        bossInput:ClearFocus()
        dungeonInput:ClearFocus()
        TalentSwapper.RefreshBuildList()
    end)

    -- Track all My Builds controls for tab switching
    f.myBuildsControls = { nameInput, catBtn, saveBtn, bossInput, dungeonInput, autoBtn, importBtn, exportBtn, scrollFrame, allBtn }
    for _, btn in ipairs(catFilterBtns) do
        table.insert(f.myBuildsControls, btn)
    end

    -- ── Recommended panel ───────────────────────────────
    recPanel = CreateFrame("Frame", nil, f)
    recPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -64)
    recPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    recPanel:Hide()

    -- Category filter buttons for recommended tab
    local recSelectedCat = nil  -- nil = show all

    local recAllBtn = CreateFrame("Button", nil, recPanel, "UIPanelButtonTemplate")
    recAllBtn:SetSize(55, 22)
    recAllBtn:SetPoint("TOPLEFT", recPanel, "TOPLEFT", 12, -2)
    recAllBtn:SetText("All")
    recAllBtn:SetScript("OnClick", function()
        recSelectedCat = nil
        TalentSwapper.RefreshRecommended()
    end)

    local recRaidBtn = CreateFrame("Button", nil, recPanel, "UIPanelButtonTemplate")
    recRaidBtn:SetSize(55, 22)
    recRaidBtn:SetPoint("LEFT", recAllBtn, "RIGHT", 4, 0)
    recRaidBtn:SetText("Raid")
    recRaidBtn:SetScript("OnClick", function()
        recSelectedCat = "Raid"
        TalentSwapper.RefreshRecommended()
    end)

    local recMplusBtn = CreateFrame("Button", nil, recPanel, "UIPanelButtonTemplate")
    recMplusBtn:SetSize(55, 22)
    recMplusBtn:SetPoint("LEFT", recRaidBtn, "RIGHT", 4, 0)
    recMplusBtn:SetText("M+")
    recMplusBtn:SetScript("OnClick", function()
        recSelectedCat = "Mythic+"
        TalentSwapper.RefreshRecommended()
    end)

    recPanel.getSelectedCat = function() return recSelectedCat end

    local recScrollFrame = CreateFrame("ScrollFrame", "TalentSwapperRecScrollFrame", recPanel, "UIPanelScrollFrameTemplate")
    recScrollFrame:SetPoint("TOPLEFT", recPanel, "TOPLEFT", 12, -28)
    recScrollFrame:SetPoint("BOTTOMRIGHT", recPanel, "BOTTOMRIGHT", -32, 10)

    local recScrollChild = CreateFrame("Frame", nil, recScrollFrame)
    recScrollChild:SetSize(FRAME_WIDTH - 50, 1)
    recScrollFrame:SetScrollChild(recScrollChild)
    recPanel.scrollChild = recScrollChild
    recPanel.rows = {}

    local recInfoText = recPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    recInfoText:SetPoint("TOP", recScrollChild, "TOP", 0, -6)
    recInfoText:SetText("")
    recPanel.infoText = recInfoText

    -- ── Tab switching ───────────────────────────────────────
    local function SwitchTab(tab)
        activeTab = tab
        if tab == "mybuilds" then
            for _, ctrl in ipairs(f.myBuildsControls) do ctrl:Show() end
            recPanel:Hide()
            myBuildsTabBtn:SetText("|cFFFFFFFFMy Builds|r")
            recTabBtn:SetText("|cFF888888Recommended|r")
            TalentSwapper.RefreshBuildList()
        else
            for _, ctrl in ipairs(f.myBuildsControls) do ctrl:Hide() end
            recPanel:Show()
            myBuildsTabBtn:SetText("|cFF888888My Builds|r")
            recTabBtn:SetText("|cFFFFFFFFRecommended|r")
            TalentSwapper.RefreshRecommended()
        end
    end

    myBuildsTabBtn:SetScript("OnClick", function() SwitchTab("mybuilds") end)
    recTabBtn:SetScript("OnClick", function() SwitchTab("recommended") end)

    f:SetScript("OnShow", function()
        SwitchTab(activeTab)
        UpdateAutoText()
    end)

    tinsert(UISpecialFrames, "TalentSwapperFrame")
    f:Hide()
    mainFrame = f
    return f
end

-- ── Recommended builds rendering ────────────────────────────

-- Collapse state per encounter (persists across refreshes within session)
local recCollapsed = {}

-- Raid instance display order
local RAID_ORDER = { "All Raids", "March of the Queldalans", "Voidspire", "Dreamrift" }
local RAID_COLORS = {
    ["All Raids"]                = "FF888888",
    ["March of the Queldalans"]  = "FFFF8800",
    ["Voidspire"]                = "FF9955FF",
    ["Dreamrift"]                = "FF44BBFF",
}

-- Helper: get or create a row frame, fully reset for reuse
local function AcquireRow(rows, rowIdx, child, height)
    local row = rows[rowIdx]
    if not row then
        row = CreateFrame("Frame", nil, child, "BackdropTemplate")
        row:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        row:EnableMouse(true)
        rows[rowIdx] = row
    end
    -- Full reset for reuse
    row:ClearAllPoints()
    row:SetSize(FRAME_WIDTH - 55, height or 24)
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetScript("OnMouseUp", nil)
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)
    -- Hide optional sub-elements from previous use
    if row.text then row.text:SetText("") end
    if row.rankText then row.rankText:SetText("") end
    if row.popText then row.popText:SetText("") end
    if row.applyBtn then row.applyBtn:Hide() end
    if row.saveBtn then row.saveBtn:Hide() end
    if row.divider then row.divider:Hide() end
    return row
end

local function RenderEncounterSection(child, rows, rowIdx, yOff, enc, refreshFn)
    local encKey = enc.name
    local isCollapsed = recCollapsed[encKey]

    -- Encounter header (clickable to collapse/expand)
    rowIdx = rowIdx + 1
    local encHeader = AcquireRow(rows, rowIdx, child, 22)
    encHeader:SetPoint("TOPLEFT", child, "TOPLEFT", 0, yOff)
    encHeader:SetBackdropColor(0.18, 0.28, 0.4, 0.4)

    if not encHeader.text then
        encHeader.text = encHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        encHeader.text:SetPoint("LEFT", encHeader, "LEFT", 14, 0)
    end
    local arrow = isCollapsed and "[+] " or "[-] "
    encHeader.text:SetText("|cFFAAAAAA" .. arrow .. "|r|cFFFFD700" .. enc.name .. "|r")
    encHeader:SetScript("OnMouseUp", function()
        recCollapsed[encKey] = not recCollapsed[encKey]
        refreshFn()
    end)
    encHeader:Show()
    yOff = yOff - 24

    if isCollapsed then
        return rowIdx, yOff
    end

    -- Build rows
    local builds = enc.data.builds or {}
    if #builds == 0 then
        rowIdx = rowIdx + 1
        local noData = AcquireRow(rows, rowIdx, child, ROW_HEIGHT)
        noData:SetPoint("TOPLEFT", child, "TOPLEFT", 0, yOff)
        if not noData.text then
            noData.text = noData:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            noData.text:SetPoint("LEFT", noData, "LEFT", 20, 0)
        end
        noData.text:SetText("No talent data available")
        noData:Show()
        yOff = yOff - ROW_HEIGHT
    end

    for _, build in ipairs(builds) do
        rowIdx = rowIdx + 1
        local row = AcquireRow(rows, rowIdx, child, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, yOff)

        if build.rank % 2 == 0 then
            row:SetBackdropColor(0.10, 0.10, 0.16, 0.5)
        else
            row:SetBackdropColor(0.06, 0.06, 0.10, 0.3)
        end

        -- Rank text
        if not row.rankText then
            row.rankText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.rankText:SetPoint("LEFT", row, "LEFT", 18, 0)
            row.rankText:SetWidth(30)
        end
        row.rankText:SetText("#" .. build.rank)

        -- Popularity text
        if not row.popText then
            row.popText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.popText:SetPoint("LEFT", row.rankText, "RIGHT", 4, 0)
            row.popText:SetWidth(100)
        end
        row.popText:SetText("|cFF00FF00" .. build.popularity .. "%|r popular")

        -- Apply button
        if not row.applyBtn then
            row.applyBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.applyBtn:SetSize(52, 20)
            row.applyBtn:SetPoint("RIGHT", row, "RIGHT", -64, 0)
            row.applyBtn:SetText("Apply")
        end
        row.applyBtn:Show()

        -- Save button
        if not row.saveBtn then
            row.saveBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.saveBtn:SetSize(52, 20)
            row.saveBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row.saveBtn:SetText("Save")
        end
        row.saveBtn:Show()

        local capturedString = build.talentString
        local capturedEncName = enc.name
        local capturedCat = enc.data.category or "Raid"

        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("|cFFFFD700" .. capturedEncName .. " - Build #" .. build.rank .. "|r")
            GameTooltip:AddLine(build.popularity .. "% of top players use this build")
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cFF888888Apply: loads into your talents|r")
            GameTooltip:AddLine("|cFF888888Save: saves to My Builds|r")
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.applyBtn:SetScript("OnClick", function()
            TalentSwapper.ApplyTalentString(capturedString, capturedEncName .. " #" .. build.rank)
        end)

        row.saveBtn:SetScript("OnClick", function()
            local buildName = capturedEncName .. " (Archon #" .. build.rank .. ")"
            local bossTag = (capturedCat == "Raid") and capturedEncName or ""
            local dungeonTag = (capturedCat == "Mythic+") and capturedEncName or ""
            TalentSwapper.SaveBuild(buildName, capturedCat, bossTag, dungeonTag)
            local specBuilds = TalentSwapper.GetSpecBuilds()
            for _, b in ipairs(specBuilds) do
                if b.name == buildName then
                    b.talentString = capturedString
                    break
                end
            end
            local tagMsg = (capturedCat == "Mythic+") and "dungeon tag" or "boss tag"
            print(CHAT_PREFIX .. "Saved |cFFFFD700" .. buildName .. "|r to My Builds with " .. tagMsg .. ".")
        end)

        row:Show()
        yOff = yOff - ROW_HEIGHT - 2
    end

    yOff = yOff - 2
    return rowIdx, yOff
end

function TalentSwapper.RefreshRecommended()
    if not recPanel then return end
    local child = recPanel.scrollChild
    local rows = recPanel.rows

    -- Hide ALL rows first
    for _, row in ipairs(rows) do
        row:Hide()
        if row.applyBtn then row.applyBtn:Hide() end
        if row.saveBtn then row.saveBtn:Hide() end
    end

    local rec = TalentSwapper.GetRecommendedData()
    if not rec or not rec.encounters or not next(rec.encounters) then
        recPanel.infoText:SetText("|cFFFF8800No recommended builds for your spec.|r\nRun |cFFFFFF00python scraper/scrape_builds.py --all|r to fetch Archon data.")
        recPanel.infoText:Show()
        return
    end

    recPanel.infoText:Hide()
    local filterCat = recPanel.getSelectedCat()

    local yOff = 0
    local rowIdx = 0

    -- Metadata line
    if rec.spec and rec.class then
        rowIdx = rowIdx + 1
        local header = AcquireRow(rows, rowIdx, child, 18)
        header:SetPoint("TOPLEFT", child, "TOPLEFT", 0, yOff)
        if not header.text then
            header.text = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            header.text:SetPoint("LEFT", header, "LEFT", 4, 0)
        end
        header.text:SetText("|cFF00BFFF" .. (rec.spec or "") .. " " .. (rec.class or "") .. "|r  |cFF666666via Archon.gg - " .. (rec.generatedAt or "?") .. "|r")
        header:Show()
        yOff = yOff - 20
    end

    -- ── RAID section ────────────────────────────────────────
    if not filterCat or filterCat == "Raid" then
        local raidGroups = {}
        for name, data in pairs(rec.encounters) do
            if data.category == "Raid" then
                local raid = data.raid or "Other"
                if not raidGroups[raid] then raidGroups[raid] = {} end
                table.insert(raidGroups[raid], { name = name, data = data })
            end
        end
        for _, list in pairs(raidGroups) do
            table.sort(list, function(a, b)
                -- "All ..." entries always come first
                local aAll = a.name:find("^All ") and true or false
                local bAll = b.name:find("^All ") and true or false
                if aAll ~= bAll then return aAll end
                return a.name < b.name
            end)
        end

        for _, raidName in ipairs(RAID_ORDER) do
            local encounters = raidGroups[raidName]
            if encounters and #encounters > 0 then
                -- Raid instance header
                rowIdx = rowIdx + 1
                local raidHeader = AcquireRow(rows, rowIdx, child, 26)
                raidHeader:SetPoint("TOPLEFT", child, "TOPLEFT", 0, yOff)
                raidHeader:SetBackdropColor(0.15, 0.15, 0.25, 0.7)

                if not raidHeader.text then
                    raidHeader.text = raidHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                    raidHeader.text:SetPoint("LEFT", raidHeader, "LEFT", 8, 0)
                end
                local rColor = RAID_COLORS[raidName] or "FFFF8800"
                raidHeader.text:SetText("|c" .. rColor .. raidName .. "|r")

                if not raidHeader.divider then
                    raidHeader.divider = raidHeader:CreateTexture(nil, "ARTWORK")
                    raidHeader.divider:SetHeight(1)
                    raidHeader.divider:SetPoint("BOTTOMLEFT", raidHeader, "BOTTOMLEFT", 4, 0)
                    raidHeader.divider:SetPoint("BOTTOMRIGHT", raidHeader, "BOTTOMRIGHT", -4, 0)
                    raidHeader.divider:SetColorTexture(0.4, 0.4, 0.5, 0.6)
                end
                raidHeader.divider:Show()
                raidHeader:Show()
                yOff = yOff - 28

                for _, enc in ipairs(encounters) do
                    rowIdx, yOff = RenderEncounterSection(child, rows, rowIdx, yOff, enc, TalentSwapper.RefreshRecommended)
                end

                yOff = yOff - 6
            end
        end
    end

    -- ── M+ section ──────────────────────────────────────────
    if not filterCat or filterCat == "Mythic+" then
        local mplusEnc = {}
        for name, data in pairs(rec.encounters) do
            if data.category == "Mythic+" then
                table.insert(mplusEnc, { name = name, data = data })
            end
        end
        table.sort(mplusEnc, function(a, b)
            local aAll = a.name:find("^All ") and true or false
            local bAll = b.name:find("^All ") and true or false
            if aAll ~= bAll then return aAll end
            return a.name < b.name
        end)

        if #mplusEnc > 0 then
            -- M+ section header
            rowIdx = rowIdx + 1
            local mplusHeader = AcquireRow(rows, rowIdx, child, 26)
            mplusHeader:SetPoint("TOPLEFT", child, "TOPLEFT", 0, yOff)
            mplusHeader:SetBackdropColor(0.15, 0.15, 0.25, 0.7)

            if not mplusHeader.text then
                mplusHeader.text = mplusHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                mplusHeader.text:SetPoint("LEFT", mplusHeader, "LEFT", 8, 0)
            end
            mplusHeader.text:SetText("|cFF8888FFMythic+ Dungeons|r")

            if not mplusHeader.divider then
                mplusHeader.divider = mplusHeader:CreateTexture(nil, "ARTWORK")
                mplusHeader.divider:SetHeight(1)
                mplusHeader.divider:SetPoint("BOTTOMLEFT", mplusHeader, "BOTTOMLEFT", 4, 0)
                mplusHeader.divider:SetPoint("BOTTOMRIGHT", mplusHeader, "BOTTOMRIGHT", -4, 0)
                mplusHeader.divider:SetColorTexture(0.4, 0.4, 0.5, 0.6)
            end
            mplusHeader.divider:Show()
            mplusHeader:Show()
            yOff = yOff - 28

            for _, enc in ipairs(mplusEnc) do
                rowIdx, yOff = RenderEncounterSection(child, rows, rowIdx, yOff, enc, TalentSwapper.RefreshRecommended)
            end
        end
    end

    child:SetHeight(math.max(1, math.abs(yOff)))
end

-- ── Build list rendering ────────────────────────────────────

function TalentSwapper.RefreshBuildList()
    if not scrollChild then return end

    -- Clear existing rows
    for _, row in ipairs(buildRows) do
        row:Hide()
    end

    local builds = TalentSwapper.GetSpecBuilds()
    local yOff = 0
    local rowIdx = 0

    for i, build in ipairs(builds) do
        -- Category filter
        if selectedCategory and build.category ~= selectedCategory then
            -- skip
        else
            rowIdx = rowIdx + 1
            local row = buildRows[rowIdx]
            if not row then
                row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
                row:SetSize(FRAME_WIDTH - 55, ROW_HEIGHT)
                row:SetBackdrop({
                    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                    insets = { left = 2, right = 2, top = 2, bottom = 2 },
                })
                row:EnableMouse(true)

                row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 8, 0)
                row.nameText:SetWidth(200)
                row.nameText:SetJustifyH("LEFT")

                row.catText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.catText:SetPoint("LEFT", row.nameText, "RIGHT", 6, 0)
                row.catText:SetWidth(70)

                row.tagText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                row.tagText:SetPoint("LEFT", row.catText, "RIGHT", 6, 0)
                row.tagText:SetWidth(80)

                row.loadBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.loadBtn:SetSize(46, 20)
                row.loadBtn:SetPoint("RIGHT", row, "RIGHT", -52, 0)
                row.loadBtn:SetText("Load")

                row.deleteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.deleteBtn:SetSize(40, 20)
                row.deleteBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                row.deleteBtn:SetText("Del")

                buildRows[rowIdx] = row
            end

            row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOff)
            row:Show()

            -- Alternate row colors
            if rowIdx % 2 == 0 then
                row:SetBackdropColor(0.12, 0.12, 0.18, 0.6)
            else
                row:SetBackdropColor(0.08, 0.08, 0.12, 0.4)
            end

            row.nameText:SetText(build.name)

            local cc = CATEGORY_COLORS[build.category] or CATEGORY_COLORS["Custom"]
            row.catText:SetTextColor(cc.r, cc.g, cc.b)
            row.catText:SetText(build.category)

            -- Show tags as small hint
            local tags = {}
            if build.bossTag and build.bossTag ~= "" then
                table.insert(tags, "B:" .. build.bossTag)
            end
            if build.dungeonTag and build.dungeonTag ~= "" then
                table.insert(tags, "D:" .. build.dungeonTag)
            end
            row.tagText:SetText(table.concat(tags, " "))

            -- Tooltip on hover
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("|cFFFFD700" .. build.name .. "|r")
                GameTooltip:AddLine(build.category, cc.r, cc.g, cc.b)
                if build.bossTag and build.bossTag ~= "" then
                    GameTooltip:AddLine("Boss: |cFFFF8800" .. build.bossTag .. "|r")
                end
                if build.dungeonTag and build.dungeonTag ~= "" then
                    GameTooltip:AddLine("Dungeon: |cFF8888FF" .. build.dungeonTag .. "|r")
                end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cFF888888Click Load to apply this build|r")
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local capturedIndex = i
            row.loadBtn:SetScript("OnClick", function()
                TalentSwapper.LoadBuild(capturedIndex)
            end)
            row.deleteBtn:SetScript("OnClick", function()
                TalentSwapper.DeleteBuild(capturedIndex)
                TalentSwapper.RefreshBuildList()
            end)

            yOff = yOff - ROW_HEIGHT - 2
        end
    end

    scrollChild:SetHeight(math.max(1, math.abs(yOff)))
end

-- ── Import / Export dialog ──────────────────────────────────

local importExportFrame

function TalentSwapper.ShowImportExportDialog(mode, prefillText)
    if not importExportFrame then
        local f = CreateFrame("Frame", "TalentSwapperImportExport", UIParent, "BackdropTemplate")
        f:SetSize(420, 180)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
        f:SetBackdropBorderColor(0, 0.75, 1, 0.6)

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", f, "TOP", 0, -12)
        f.title = title

        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        local scrollFrame = CreateFrame("ScrollFrame", "TalentSwapperImportScroll", f, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -36)
        scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 44)

        local editBox = CreateFrame("EditBox", "TalentSwapperImportEditBox", scrollFrame)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(true)
        editBox:SetFontObject("ChatFontNormal")
        editBox:SetWidth(360)
        editBox:SetScript("OnEscapePressed", function() f:Hide() end)
        scrollFrame:SetScrollChild(editBox)
        f.editBox = editBox

        local actionBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        actionBtn:SetSize(100, 26)
        actionBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 10)
        f.actionBtn = actionBtn

        tinsert(UISpecialFrames, "TalentSwapperImportExport")
        f:Hide()
        importExportFrame = f
    end

    local f = importExportFrame
    f.editBox:SetText(prefillText or "")

    if mode == "import" then
        f.title:SetText("|cFF00BFFFImport Talent String|r")
        f.actionBtn:SetText("Apply")
        f.actionBtn:SetScript("OnClick", function()
            local str = f.editBox:GetText():trim()
            if str ~= "" then
                TalentSwapper.ApplyTalentString(str)
                f:Hide()
            end
        end)
    else
        f.title:SetText("|cFF00BFFFExport Talent String|r")
        f.actionBtn:SetText("Close")
        f.actionBtn:SetScript("OnClick", function() f:Hide() end)
        -- Select all for easy copy
        C_Timer.After(0.05, function()
            f.editBox:HighlightText()
        end)
    end

    f:Show()
end

-- ── Toggle ──────────────────────────────────────────────────

function TalentSwapper.ToggleMainFrame()
    local f = CreateMainFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end
