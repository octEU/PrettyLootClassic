-- PrettyLoot: a loot notification addon for Classic WoW.
-- Issues and contributions welcome on GitHub.
local addonName, PL = ...

-- =========================================================================
-- 1. Libraries & SavedVariables
-- =========================================================================
local AceAddon = LibStub("AceAddon-3.0")
local AceDB = LibStub("AceDB-3.0")
local AceConsole = LibStub("AceConsole-3.0")
local AceConfig = LibStub("AceConfig-3.0")
-- Optional libraries: loaded silently; absence does not prevent the addon from functioning.
local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
local LSM = LibStub("LibSharedMedia-3.0", true)
local AceSerializer = LibStub("AceSerializer-3.0", true) -- optional
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)

local PrettyLoot = AceAddon:NewAddon("PrettyLoot", "AceConsole-3.0", "AceEvent-3.0")
PL = PrettyLoot

-- Recursively copies a table. Used when duplicating profile data to avoid shared references.
local function DeepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do copy[k] = DeepCopy(v) end
    return copy
end

-- =========================================================================
-- 2. Defaults
-- =========================================================================
local defaults = {
    profile = {
        locked = true,
        x = 400,
        y = -70,

        -- display defaults
        iconSize = 16,
        textSize = 14,
        rowHeight = 22,
        maxItems = 10,
        rowSpacing = 2,
        fontKey = "Expressway",

        -- durations
        holdDuration = 10,
        durationHighlight = 10,

        trackReputation = true,
        trackAuctions = true,

        blacklist = "",
        highlight = "",

        playSoundOnHighlight = false,
        highlightSound = "",

        -- pinning options
        goldStaysOnTop = true,

        -- highlight visual style
        highlightStyle = "goldbrackets", -- "background" or "goldbrackets"
        highlightBackgroundColour = { r = 0.4, g = 0.2, b = 0.7, a = 0.25 },

        -- layout tuning
        iconGapWithIcon = 6,
        iconGapNoIcon = 2,
        indicatorVerticalOffset = 0,

        -- new behaviour
        fadeAsGroup = true,
    }
}

-- =========================================================================
-- 3. Constants & helpers
-- =========================================================================
local SLIDE_SPEED = 300
local SLIDE_DISTANCE_MAX = 140
local FADE_SPEED = 2

local FLUSH_DELAY = 0.08 -- seconds; batches rapid loot events into a single display update
local lastSoundTime = 0

local activeLines = {}
local framePool = {}

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local DEFAULT_QUALITY = 1

local qualityColors = {
    [0] = "|cff9d9d9d",
    [1] = "|cffffffff",
    [2] = "|cff1eff00",
    [3] = "|cff0070dd",
    [4] = "|cffa335ee",
    [5] = "|cffff8000",
    [6] = "|cffe6cc80",
}

local repColors = {
    [1] = "|cffcc2222",
    [2] = "|cffff0000",
    [3] = "|cffee6622",
    [4] = "|cffe8e800",
    [5] = "|cff00ff00",
    [6] = "|cff00ff88",
    [7] = "|cff00ffcc",
    [8] = "|cff00ffff",
}

local anchor, highlight, highlightText, highlightHeader

PL.plusWidth = nil

local parsedBlacklist = {}
local parsedBlacklistPatterns = {}
local parsedHighlight = {}
local parsedHighlightPatterns = {}

PL._newProfileName = ""

local function GetHighlightDuration()
    return PL.db.profile.durationHighlight or PL.db.profile.holdDuration or 10
end

local function GetBaseDurationForLine()
    return PL.db.profile.holdDuration or 10
end

local function GetRowHeight() return PL.db.profile.rowHeight or 22 end

-- Returns the active font path. Falls back to Friz Quadrata if LSM is unavailable or the font is not registered.
local function GetFont()
    if LSM and LSM.Fetch then
        local ok, f = pcall(function() return LSM:Fetch("font", PL.db.profile.fontKey) end)
        if ok and f and type(f) == "string" and f ~= "" then
            return f
        end
    end
    return "Fonts\\FRIZQT__.TTF"
end

local function Trim(s) if not s then return "" end return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function StripColors(s) if not s then return "" end return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local function EscapeExceptAsterisk(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%+%-%?\\])", "%%%1"))
end

local function WildcardToPattern(s)
    if not s then return nil end
    local orig = s
    local lower = string.lower(s)
    local escaped = EscapeExceptAsterisk(lower)
    escaped = escaped:gsub("%*", ".*")
    local leftAnchor = true
    local rightAnchor = true
    if orig:sub(1,1) == "*" then leftAnchor = false end
    if orig:sub(-1) == "*" then rightAnchor = false end
    if leftAnchor then escaped = "^" .. escaped end
    if rightAnchor then escaped = escaped .. "$" end
    return escaped
end

local function ParseListIntoTables(text, outLookup, outPatterns)
    outLookup = outLookup or {}
    outPatterns = outPatterns or {}
    if not text or text == "" then return outLookup, outPatterns end
    local norm = text:gsub(",", "\n")
    for line in string.gmatch(norm, "[^\r\n]+") do
        local item = Trim(line)
        if item ~= "" then
            if string.find(item, "%*") then
                local ok, pat = pcall(WildcardToPattern, item)
                if ok and pat then
                    table.insert(outPatterns, pat)
                else
                    outLookup[string.lower(item)] = true
                end
            else
                outLookup[string.lower(item)] = true
            end
        end
    end
    return outLookup, outPatterns
end

local function UpdateParsedLists()
    parsedBlacklist = {}
    parsedBlacklistPatterns = {}
    parsedHighlight = {}
    parsedHighlightPatterns = {}
    ParseListIntoTables(PL.db.profile.blacklist or "", parsedBlacklist, parsedBlacklistPatterns)
    ParseListIntoTables(PL.db.profile.highlight or "", parsedHighlight, parsedHighlightPatterns)
end

local function MatchList(listLookup, listPatterns, displayName)
    if not displayName then return false end
    local lowerName = string.lower(displayName)
    if listLookup[lowerName] then return true end
    for _, pat in ipairs(listPatterns) do
        local ok, res = pcall(string.find, lowerName, pat)
        if ok and res then return true end
    end
    return false
end

local function IsBlacklisted(itemKey, displayName)
    if itemKey ~= nil then
        local keyStr = tostring(itemKey)
        if parsedBlacklist[keyStr] then return true end
        if type(itemKey) == "string" and parsedBlacklist[string.lower(itemKey)] then return true end
    end
    if displayName then
        local stripped = StripColors(displayName)
        if MatchList(parsedBlacklist, parsedBlacklistPatterns, stripped) then return true end
    end
    return false
end

local function IsHighlighted(itemKey, displayName)
    if itemKey ~= nil then
        local keyStr = tostring(itemKey)
        if parsedHighlight[keyStr] then return true end
        if type(itemKey) == "string" and parsedHighlight[string.lower(itemKey)] then return true end
    end
    if displayName then
        local stripped = StripColors(displayName)
        if MatchList(parsedHighlight, parsedHighlightPatterns, stripped) then return true end
    end
    return false
end

-- =========================================================================
-- Priority: support optional "stays on top" pinning
-- =========================================================================
local function getPriority(line)
    local goldPinned = PL and PL.db and PL.db.profile and PL.db.profile.goldStaysOnTop

    if line.isMoney and goldPinned then return 0 end
    if line.isMoney    then return 1 end
    if line.isAuction  then return 2 end
    if line.isReputation then return 3 end
    return 4
end

-- forward-declare RemoveLine so earlier functions can call it safely
local RemoveLine

local function InsertLineByPriority(newLine)
    local newP = getPriority(newLine)
    local inserted = false
    for i, v in ipairs(activeLines) do
        local p = getPriority(v)
        -- Insert before the first line with equal or lower priority (higher number),
        -- so higher-priority entries (lower number) sit nearer the top.
        if p >= newP then
            table.insert(activeLines, i, newLine)
            inserted = true
            break
        end
    end
    if not inserted then table.insert(activeLines, newLine) end
end

-- Removes overflow entries when activeLines exceeds maxItems, starting from the lowest priority.
local function RemoveLowestPriorityLine()
    local maxItems = PL.db.profile.maxItems or 10
    while #activeLines > maxItems do
        local lastIndex = #activeLines
        local line = activeLines[lastIndex]
        if not line then break end
        RemoveLine(line)
    end
end

-- =========================================================================
-- Preview helpers
-- =========================================================================
local function ClearPreviewLines()
    local i = 1
    while i <= #activeLines do
        local line = activeLines[i]
        if line.isPreview then
            RemoveLine(line)
        else
            i = i + 1
        end
    end
end

-- =========================================================================
-- Group cascade state & helper
-- =========================================================================
local cascadeState = {
    active = false,
}

local function TriggerGroupCascade()
    if not PL.db.profile.fadeAsGroup then return end
    if cascadeState.active then return end

    local total = #activeLines
    if total == 0 then return end

    cascadeState.active = true

    -- Snapshot activeLines so mutations during the cascade do not affect scheduling.
    local snapshot = {}
    for i = 1, total do snapshot[i] = activeLines[i] end

    local delayStep = 0.2
    -- Schedule fade from bottom to top: the bottom-most line (highest index) starts immediately.
    for i = total, 1, -1 do
        local l = snapshot[i]
        local delay = (total - i) * delayStep
        C_Timer.After(delay, function()
            if not l then return end
            l._scheduledToStart = true
            l.timer = 0
            l:SetAlpha(1)
            l.slideX = l.slideX or 0
        end)
    end

    -- Clear cascade state after the full window has elapsed.
    C_Timer.After((total - 1) * delayStep + 0.8, function()
        cascadeState.active = false
    end)
end

-- =========================================================================
-- Helpers for gold bracket formatting
-- =========================================================================
local GOLD_BRACKET_COLOR = "|cffffd700"
local function WrapWithGoldBrackets(name)
    -- Put gold brackets around the name while leaving the name's own color escape sequences intact.
    -- We reset color before the name so the name's own color codes show correctly.
    return GOLD_BRACKET_COLOR .. "[" .. "|r" .. (name or "") .. GOLD_BRACKET_COLOR .. "]|r"
end

-- =========================================================================
-- Frame factory
-- =========================================================================
local function ComputePlusWidth()
    if not anchor then return 36 end
    local temp = anchor:CreateFontString(nil, "OVERLAY")
    temp:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
    local samples = { "|cff00ff00+|r", "|cffff0000-|r", "|cffffa500REP|r", "|cffff8800AH|r" }
    local maxW = 0
    for _, s in ipairs(samples) do
        temp:SetText(s)
        local w = temp:GetStringWidth()
        if w > maxW then maxW = w end
    end
    temp:SetText("")
    temp:Hide()
    return math.ceil(maxW + 4)
end

local function UpdateHighlightSize()
    local width = 300
    local headerHeight = 25
    local contentHeight = (GetRowHeight() + PL.db.profile.rowSpacing) * PL.db.profile.maxItems
    local totalHeight = headerHeight + contentHeight
    anchor:SetSize(width, totalHeight)
    highlight:SetSize(width, contentHeight)
    highlightHeader:SetSize(width, headerHeight)
end

local function RecalculateQueue()
    local yOffset = 0
    local rowHeight = GetRowHeight()
    for _, line in ipairs(activeLines) do
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", highlight, "TOPLEFT", line.slideX or 0, yOffset)
        line.anchorRef = highlight
        line.anchorPoint = "TOPLEFT"
        line.anchorYOffset = yOffset
        yOffset = yOffset - rowHeight - PL.db.profile.rowSpacing
    end
    UpdateHighlightSize()
end

local function StopHighlightVisual(line)
    if line._bgTex then
        line._bgTex:Hide()
    end
    line.highlighted = nil
    local tf = line.textHighlight or line
    if tf and tf.SetScale then
        pcall(function() tf:SetScale(1) end)
    end
end

local function StartHighlightVisual(line)
    local style = PL.db.profile.highlightStyle or "goldbrackets"
    local targetFrame = line.textHighlight or line
    if not targetFrame then return end

    if style == "background" then
        if not line._bgTex then
            local bg = targetFrame:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(targetFrame)
            line._bgTex = bg
        end
        local c = PL.db.profile.highlightBackgroundColour or { r = 0.4, g = 0.2, b = 0.7, a = 0.25 }
        line._bgTex:SetColorTexture(c.r or 0.4, c.g or 0.2, c.b or 0.7, c.a or 0.25)
        line._bgTex:Show()
    else
        -- Gold brackets style applies formatting at write-time in AddOrUpdateLoot; no texture needed.
        if line._bgTex then line._bgTex:Hide() end
    end
end

local function AnchorTextHighlight(line)
    if not line.textHighlight or not line.text then return end
    line.textHighlight:ClearAllPoints()
    line.textHighlight:SetPoint("TOPLEFT", line.text, "TOPLEFT", -2, 2)
    line.textHighlight:SetPoint("BOTTOMRIGHT", line.text, "BOTTOMRIGHT", 2, -2)
end

RemoveLine = function(line)
    StopHighlightVisual(line)
    line:Hide()
    line.itemKey = nil
    line.itemLink = nil
    line.slideX = 0
    line.isPreview = nil
    line._fadingStarted = nil
    line._scheduledToStart = nil
    for i, v in ipairs(activeLines) do if v == line then table.remove(activeLines, i) break end end
    table.insert(framePool, line)
    RecalculateQueue()
end

local function GetLine()
    local line = table.remove(framePool)
    if not line then
        line = CreateFrame("Frame", nil, UIParent)
        line:SetSize(300, GetRowHeight())
        line:SetClipsChildren(false)
        line.slideX = 0

        line.plus = line:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        line.plus:SetPoint("LEFT", line, "LEFT", 0, PL.db.profile.indicatorVerticalOffset or 0)
        line.plus:SetText("|cff00ff00+|r")
        line.plus:SetParent(line)
        line.plus:SetJustifyH("RIGHT")

        line.icon = line:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(PL.db.profile.iconSize, PL.db.profile.iconSize)
        line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        line.icon:SetParent(line)

        line.iconBorder = line:CreateTexture(nil, "BORDER")
        line.iconBorder:SetPoint("TOPLEFT", line.icon, "TOPLEFT", -1, 1)
        line.iconBorder:SetPoint("BOTTOMRIGHT", line.icon, "BOTTOMRIGHT", 1, -1)
        line.iconBorder:SetColorTexture(0,0,0,1)
        line.iconBorder:SetParent(line)

        line.text = line:CreateFontString(nil, "OVERLAY", nil)
        line.text:SetParent(line)
        line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
        line.text:SetJustifyH("LEFT")
        -- Width of 0 allows text to overflow the frame, letting long names render in full.
        line.text:SetWidth(0)
        line.text:ClearAllPoints()
        line.text:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)

        -- Invisible frame used to anchor highlight background textures to the text region only.
        line.textHighlight = CreateFrame("Frame", nil, line)
        line.textHighlight:SetFrameLevel(line:GetFrameLevel() + 3)
        line.textHighlight:SetPoint("TOPLEFT", line.text, "TOPLEFT", -2, 2)
        line.textHighlight:SetPoint("BOTTOMRIGHT", line.text, "BOTTOMRIGHT", 2, -2)

        line:SetScript("OnUpdate", function(self, elapsed)
            if self.timer and self.timer > 0 then
                self.timer = self.timer - elapsed
                if self.slideX ~= 0 or self:GetAlpha() < 1 then
                    self.slideX = 0
                    self:SetAlpha(1)
                    self:SetPoint("TOPLEFT", self.anchorRef, self.anchorPoint, self.slideX, self.anchorYOffset)
                end
                return
            end

            if not self._fadingStarted then
                if PL.db.profile.fadeAsGroup then
                    if not cascadeState.active and not self._scheduledToStart then
                        TriggerGroupCascade()
                        return
                    end

                    if self._scheduledToStart then
                        self._scheduledToStart = nil
                        self._fadingStarted = true
                        StopHighlightVisual(self)
                    else
                        return
                    end
                else
                    self._fadingStarted = true
                    StopHighlightVisual(self)
                end
            end

            self.slideX = self.slideX + (elapsed * SLIDE_SPEED)
            if self.slideX > SLIDE_DISTANCE_MAX then self.slideX = SLIDE_DISTANCE_MAX end
            self:SetPoint("TOPLEFT", self.anchorRef, self.anchorPoint, self.slideX, self.anchorYOffset)

            local newAlpha = self:GetAlpha() - (elapsed * FADE_SPEED)
            if newAlpha > 0 then
                self:SetAlpha(newAlpha)
            else
                RemoveLine(self)
            end
        end)
    end

    if not PL.plusWidth then PL.plusWidth = ComputePlusWidth() end
    line.plus:SetWidth(PL.plusWidth)

    line:SetAlpha(1)
    line:SetHeight(GetRowHeight())
    line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
    line.icon:SetSize(PL.db.profile.iconSize, PL.db.profile.iconSize)
    line.isPreview = nil
    line.itemLink = nil
    line._fadingStarted = nil
    line._scheduledToStart = nil
    AnchorTextHighlight(line)
    line:Show()
    return line
end

-- =========================================================================
-- Item name colourisation
-- =========================================================================

-- Returns the item name colourised by quality. Falls back to fallbackName if no link is provided
-- or if the item is not yet cached by the client.
local function ColorizeItemName(itemLink, fallbackName)
    if not itemLink and not fallbackName then
        return "|cffffffffUnknown Item|r"
    end

    local itemName = fallbackName or "Unknown Item"
    local quality = DEFAULT_QUALITY

    if itemLink then
        local name, _, linkQuality = GetItemInfo(itemLink)
        if name then itemName = name end
        if linkQuality and linkQuality >= 0 and linkQuality <= 6 then
            quality = linkQuality
        end
    end

    local colorCode = qualityColors[quality] or qualityColors[1]
    return string.format("%s%s|r", colorCode, itemName)
end

-- =========================================================================
-- Add/Update loot entries
-- =========================================================================
local function AddOrUpdateLoot(key, iconPath, textHtml, quantity, isMoney, isCurrency, isLoss, isPreview, itemLink)
    local displayName = StripColors(textHtml)
    if not isPreview and IsBlacklisted(key, displayName) then return end

    local styleSettingIsGoldBrackets = (PL.db.profile.highlightStyle or "") == "goldbrackets"
    local isHighlightEntry = IsHighlighted(key, displayName) or key == "PREVIEW_HIGHLIGHT_ITEM"

    local line
    for _, l in ipairs(activeLines) do
        if l.itemKey == key and ((l.isPreview and isPreview) or (not l.isPreview and not isPreview)) then
            if l.timer and l.timer <= 0 then
                -- Line is fading — don't merge into it, remove it and let a new line be created
                RemoveLine(l)
                break
            else
                line = l
                break
            end
        end
    end

    if line then
        if isHighlightEntry then
            line.highlighted = true
        end

        -- Money, currency, and reputation are signed; losses subtract from the running total.
        if isCurrency or line.isCurrency or line.isReputation or isMoney or line.isMoney then
            local signedQuantity = isLoss and -quantity or quantity
            line.currentCount = (line.currentCount or 0) + signedQuantity
        else
            line.currentCount = (line.currentCount or 0) + quantity
        end

        local finalText = ""

        local applyGoldBrackets = styleSettingIsGoldBrackets and line.highlighted

        if isMoney then
            line.isMoney = true
            local color = line.currentCount >= 0 and "|cff00ff00" or "|cffff0000"
            local text = GetCoinTextureString(math.abs(line.currentCount))
            line.plus:SetText(color..(line.currentCount >= 0 and "+" or "-").."|r")
            finalText = "|cffffffff"..text.."|r"
            line.icon:Hide()
            line.iconBorder:Hide()
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, 0)
            AnchorTextHighlight(line)
        elseif line.isReputation or isCurrency then
            line.isMoney = nil
            if line.currentCount == 0 then RemoveLine(line); return end
            local displayQuantity = math.abs(line.currentCount)
            local sign = line.currentCount >= 0 and "+" or "-"
            local baseName = line.baseName or textHtml

            if line.isReputation then
                line.plus:SetText("|cffffa500REP|r")
            else
                line.plus:SetText("|cff89cff0CUR|r")
            end

            if applyGoldBrackets then
                finalText = string.format("%s |cffffffff%s%d|r", WrapWithGoldBrackets(baseName), sign, displayQuantity)
            else
                finalText = string.format("%s |cffffffff%s%d|r", baseName, sign, displayQuantity)
            end

            -- Reputation hides the icon; currency shows it. Anchor text accordingly.
            line.text:ClearAllPoints()
            if line.isReputation then
                line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, 0)
            else
                line.text:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)
            end
            AnchorTextHighlight(line)
        elseif line.isAuction then
            line.isMoney = nil
            local displayQuantity = line.currentCount or quantity or 1
            local baseName = line.baseName or textHtml
            if displayQuantity > 1 then
                finalText = string.format("%s sold! x%d", baseName, displayQuantity)
            else
                finalText = baseName .. " sold!"
            end
            line.plus:SetText("|cffff8800AH|r")
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, 0)
            AnchorTextHighlight(line)
        else
            -- Regular items
            line.isMoney = nil
            local prettyName = ColorizeItemName(line.itemLink, StripColors(line.baseName or textHtml))
            if applyGoldBrackets then
                finalText = string.format("%s x%d", WrapWithGoldBrackets(prettyName), line.currentCount or quantity or 1)
            else
                finalText = string.format("%s x%d", prettyName, line.currentCount or quantity or 1)
            end

            line.text:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)
            line.plus:SetText("|cff00ff00+|r")
            AnchorTextHighlight(line)
        end

        line.text:SetText(finalText)

        if line.highlighted then
            line.timer = GetHighlightDuration()
        else
            line.timer = GetBaseDurationForLine(line)
        end

        -- When fadeAsGroup is enabled, refreshing any line also resets timers for all
        -- other active lines, provided no cascade is already in progress.
        if not isPreview and PL.db.profile.fadeAsGroup and not cascadeState.active then
            for _, other in ipairs(activeLines) do
                if other ~= line and other.timer and other.timer > 0 and not other._fadingStarted then
                    if other.highlighted then
                        other.timer = GetHighlightDuration()
                    else
                        other.timer = GetBaseDurationForLine(other)
                    end
                    other:SetAlpha(1)
                    other.slideX = 0
                    other:SetPoint("TOPLEFT", other.anchorRef or UIParent, other.anchorPoint or "TOPLEFT", other.slideX, other.anchorYOffset or 0)
                end
            end
        end

        RecalculateQueue()
    else
        line = GetLine()
        line.itemKey = key
        line.itemLink = itemLink
        line.isPreview = isPreview and true or nil
        line.isReputation = type(key) == "string" and key:match("^REPUTATION_") ~= nil
        line.isAuction = type(key) == "string" and key:match("^AUCTION_") ~= nil
        if isCurrency then
            line.currentCount = isLoss and -quantity or quantity
        elseif isMoney then
            line.currentCount = isLoss and -quantity or quantity
        elseif line.isReputation then
            line.currentCount = isLoss and -quantity or quantity
        else
            -- Items and auctions: plain quantity, no sign
            line.currentCount = quantity
        end
        line.isMoney = isMoney and true or nil
        line.timer = GetBaseDurationForLine(line)

        local finalText = ""

        local applyGoldBrackets = styleSettingIsGoldBrackets and isHighlightEntry

        if isMoney then
            line.icon:Hide()
            line.iconBorder:Hide()
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
            line.text:SetText("|cffffffff"..GetCoinTextureString(math.abs(line.currentCount)).."|r")
            line.plus:SetText(line.currentCount >= 0 and "|cff00ff00+|r" or "|cffff0000-|r")
            AnchorTextHighlight(line)
        elseif line.isReputation then
            line.icon:Hide()
            line.iconBorder:Hide()
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
            local displayQuantity = math.abs(line.currentCount)
            local sign = line.currentCount >= 0 and "+" or "-"
            line.plus:SetText("|cffffa500REP|r")
            if applyGoldBrackets then
                finalText = string.format("%s |cffffffff%s%d|r", WrapWithGoldBrackets(textHtml), sign, displayQuantity)
            else
                finalText = string.format("%s |cffffffff%s%d|r", textHtml, sign, displayQuantity)
            end
            line.text:SetText(finalText)
            AnchorTextHighlight(line)
        elseif isCurrency then
            line.icon:Show()
            line.iconBorder:Show()
            line.icon:SetTexture(iconPath or DEFAULT_ICON)
            line.icon:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapWithIcon or 6, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
            local displayQuantity = math.abs(line.currentCount)
            local sign = line.currentCount >= 0 and "+" or "-"
            if applyGoldBrackets then
                finalText = string.format("%s |cffffffff%s%d|r", WrapWithGoldBrackets(textHtml), sign, displayQuantity)
            else
                finalText = string.format("%s |cffffffff%s%d|r", textHtml, sign, displayQuantity)
            end
            line.plus:SetText("|cff89cff0CUR|r")
            line.text:SetText(finalText)
            AnchorTextHighlight(line)
        elseif line.isAuction then
            line.icon:Hide()
            line.iconBorder:Hide()
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapNoIcon or 2, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
            local displayQuantity = line.currentCount or quantity
            if displayQuantity > 1 then
                finalText = string.format("%s sold! x%d", textHtml, displayQuantity)
            else
                finalText = textHtml .. " sold!"
            end
            line.plus:SetText("|cffff8800AH|r")
            line.text:SetText(finalText)
            AnchorTextHighlight(line)
        else
            line.icon:Show()
            line.iconBorder:Show()
            line.icon:SetTexture(iconPath or DEFAULT_ICON)
            line.icon:SetPoint("LEFT", line.plus, "RIGHT", PL.db.profile.iconGapWithIcon or 6, PL.db.profile.indicatorVerticalOffset or 0)
            line.text:ClearAllPoints()
            line.text:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)
            line.text:SetFont(GetFont(), PL.db.profile.textSize, "OUTLINE")
            local prettyName = ColorizeItemName(itemLink or line.itemLink, StripColors(textHtml))
            if applyGoldBrackets then
                finalText = string.format("%s x%d", WrapWithGoldBrackets(prettyName), quantity)
            else
                finalText = string.format("%s x%d", prettyName, quantity)
            end
            line.text:SetText(finalText)
            line.plus:SetText("|cff00ff00+|r")
            AnchorTextHighlight(line)
        end

        if isHighlightEntry then
            line.highlighted = true
            line.timer = GetHighlightDuration()
            StartHighlightVisual(line)
            if PL.db.profile.playSoundOnHighlight and not isPreview then
                local now = GetTime()
                local soundKey = PL.db.profile.highlightSound
                local sound = nil
                if soundKey and soundKey ~= "" and LSM and LSM.Fetch then
                    local ok, s = pcall(function() return LSM:Fetch("sound", soundKey) end)
                    if ok then sound = s end
                end
                pcall(function()
                    if type(sound) == "string" then PlaySoundFile(sound, "Master") end
                end)
                lastSoundTime = now
            end
        else
            line.highlighted = nil
        end

        InsertLineByPriority(line)

        -- When fadeAsGroup is enabled, adding a new line also resets timers for all
        -- other active lines, provided no cascade is already in progress.
        if not isPreview and PL.db.profile.fadeAsGroup and not cascadeState.active then
            for _, other in ipairs(activeLines) do
                if other ~= line and other.timer and other.timer > 0 and not other._fadingStarted then
                    if other.highlighted then
                        other.timer = GetHighlightDuration()
                    else
                        other.timer = GetBaseDurationForLine(other)
                    end
                    other:SetAlpha(1)
                    other.slideX = 0
                    other:SetPoint("TOPLEFT", other.anchorRef or highlight, other.anchorPoint or "TOPLEFT", other.slideX, other.anchorYOffset or 0)
                end
            end
        end

        RemoveLowestPriorityLine()
        RecalculateQueue()
    end
end

-- =========================================================================
-- Throttled queue
-- =========================================================================
local eventQueue = {}
local flushTimerActive = false

local function FlushEventQueue()
    flushTimerActive = false
    if #eventQueue == 0 then return end

    local merged = {}
    for _, ev in ipairs(eventQueue) do
        local key = ev.key
        if not merged[key] then
            merged[key] = {
                key          = key,
                icon         = ev.icon,
                text         = ev.text,
                signed       = ev.signed or 0,
                qty          = ev.qty or 0,
                isMoney      = ev.isMoney,
                isCurrency   = ev.isCurrency,
                isReputation = ev.isReputation,
                isAuction    = ev.isAuction,
                itemLink     = ev.itemLink,
            }
        else
            merged[key].signed = (merged[key].signed or 0) + (ev.signed or 0)
            merged[key].qty    = (merged[key].qty or 0) + (ev.qty or 0)
        end
    end

    eventQueue = {}

    for _, m in pairs(merged) do
        if m.isMoney then
            if (m.signed or 0) ~= 0 then
                local isLoss = (m.signed or 0) < 0
                AddOrUpdateLoot("MONEY", nil, GetCoinTextureString(math.abs(m.signed)), math.abs(m.signed), true, false, isLoss, false, nil)
            end
        elseif m.isCurrency or m.isReputation then
            local signed = m.signed or 0
            if signed == 0 then
                if (m.qty or 0) > 0 then
                    AddOrUpdateLoot(m.key, m.icon, m.text, m.qty, false, m.isCurrency, false, false, m.itemLink)
                end
            else
                AddOrUpdateLoot(m.key, m.icon, m.text, math.abs(signed), false, m.isCurrency, signed < 0, false, m.itemLink)
            end
        else
            if (m.qty or 0) > 0 then
                AddOrUpdateLoot(m.key, m.icon, m.text, m.qty, false, false, false, false, m.itemLink)
            end
        end
    end
end

local function QueueEvent(ev)
    table.insert(eventQueue, ev)
    if not flushTimerActive then
        flushTimerActive = true
        C_Timer.After(FLUSH_DELAY, FlushEventQueue)
    end
end

-- =========================================================================
-- Profile helpers
-- =========================================================================
local function CopyProfileValuesTo(targetProfileTable, sourceProfileTable)
    -- Wipe target first to avoid stale keys persisting from the old profile.
    for k in pairs(targetProfileTable) do
        targetProfileTable[k] = nil
    end
    for k, v in pairs(sourceProfileTable) do
        targetProfileTable[k] = DeepCopy(v)
    end
end

function PrettyLoot:ApplyCharacterProfileDefault()
    UpdateParsedLists()
end

-- Creates a new profile from addon defaults, or switches to it if it already exists.
function PrettyLoot:CreateProfile(newName)
    local db = self.db
    if not newName or Trim(newName) == "" then
        DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: profile name required")
        return
    end

    local exists = false
    for _, n in ipairs(db:GetProfiles()) do
        if n == newName then exists = true; break end
    end

    if exists then
        -- Profile already exists; switch to it rather than overwriting.
        db.profile.locked = true
        if highlight then highlight:Hide() end
        if highlightHeader then highlightHeader:Hide() end
        if highlightText then highlightText:Hide() end

        db:SetProfile(newName)
        self:ApplySavedPosition()
        UpdateParsedLists()
        if AceConfigRegistry then AceConfigRegistry:NotifyChange("PrettyLoot") end
        return
    end

    -- New profile: initialise from addon defaults.
    db:SetProfile(newName)
    CopyProfileValuesTo(db.profile, defaults.profile)

    self:ApplySavedPosition()
    UpdateParsedLists()
    if AceConfigRegistry then AceConfigRegistry:NotifyChange("PrettyLoot") end

    DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: created new profile '" .. newName .. "' from defaults")
end

-- =========================================================================
-- Import / Export helpers
-- =========================================================================
local function SerializeProfileTable(tbl)
    if AceSerializer then
        local ok, s = pcall(function() return AceSerializer:Serialize(tbl) end)
        if ok and s then return s end
    end
    local lines = {}
    for k, _ in pairs(defaults.profile) do
        local v = tbl[k]
        if type(v) == "table" then
            lines[#lines+1] = k .. "=%TABLE%"
        else
            local val = tostring(v):gsub("\n","\\n")
            lines[#lines+1] = k .. "=" .. val
        end
    end
    return table.concat(lines, "\n")
end

local function DeserializeProfileString(s)
    if not s or s == "" then return nil end
    if AceSerializer then
        local ok, obj = pcall(function() return AceSerializer:Deserialize(s) end)
        if ok and obj then return obj end
    end
    local t = {}
    for line in s:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then
            v = v:gsub("\\n", "\n")
            if v == "true" then t[k] = true
            elseif v == "false" then t[k] = false
            elseif tonumber(v) and tostring(tonumber(v)) == v then t[k] = tonumber(v)
            else t[k] = v end
        end
    end
    return t
end

local function removeOkayButtons(frame)
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        if child and child.GetObjectType and child:GetObjectType() == "Button" then
            local text
            if child.GetText then
                local ok, t = pcall(function() return child:GetText() end)
                if ok then
                    text = t
                end
            end

            if text and (text == "Okay" or text == "OK" or text == "OkayButton") then
                child:Hide()
            else
                local name = child.GetName and child:GetName()
                if name and (name:find("Okay", 1, true) or name:find("OK", 1, true)) then
                    child:Hide()
                end
            end
        end
    end
end

local exportFrame = nil
local function OpenExportDialog()
    if exportFrame and exportFrame:IsShown() then
        exportFrame:Raise()
        return
    end

    local WIDTH, HEIGHT = 320, 190
    local PAD = 14
    local innerWidth = WIDTH - PAD * 2
    local editHeight = 88

    local f = CreateFrame("Frame", "PrettyLootExportDialog", UIParent, "DialogBoxFrame")
    f:SetParent(UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel((UIParent:GetFrameLevel() or 0) + 2000)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetMovable(true)
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(true)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("PrettyLoot — Export Profile")

    local instr = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instr:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -36)
    instr:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -36)
    instr:SetJustifyH("LEFT")
    instr:SetText("Profile data. Press Ctrl+C to copy.")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -54)
    scroll:SetSize(innerWidth - 22, editHeight)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(innerWidth - 22 - 8)
    edit:SetHeight(editHeight - 8)
    edit:SetAutoFocus(true)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetTextInsets(4, 4, 4, 4)
    scroll:SetScrollChild(edit)

    local profileCopy = DeepCopy(PL.db.profile)
    local s = SerializeProfileTable(profileCopy)
    edit:SetText(s)
    edit:SetFocus()
    edit:HighlightText()

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(100, 24)
    btnClose:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 12)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)

    removeOkayButtons(f)

    exportFrame = f
    f:Show()
    f:Raise()
end

local importFrame = nil
local function OpenImportDialog()
    if importFrame and importFrame:IsShown() then
        importFrame:Raise()
        return
    end

    local WIDTH, HEIGHT = 320, 190
    local PAD = 14
    local innerWidth = WIDTH - PAD * 2
    local editHeight = 88

    local f = CreateFrame("Frame", "PrettyLootImportDialog", UIParent, "DialogBoxFrame")
    f:SetParent(UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel((UIParent:GetFrameLevel() or 0) + 2000)
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetMovable(true)
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(true)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("PrettyLoot — Import Profile")

    local instr = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instr:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -36)
    instr:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -36)
    instr:SetJustifyH("LEFT")
    instr:SetText("Paste profile data here, then click Import to apply it.")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -54)
    scroll:SetSize(innerWidth - 22, editHeight)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(innerWidth - 22 - 8)
    edit:SetHeight(editHeight - 8)
    edit:SetAutoFocus(true)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetTextInsets(4, 4, 4, 4)
    scroll:SetScrollChild(edit)

    local btnImport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnImport:SetSize(100, 24)
    btnImport:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 12)
    btnImport:SetText("Import")
    btnImport:SetScript("OnClick", function()
        local txt = edit:GetText()
        if not txt or txt == "" then
            DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: paste profile data first")
            return
        end
        local t = DeserializeProfileString(txt)
        if not t then
            DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: import failed (invalid data)")
            return
        end
        for k, _ in pairs(defaults.profile) do
            if t[k] ~= nil then
                PL.db.profile[k] = DeepCopy(t[k])
            end
        end
        UpdateParsedLists()
        PrettyLoot:ApplySavedPosition()
        DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: profile data imported into current profile")
        f:Hide()
    end)

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(100, 24)
    btnClose:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 12)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)

    removeOkayButtons(f)

    importFrame = f
    f:Show()
    f:Raise()
end

-- =========================================================================
-- Helper wrappers to safely fetch LSM tables
-- =========================================================================
local function SafeLSMHashTable(kind)
    local l = LibStub("LibSharedMedia-3.0", true)
    if not l then return {} end
    local ok, t = pcall(function() return l:HashTable(kind) end)
    if ok and type(t) == "table" then return t end
    return {}
end

-- =========================================================================
-- Options (LSM-safe handling)
-- =========================================================================
function PrettyLoot:SetupOptions()
    local function GetProfileList()
        local t = {}
        for _, name in ipairs(self.db:GetProfiles()) do t[name] = name end
        return t
    end

    local highlightStyles = {
        background = "Background colour",
        goldbrackets = "Gold brackets",
    }

    -- Use LSM widget types in the options UI when AceGUI and the LSM widgets are available.
    local AceGUI = LibStub("AceGUI-3.0", true)
    local lsm_has_font_widget = false
    local lsm_has_sound_widget = false
    if AceGUI and AceGUI.WidgetVersions then
        lsm_has_font_widget = AceGUI.WidgetVersions["LSM30_Font"] ~= nil
        lsm_has_sound_widget = AceGUI.WidgetVersions["LSM30_Sound"] ~= nil
    end

    local fontDialogControl = lsm_has_font_widget and "LSM30_Font" or nil
    local soundDialogControl = lsm_has_sound_widget and "LSM30_Sound" or nil

    local options = {
        name = "PrettyLoot",
        handler = self,
        type = "group",
        childGroups = "tree",
        args = {
            lock = {
                type = "toggle",
                name = "Lock Window",
                order = 1,
                get = function() return self.db.profile.locked end,
                set = function(info, value)
                    self.db.profile.locked = value
                    if value then
                        if highlight then highlight:Hide() end
                        if highlightHeader then highlightHeader:Hide() end
                        if highlightText then highlightText:Hide() end
                    else
                        if highlight then highlight:Show() end
                        if highlightHeader then highlightHeader:Show() end
                        if highlightText then highlightText:Show() end
                        UpdateHighlightSize()
                    end
                end,
            },

            preview = {
                type = "execute",
                name = "Preview Loot",
                order = 2,
                desc = "Show a demo set of loot notifications demonstrating priority ordering.",
                func = function()
                    ClearPreviewLines()

                    AddOrUpdateLoot("PREVIEW_MONEY", nil, GetCoinTextureString(12345), 12345, true, false, false, true, nil)
                    AddOrUpdateLoot("PREVIEW_REP", nil, "|cffffa500Preview Reputation|r", 50, false, false, false, true, nil)
                    AddOrUpdateLoot("PREVIEW_ITEM", "Interface\\Icons\\INV_Misc_Herb_16", "|cffffffffPreview Item|r", 3, false, false, false, true, nil)

                    local highlightName = "|cff00ff00Highlighted Preview Item|r"
                    AddOrUpdateLoot("PREVIEW_HIGHLIGHT_ITEM", "Interface\\Icons\\INV_Misc_Rune_01", highlightName, 1, false, false, false, true, nil)
                end,
            },

            resetPos = {
                type = "execute",
                name = "Reset Position",
                order = 3,
                func = function()
                    self.db.profile.x = defaults.profile.x
                    self.db.profile.y = defaults.profile.y
                    self:ApplySavedPosition()
                end,
            },

            general = {
                type = "group",
                name = "General",
                order = 10,
                args = {
                    trackingHeader = { type = "header", name = "Tracking Options", order = 1 },
                    trackReputation = {
                        type = "toggle",
                        name = "Track Reputation",
                        order = 2,
                        get = function() return self.db.profile.trackReputation end,
                        set = function(info, value) self.db.profile.trackReputation = value end,
                    },
                    trackAuctions = {
                        type = "toggle",
                        name = "Track Auction Sales",
                        order = 3,
                        get = function() return self.db.profile.trackAuctions end,
                        set = function(info, value) self.db.profile.trackAuctions = value end,
                    },

                    pinHeader = { type = "header", name = "Pinning / Priority", order = 4 },
                    goldStaysOnTop = {
                        type = "toggle",
                        name = "Gold stays on top",
                        desc = "Keep gold gain/loss entries visible when the list overflows.",
                        order = 4.1,
                        get = function() return self.db.profile.goldStaysOnTop end,
                        set = function(info, v)
                            self.db.profile.goldStaysOnTop = v
                            table.sort(activeLines, function(a, b)
                                return getPriority(a) < getPriority(b)
                            end)
                            RecalculateQueue()
                        end,
                    },

                    groupFadeHeader = { type = "header", name = "Group Fade", order = 5 },
                    fadeAsGroup = {
                        type = "toggle",
                        name = "Fade as group",
                        desc = "When enabled, looting a new item resets timers of currently displayed items so they eventually leave together. Departure cascades bottom-to-top.",
                        order = 5.1,
                        get = function() return self.db.profile.fadeAsGroup end,
                        set = function(info, v) self.db.profile.fadeAsGroup = v end,
                    },

                    durationsHeader = { type = "header", name = "Duration Settings", order = 10 },
                    durationHighlight = {
                        type = "range",
                        name = "Duration: Highlighted",
                        desc = "How long highlighted items stay on screen before fading.",
                        min = 1,
                        max = 60,
                        step = 1,
                        order = 11,
                        get = function() return self.db.profile.durationHighlight or 10 end,
                        set = function(info, v) self.db.profile.durationHighlight = v end,
                    },
                    globalDuration = { type = "range", name = "Global Duration (All entries)", min = 1, max = 60, step = 1, order = 12, get = function() return self.db.profile.holdDuration end, set = function(info, v) self.db.profile.holdDuration = v end },
                },
            },

            display = {
                type = "group",
                name = "Display",
                order = 20,
                args = {
                    displayHeader = { type = "header", name = "Display Settings", order = 1 },

                    positionHeader = { type = "header", name = "Position", order = 2 },
                    posX = {
                        type = "range",
                        name = "X Offset",
                        order = 3,
                        min = -2000, max = 2000, step = 1,
                        get = function() return self.db.profile.x or defaults.profile.x end,
                        set = function(info, v)
                            self.db.profile.x = v
                            self:ApplySavedPosition()
                        end,
                    },
                    posY = {
                        type = "range",
                        name = "Y Offset",
                        order = 4,
                        min = -2000, max = 2000, step = 1,
                        get = function() return self.db.profile.y or defaults.profile.y end,
                        set = function(info, v)
                            self.db.profile.y = v
                            self:ApplySavedPosition()
                        end,
                    },

                    iconSize = { type = "range", name = "Icon Size", min = 8, max = 30, step = 1, order = 5, get = function() return self.db.profile.iconSize end, set = function(info, v) self.db.profile.iconSize = v for _,line in ipairs(activeLines) do line.icon:SetSize(v, v) end UpdateHighlightSize(); RecalculateQueue() end },
                    textSize = { type = "range", name = "Text Size", min = 8, max = 30, step = 1, order = 6, get = function() return self.db.profile.textSize end, set = function(info, v) self.db.profile.textSize = v for _,line in ipairs(activeLines) do line.text:SetFont(GetFont(), v, "OUTLINE") end PL.plusWidth = ComputePlusWidth(); for _,line in ipairs(activeLines) do if line.plus then line.plus:SetWidth(PL.plusWidth) end end UpdateHighlightSize(); RecalculateQueue() end },
                    rowHeight = { type = "range", name = "Row Height", min = 10, max = 30, step = 1, order = 7, get = function() return self.db.profile.rowHeight end, set = function(info, v) self.db.profile.rowHeight = v for _,line in ipairs(activeLines) do line:SetHeight(v) end UpdateHighlightSize(); RecalculateQueue() end },
                    rowSpacing = { type = "range", name = "Row Spacing", min = 0, max = 10, step = 1, order = 8, get = function() return self.db.profile.rowSpacing end, set = function(info, v) self.db.profile.rowSpacing = v UpdateHighlightSize(); RecalculateQueue() end },
                    maxItems = { type = "range", name = "Max Items", min = 1, max = 30, step = 1, order = 9, get = function() return self.db.profile.maxItems end, set = function(info, v) self.db.profile.maxItems = v while #activeLines > v do RemoveLowestPriorityLine() end UpdateHighlightSize(); RecalculateQueue() end },
                    font = {
                        type = "select",
                        dialogControl = fontDialogControl,
                        name = "Font",
                        values = function()
                            return SafeLSMHashTable("font")
                        end,
                        order = 10,
                        get = function() return self.db.profile.fontKey end,
                        set = function(info, key) self.db.profile.fontKey = key for _,line in ipairs(activeLines) do line.text:SetFont(GetFont(), self.db.profile.textSize, "OUTLINE") end PL.plusWidth = ComputePlusWidth(); for _,line in ipairs(activeLines) do if line.plus then line.plus:SetWidth(PL.plusWidth) end end RecalculateQueue() end },
                },
            },

            lists = {
                type = "group",
                name = "Blacklist / Highlight",
                order = 30,
                args = {
                    soundHeader = { type = "header", name = "Sound Settings", order = 1 },
                    playSoundOnHighlight = { type = "toggle", name = "Play sound on highlight", order = 2, get = function() return self.db.profile.playSoundOnHighlight end, set = function(info, v) self.db.profile.playSoundOnHighlight = v end },
                    highlightSound = { type = "select", dialogControl = soundDialogControl, name = "Highlight sound", order = 3, values = function() return SafeLSMHashTable("sound") end, get = function() return self.db.profile.highlightSound end, set = function(info, key) self.db.profile.highlightSound = key end },

                    visualHeader = { type = "header", name = "Highlight Visuals", order = 5 },
                    highlightStyle = { type = "select", name = "Highlight style", order = 6, values = highlightStyles, get = function() return self.db.profile.highlightStyle or "goldbrackets" end, set = function(info, v) self.db.profile.highlightStyle = v end },
                    highlightBackgroundColour = { type = "color", name = "Highlight background colour", order = 7, hasAlpha = true, hidden = function() return (self.db.profile.highlightStyle or "goldbrackets") ~= "background" end, get = function() local c = self.db.profile.highlightBackgroundColour or { r = 0.4, g = 0.2, b = 0.7, a = 0.25 } return c.r or 0.4, c.g or 0.2, c.b or 0.7, c.a or 0.25 end, set = function(info, r, g, b, a) self.db.profile.highlightBackgroundColour = { r = r, g = g, b = b, a = a } end },

                    previewHighlight = { type = "execute", name = "Preview highlighted item", order = 8, desc = "Show a single highlighted item using the current highlight settings.", func = function() ClearPreviewLines(); local highlightName = "|cff00ff00Highlighted Preview Item|r"; AddOrUpdateLoot("PREVIEW_HIGHLIGHT_ITEM", "Interface\\Icons\\INV_Misc_Rune_01", highlightName, 1, false, false, false, true, nil) end },

                    listsHeader = { type = "header", name = "Lists", order = 10 },
                    blacklistDesc = { type = "description", name = "Blacklisted Items: these entries are ignored. Enter exact names or use '*' wildcards (case-insensitive). You can also enter numeric IDs or prefixes like CURRENCY:123.", order = 11 },
                    blacklist = { type = "input", multiline = true, width = "full", name = "Blacklisted Items", desc = "Comma or newline separated. Example: Silk Cloth, Silk*, 12345, CURRENCY:789", order = 12, get = function() return self.db.profile.blacklist end, set = function(info, v) self.db.profile.blacklist = v UpdateParsedLists() end },

                    highlightDesc = { type = "description", name = "Highlighted Items: entries here extend display time and optionally play sound. Use exact names or '*' wildcards (case-insensitive).", order = 20 },
                    highlight = { type = "input", multiline = true, width = "full", name = "Highlighted Items", desc = "Comma or newline separated. Example: Opulent Bracers, *cloth, REPUTATION:123", order = 21, get = function() return self.db.profile.highlight end, set = function(info, v) self.db.profile.highlight = v UpdateParsedLists() end },
                },
            },

            profiles = {
                type = "group",
                name = "Profiles",
                order = 40,
                args = {
                    profileHeader = { type = "header", name = "Profile Management", order = 1 },
                    profileSelect = {
                        type = "select",
                        name = "Active Profile",
                        desc = "Switch profiles",
                        order = 2,
                        values = function() return GetProfileList() end,
                        get = function() return self.db:GetCurrentProfile() end,
                        set = function(info, name)
                            self.db.profile.locked = true
                            if highlight then highlight:Hide() end
                            if highlightHeader then highlightHeader:Hide() end
                            if highlightText then highlightText:Hide() end

                            self.db:SetProfile(name)
                            UpdateParsedLists()
                            self:ApplySavedPosition()

                            if AceConfigRegistry then AceConfigRegistry:NotifyChange("PrettyLoot") end
                        end,
                    },

                    copyFromHeader = {
                        type = "header",
                        name = "Copy From",
                        order = 5,
                    },
                    copyFrom = {
                        type = "select",
                        name = "Copy settings from...",
                        desc = "Copy settings from another profile into the current profile.",
                        order = 6,
                        values = function() return GetProfileList() end,
                        get = function() return "" end,
                        set = function(info, sourceName)
                            local db = PrettyLoot.db
                            local currentName = db:GetCurrentProfile()
                            if sourceName == currentName then
                                DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: cannot copy a profile into itself")
                                return
                            end

                            local tmp = {}
                            db:SetProfile(sourceName)
                            CopyProfileValuesTo(tmp, db.profile)

                            db:SetProfile(currentName)
                            CopyProfileValuesTo(db.profile, tmp)

                            PrettyLoot:ApplySavedPosition()
                            UpdateParsedLists()
                            if AceConfigRegistry then AceConfigRegistry:NotifyChange("PrettyLoot") end

                            DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: copied settings from '" .. sourceName .. "' into '" .. currentName .. "'")
                        end,
                    },

                    newProfileName = {
                        type = "input",
                        name = "New profile name",
                        desc = "Enter a name for a new profile.",
                        order = 10,
                        width = "full",
                        get = function() return PL._newProfileName or "" end,
                        set = function(info, val) PL._newProfileName = Trim(val) end,
                    },

                    createProfile = {
                        type = "execute",
                        name = "Create profile",
                        desc = "Create a new profile from addon defaults.",
                        order = 11,
                        func = function()
                            local name = PL._newProfileName
                            if not name or name == "" then
                                DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: enter a name in the 'New profile name' box first")
                                return
                            end
                            PrettyLoot:CreateProfile(name)
                            PL._newProfileName = ""
                        end,
                    },

                    deleteProfile = {
                        type = "execute",
                        name = "Delete current profile",
                        desc = "Delete the current profile (you will be switched back to Default).",
                        order = 20,
                        func = function()
                            local sel = PrettyLoot.db:GetCurrentProfile()
                            if not sel then
                                DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: no active profile to delete")
                                return
                            end
                            if sel == "Default" then
                                DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: cannot delete Default profile")
                                return
                            end
                            StaticPopupDialogs["PRETTYLOOT_DELETE_PROFILE"] = StaticPopupDialogs["PRETTYLOOT_DELETE_PROFILE"] or {
                                text = "Delete profile '%s'? This cannot be undone.\n\nYou will be switched back to the Default profile.",
                                button1 = "Delete",
                                button2 = "Cancel",
                                OnAccept = function(self, data)
                                    PrettyLoot:DeleteProfile(data)
                                end,
                                timeout = 0,
                                whileDead = true,
                                hideOnEscape = true,
                            }
                            StaticPopup_Show("PRETTYLOOT_DELETE_PROFILE", sel, nil, sel)
                        end,
                    },

                    exportProfile = {
                        type = "execute",
                        name = "Export Profile",
                        desc = "Export the current profile and open a copyable dialog.",
                        order = 30,
                        func = function() OpenExportDialog() end,
                    },

                    importProfile = {
                        type = "execute",
                        name = "Import Profile",
                        desc = "Open the Import dialog to paste profile data.",
                        order = 31,
                        func = function() OpenImportDialog() end,
                    },
                },
            },
        },
    }

    AceConfig:RegisterOptionsTable("PrettyLoot", options)
    if AceConfigDialog and AceConfigDialog.AddToBlizOptions then
        AceConfigDialog:AddToBlizOptions("PrettyLoot", "PrettyLoot")
    end
end

-- =========================================================================
-- Media registration
-- Registers bundled fonts and sounds with LibSharedMedia so they appear
-- in the options dropdowns alongside any other installed LSM media.
-- =========================================================================
function PrettyLoot:RegisterMedia()
    local lsm = LibStub("LibSharedMedia-3.0", true)
    if not lsm then return end

    -- Media names appear in the options dropdowns.
    pcall(function()
        lsm:Register("font", "Expressway", "Interface\\AddOns\\PrettyLoot\\Media\\expressway.ttf")
        lsm:Register("sound", "PL Coin", "Interface\\AddOns\\PrettyLoot\\Media\\plCoin.ogg")
        lsm:Register("sound", "PL Jingle", "Interface\\AddOns\\PrettyLoot\\Media\\plJingle.ogg")
        lsm:Register("sound", "PL Achievement", "Interface\\AddOns\\PrettyLoot\\Media\\plAchievement.ogg")
        lsm:Register("sound", "PL Email", "Interface\\AddOns\\PrettyLoot\\Media\\plEmail.ogg")
    end)

    if AceConfigRegistry then AceConfigRegistry:NotifyChange("PrettyLoot") end
end

-- =========================================================================
-- Event handlers
-- =========================================================================
function PrettyLoot:CHAT_MSG_LOOT(event, message)
    if not message then return end

    local playerName = UnitName("player")

    -- Only process canonical loot receipt messages for the player.
    -- This avoids:
    --   * other players winning rolls showing in the display
    --   * duplicate x2 loot entries from secondary loot events
    local isPlayerLoot =
        message:find("^You receive loot:")
        or message:find("^" .. playerName .. " receives loot:")

    if not isPlayerLoot then
        return
    end

    -- Ignore roll-selection and roll-result spam.
    if message then
        local lower = string.lower(message)

        if lower:find("^greed roll")
        or lower:find("^need roll")
        or lower:find("^you have selected")
        or lower:find("selected need for:")
        or lower:find("selected greed for:")
        or lower:find("passed on:")
        or lower:find("you won:")
        or lower:find("won:")
        then
            return
        end
    end

    local itemLink = string.match(message or "", "|Hitem:.-|h.-|h|r")
    if not itemLink then return end

    local quantity = tonumber(string.match(message, "x(%d+)")) or 1
    local itemID = tonumber(string.match(itemLink, "item:(%d+)"))

    if not itemID or itemID == 0 then
        return
    end

    local itemName, _, itemQuality, _, _, _, _, _, _, itemIcon = GetItemInfo(itemLink)

    itemName = itemName or string.match(message, "%[(.-)%]") or "Unknown Item"
    itemIcon = itemIcon or DEFAULT_ICON
    itemQuality = itemQuality or DEFAULT_QUALITY

    local colorCode = qualityColors[itemQuality] or qualityColors[1]

    ClearPreviewLines()

    QueueEvent({
        key = tostring(itemID),
        icon = itemIcon,
        text = colorCode .. itemName .. "|r",
        qty = quantity,
        isMoney = false,
        isCurrency = false,
        itemLink = itemLink,
    })
end

function PrettyLoot:PLAYER_MONEY()
    local newMoney = GetMoney()
    local oldMoney = self.savedOldMoney or newMoney
    if newMoney == oldMoney then return end

    local moneyChange, isLoss
    if newMoney > oldMoney then
        moneyChange = newMoney - oldMoney
        isLoss = false
    else
        moneyChange = oldMoney - newMoney
        isLoss = true
    end

    self.savedOldMoney = newMoney
    local signed = isLoss and -moneyChange or moneyChange

    ClearPreviewLines()
    QueueEvent({ key = "MONEY", icon = nil, text = GetCoinTextureString(math.abs(signed)), signed = signed, qty = math.abs(signed), isMoney = true })
end

function PrettyLoot:PLAYER_ENTERING_WORLD(event, isLogin, isReload)
    C_Timer.After(1, function()
        PL.plusWidth = ComputePlusWidth()
        UpdateParsedLists()
    end)
end

function PrettyLoot:CHAT_MSG_COMBAT_FACTION_CHANGE(event, message)
    if not self.db.profile.trackReputation or not message then return end
    ClearPreviewLines()

    local faction, amount, isLoss

    -- Explicit gain patterns
    local f, a
    f, a = string.match(message, "Your (.-)%s+reputation has increased by (%d+)")
    if f then faction, amount, isLoss = f, a, false end

    if not faction then
        f, a = string.match(message, "Reputation with (.-)%s+increased by (%d+)")
        if f then faction, amount, isLoss = f, a, false end
    end
    if not faction then
        a, f = string.match(message, "You have gained (%d+) reputation with (.-)%s*%.")
        if f then faction, amount, isLoss = f, a, false end
    end
    if not faction then
        a, f = string.match(message, "You gain (%d+) reputation with (.-)%s*%.")
        if f then faction, amount, isLoss = f, a, false end
    end

    -- Explicit loss patterns
    if not faction then
        f, a = string.match(message, "Your (.-)%s+reputation has decreased by (%d+)")
        if f then faction, amount, isLoss = f, a, true end
    end
    if not faction then
        f, a = string.match(message, "Reputation with (.-)%s+decreased by (%d+)")
        if f then faction, amount, isLoss = f, a, true end
    end
    if not faction then
        a, f = string.match(message, "You have lost (%d+) reputation with (.-)%s*%.")
        if f then faction, amount, isLoss = f, a, true end
    end
    if not faction then
        a, f = string.match(message, "You lose (%d+) reputation with (.-)%s*%.")
        if f then faction, amount, isLoss = f, a, true end
    end

    if not faction or not amount then return end

    faction = faction:match("^%s*(.-)%s*$")

    amount = tonumber(amount)

    -- Scan the faction list to resolve the current standing colour.
    local factionKey = faction
    local color = "|cffffffff"
    local standing = nil

    local numFactions = GetNumFactions and GetNumFactions() or 0
    local fl = string.lower(faction)
    for i = 1, numFactions do
        local name, _, standingID = GetFactionInfo(i)
        if name and (name == faction or string.lower(name) == fl) then
            standing = standingID
            factionKey = name
            break
        end
    end

    if standing then
        color = repColors[standing] or color
    end

    QueueEvent({
        key = "REPUTATION_" .. factionKey,
        icon = nil,
        text = color .. faction .. "|r",
        signed = isLoss and -amount or amount,
        qty = amount,
        isReputation = true,
    })
end

function PrettyLoot:CHAT_MSG_SYSTEM(event, message)
    if not self.db.profile.trackAuctions or not message then return end

    local itemName = string.match(message, "^Your auction of (.+) sold%.$")
    if not itemName then return end

    QueueEvent({
        key       = "AUCTION_" .. itemName,
        icon      = nil,
        text      = itemName,
        signed    = 1,
        qty       = 1,
        isAuction = true,
    })
end

-- =========================================================================
-- Initialisation
-- =========================================================================
function PrettyLoot:ApplySavedPosition()
    anchor:ClearAllPoints()
    anchor:SetPoint("CENTER", UIParent, "CENTER", self.db.profile.x or defaults.profile.x, self.db.profile.y or defaults.profile.y)
end

function PrettyLoot:OnInitialize()
    self.db = AceDB:New("PrettyLootDB", defaults, true)

    if self.db:GetCurrentProfile() ~= "Default" then
        self.db:SetProfile("Default")
    end

    anchor = CreateFrame("Frame", "PrettyLootAnchor", UIParent)
    anchor:SetSize(300, 25)
    anchor:SetMovable(true)
    anchor:EnableMouse(false)
    anchor:SetClampedToScreen(true)

    highlightHeader = CreateFrame("Frame", nil, anchor)
    highlightHeader:SetSize(300, 25)
    highlightHeader:SetPoint("TOP", anchor, "TOP", 0, 0)
    local headerBg = highlightHeader:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(0, 0.5, 0, 0.4)
    highlightText = highlightHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    highlightText:SetPoint("CENTER", highlightHeader, "CENTER", 0, 0)
    highlightText:SetText("Pretty Loot")
    highlightText:SetTextColor(1,1,1,1)
    highlightText:Hide()
    highlightHeader:EnableMouse(true)
    highlightHeader:RegisterForDrag("LeftButton")
    highlightHeader:SetScript("OnDragStart", function()
        if not self.db.profile.locked then
            anchor:StartMoving()
        end
    end)
    highlightHeader:SetScript("OnDragStop", function()
        if not self.db.profile.locked then
            anchor:StopMovingOrSizing()
            local _,_,_,x,y = anchor:GetPoint()
            self.db.profile.x = x
            self.db.profile.y = y
        end
    end)
    highlightHeader:Hide()

    highlight = CreateFrame("Frame", nil, anchor)
    highlight:SetPoint("TOP", highlightHeader, "BOTTOM", 0, 0)
    local highlightBg = highlight:CreateTexture(nil, "BACKGROUND")
    highlightBg:SetAllPoints()
    highlightBg:SetColorTexture(0,0,0,0.0)
    highlight:Hide()

    self:ApplySavedPosition()
    UpdateHighlightSize()

    self:SetupOptions()
    UpdateParsedLists()

    self:RegisterChatCommand("pl", "SlashCommand")

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00PrettyLoot Loaded|r - Type /pl for options")
end

function PrettyLoot:OnEnable()
    self:RegisterEvent("CHAT_MSG_LOOT")
    self:RegisterEvent("CHAT_MSG_SYSTEM")
    self:RegisterEvent("PLAYER_MONEY")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
    self.savedOldMoney = GetMoney()

    -- Delay media registration slightly to ensure LSM is fully initialised.
    C_Timer.After(0.2, function() PrettyLoot:RegisterMedia() end)
end

function PrettyLoot:SlashCommand(msg)
    msg = (msg or ""):lower()
    if msg == "unlock" then
        self.db.profile.locked = false
        if highlight then highlight:Show() end
        if highlightHeader then highlightHeader:Show() end
        if highlightText then highlightText:Show() end
    elseif msg == "lock" then
        self.db.profile.locked = true
        if highlight then highlight:Hide() end
        if highlightHeader then highlightHeader:Hide() end
        if highlightText then highlightText:Hide() end
    elseif msg:match("^create%s+(.+)$") then
        local name = msg:match("^create%s+(.+)$")
        if name and Trim(name) ~= "" then
            self:CreateProfile(name)
        else
            DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: usage: /pl create <profile name>")
        end
    else
        if AceConfigDialog then
            AceConfigDialog:Open("PrettyLoot")
        else
            DEFAULT_CHAT_FRAME:AddMessage("PrettyLoot: options UI not available (AceConfigDialog missing)")
        end
    end
end