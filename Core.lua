-- Keystone Percentile: "Top X%" for your Mythic+ rating and DPS.
-- Shows overall, role, class and spec percentiles from Raider.IO data.
local ADDON, ns = ...
local L = ns.L

local REGION_KEYS = { [1] = "us", [2] = "kr", [3] = "eu", [4] = "tw", [5] = "cn" }
local ROLE_KEYS = { DAMAGER = "dps", HEALER = "healer", TANK = "tank" }
local ROLE_NAMES = { dps = L["DPS"], healer = L["Healer"], tank = L["Tank"] }
local STALE_SECONDS = 7 * 24 * 3600

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Key(name, realm)
  local n = (name or ""):gsub("%s", "")
  local r = (realm or ""):gsub("[%s'%-%(%)]", "")
  return (n .. "-" .. r):lower()
end

local function IsSecret(v)
  return issecretvalue and issecretvalue(v) or false
end

local function GetRegion()
  if KP_DB and KP_DB.region then return KP_DB.region end
  return REGION_KEYS[GetCurrentRegion and GetCurrentRegion() or 0]
end

local function GetScore(unit)
  local ok, summary = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, unit)
  if not ok or not summary then return nil end
  local score = summary.currentSeasonScore
  if score == nil or IsSecret(score) then return nil end
  return math.floor(score + 0.5)
end

local function ScoreColor(score)
  if C_ChallengeMode and C_ChallengeMode.GetDungeonScoreRarityColor then
    local c = C_ChallengeMode.GetDungeonScoreRarityColor(score)
    if c then return c:GenerateHexColor() end
  end
  return "ffffffff"
end

-- Colour the percentage itself: gold for top 1%, purple top 5%, blue top 25%...
local function PctColor(p)
  if p <= 1 then return "ffff8000" end
  if p <= 5 then return "ffa335ee" end
  if p <= 25 then return "ff0070dd" end
  if p <= 50 then return "ff1eff00" end
  return "ffcccccc"
end

local function FormatPct(p)
  if p < 1 then return string.format("%.2f%%", p) end
  if p < 10 then return string.format("%.1f%%", p) end
  return string.format("%d%%", math.floor(p + 0.5))
end

local function Num(n)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

ns.Key, ns.IsSecret, ns.FormatPct, ns.PctColor, ns.Num = Key, IsSecret, FormatPct, PctColor, Num

---------------------------------------------------------------------------
-- Player identity: role, class, spec, hero talent
---------------------------------------------------------------------------
local function GetHeroTalentName()
  if not (C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec) then return nil end
  local ok, subTreeID = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
  if not ok or not subTreeID then return nil end
  local configID = C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end
  local ok2, info = pcall(C_Traits.GetSubTreeInfo, configID, subTreeID)
  return ok2 and info and info.name or nil
end

local function GetPlayerIdentity()
  local className, _, classID = UnitClass("player")
  local id = { className = className, classID = classID }
  local idx = GetSpecialization and GetSpecialization()
  if idx then
    local specID, specName, _, _, role = GetSpecializationInfo(idx)
    id.specID, id.specName, id.role = specID, specName, ROLE_KEYS[role]
  end
  id.hero = GetHeroTalentName()
  return id
end
ns.GetPlayerIdentity = GetPlayerIdentity

---------------------------------------------------------------------------
-- Percentile maths
-- Each group has anchor points (top 0.1/1/5/10/25/40%). Between two anchors
-- we interpolate on a log scale of the percentage, which follows the shape
-- of the ladder far better than a straight line.
---------------------------------------------------------------------------
local function Cohort(region, key)
  local r = KP_DATA and KP_DATA.regions and KP_DATA.regions[region]
  local c = r and r.cohorts and r.cohorts[key]
  if c and c.cutoffs and #c.cutoffs > 0 then return c end
end

local function EstimatePct(score, cutoffs)
  local c = cutoffs -- best first (smallest pct)
  if score >= c[1].score then return c[1].pct, true end
  for i = 1, #c - 1 do
    local hi, lo = c[i], c[i + 1]
    if score >= lo.score then
      if hi.score == lo.score then return lo.pct end
      local t = (score - lo.score) / (hi.score - lo.score)
      return math.exp(math.log(lo.pct) + t * (math.log(hi.pct) - math.log(lo.pct)))
    end
  end
  local last = c[#c]
  if score <= 0 or last.score <= 0 then return 100 end
  return last.pct + (100 - last.pct) * (1 - score / last.score)
end

local function NextGoal(score, cutoffs)
  for i = #cutoffs, 1, -1 do
    if score < cutoffs[i].score then
      return cutoffs[i].pct, math.ceil(cutoffs[i].score - score)
    end
  end
end

-- Result for one group: { pct, rank, pop, exact, capped, goalPct, need }
local function Evaluate(region, cohortKey, rankKey, score, char)
  local co = Cohort(region, cohortKey)
  if not co then return nil end
  local res = { pop = co.pop }

  local rank = char and char.ranks and char.ranks[rankKey]
  if rank and co.pop and co.pop > 0 then
    res.rank, res.exact = rank, true
    res.pct = math.max(rank / co.pop * 100, 0.001)
  else
    res.pct, res.capped = EstimatePct(score, co.cutoffs)
    if co.pop and co.pop > 0 then res.rank = math.max(1, math.ceil(res.pct / 100 * co.pop)) end
  end
  res.goalPct, res.need = NextGoal(score, co.cutoffs)
  return res
end

-- Stored Raider.IO ranks only count while your live score still matches them.
local function ExactChar(name, realm, score)
  local chars = (KP_PERSONAL and KP_PERSONAL.characters) or (KP_DATA and KP_DATA.characters)
  local c = chars and chars[Key(name, realm)]
  if c and c.score and math.abs(c.score - score) < 1 then return c end
end

ns.EvaluateCohort, ns.ExactChar, ns.GetRegion, ns.GetScore = Evaluate, ExactChar, GetRegion, GetScore

-- Rows shown for the player: { label, result } (result may be nil)
local function BuildRows(score)
  local region = GetRegion()
  local id = GetPlayerIdentity()
  local char = ExactChar(UnitName("player"), GetRealmName(), score)
  local rows = {}

  rows[#rows + 1] = { L["Overall"], Evaluate(region, "overall", "overall", score, char) }
  if id.role then
    rows[#rows + 1] = { ROLE_NAMES[id.role], Evaluate(region, id.role, id.role, score, char) }
  end
  if id.classID then
    rows[#rows + 1] = { id.className, Evaluate(region, "class:" .. id.classID, "class", score, char) }
  end
  if id.specID then
    rows[#rows + 1] = { id.specName, Evaluate(region, "spec:" .. id.specID, "spec_" .. id.specID, score, char) }
  end
  if id.hero then
    rows[#rows + 1] = { id.hero, nil, L["no ranking data"] }
  end
  return rows, region
end

local function PctText(res)
  if not res then return "|cff777777—|r" end
  local s = string.format(L["Top %s"], FormatPct(res.pct) .. (res.capped and "+" or ""))
  return string.format("|c%s%s|r", PctColor(res.pct), s)
end

local function RankText(res, fallback)
  if not res then return "|cff777777" .. (fallback or L["no data"]) .. "|r" end
  if not res.rank or not res.pop then return "" end
  if res.exact then
    return string.format("|cff00ff96#%s|r |cff999999/ %s|r", Num(res.rank), Num(res.pop))
  elseif res.capped then
    return string.format("|cff999999%s %s / %s|r", L["top"], Num(res.rank), Num(res.pop))
  end
  return string.format("|cff999999~#%s / %s|r", Num(res.rank), Num(res.pop))
end

---------------------------------------------------------------------------
-- On-screen panel
---------------------------------------------------------------------------
local panel = CreateFrame("Frame", "KeystonePercentilePanel", UIParent, "BackdropTemplate")
panel:SetSize(240, 100)
panel:SetFrameStrata("MEDIUM")
panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
panel:SetBackdropColor(0, 0, 0, 0.6)
panel:SetBackdropBorderColor(0, 0, 0, 0.9)
panel:SetMovable(true)
panel:SetClampedToScreen(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:Hide()

panel.header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
panel.header:SetPoint("TOPLEFT", 10, -8)
panel.footer = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
panel.footer:SetJustifyH("LEFT")

local ROW_H, PAD = 16, 10
local rowFS = {}
local function RowStrings(i)
  if not rowFS[i] then
    local a = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local b = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local c = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    a:SetJustifyH("LEFT"); b:SetJustifyH("LEFT"); c:SetJustifyH("LEFT")
    rowFS[i] = { a, b, c }
  end
  return rowFS[i]
end

panel:SetScript("OnDragStart", function(self)
  self.dragged = true
  if not KP_DB.locked then self:StartMoving() end
end)
panel:SetScript("OnMouseDown", function(self) self.dragged = false end)
panel:SetScript("OnMouseUp", function(self, button)
  if button == "LeftButton" and not self.dragged and ns.ToggleHistory then ns.ToggleHistory() end
end)
panel:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local p, _, rp, x, y = self:GetPoint()
  KP_DB.pos = { p, rp, x, y }
end)

local lastRows
panel:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:AddLine("Keystone Percentile: " .. (GetRegion() or "?"):upper())
  if KP_DATA.season then GameTooltip:AddLine(KP_DATA.season, 0.7, 0.7, 0.7) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(L["Next goal per group"], 1, 0.82, 0)
  for _, row in ipairs(lastRows or {}) do
    local res = row[2]
    if res and res.goalPct then
      GameTooltip:AddDoubleLine(row[1], string.format(L["+%d to Top %s"], res.need, FormatPct(res.goalPct)),
        1, 1, 1, 1, 0.82, 0)
    elseif res then
      GameTooltip:AddDoubleLine(row[1], L["above every cutoff"], 1, 1, 1, 0, 1, 0.6)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(L["|cff00ff96#rank|r = exact from Raider.IO, ~#rank = estimate"], 0.6, 0.6, 0.6, true)
  GameTooltip:AddLine(L["Data:"] .. " " .. (KP_DATA.updatedAt or L["never"]), 0.6, 0.6, 0.6)
  GameTooltip:AddLine(L["Click for run history. Drag to move."], 0.6, 0.6, 0.6)
  GameTooltip:Show()
end)
panel:SetScript("OnLeave", GameTooltip_Hide)

local function RefreshPanel()
  if not KP_DB or KP_DB.hidden then panel:Hide() return end
  local score = GetScore("player")
  if not score then return end
  local rows, region = BuildRows(score)
  lastRows = rows

  panel.header:SetText(string.format("|c%s%s|r  |cff999999%s, %s|r",
    ScoreColor(score), Num(score), L["M+ rating"], (region or "?"):upper()))

  -- Fill the three columns, then measure them to line everything up.
  local w1, w2, w3 = 0, 0, 0
  for i, row in ipairs(rows) do
    local fs = RowStrings(i)
    fs[1]:SetText(row[1]); fs[2]:SetText(PctText(row[2])); fs[3]:SetText(RankText(row[2], row[3]))
    w1 = math.max(w1, fs[1]:GetStringWidth())
    w2 = math.max(w2, fs[2]:GetStringWidth())
    w3 = math.max(w3, fs[3]:GetStringWidth())
    for c = 1, 3 do fs[c]:Show() end
  end
  for i = #rows + 1, #rowFS do for c = 1, 3 do rowFS[i][c]:Hide() end end

  local top = -8 - panel.header:GetStringHeight() - 6
  for i = 1, #rows do
    local fs, y = rowFS[i], top - (i - 1) * ROW_H
    fs[1]:ClearAllPoints(); fs[1]:SetPoint("TOPLEFT", PAD, y)
    fs[2]:ClearAllPoints(); fs[2]:SetPoint("TOPLEFT", PAD + w1 + 12, y)
    fs[3]:ClearAllPoints(); fs[3]:SetPoint("TOPLEFT", PAD + w1 + 12 + w2 + 12, y - 1)
  end

  local footer
  if not rows[1][2] then
    footer = "|cffff5555" .. string.format(L["No ladder data for %s yet."], (region or "?"):upper()) .. "|r"
  elseif (KP_DATA.updatedEpoch or 0) > 0 and GetServerTime() - KP_DATA.updatedEpoch > STALE_SECONDS then
    footer = "|cffff5555" .. L["Data is over 7 days old."] .. "|r"
  end
  local height = 8 + panel.header:GetStringHeight() + 6 + #rows * ROW_H
  if footer then
    panel.footer:SetText(footer)
    panel.footer:ClearAllPoints(); panel.footer:SetPoint("TOPLEFT", PAD, -height - 2)
    panel.footer:Show()
    height = height + panel.footer:GetStringHeight() + 4
  else
    panel.footer:Hide()
  end

  local width = math.max(PAD + w1 + 12 + w2 + 12 + w3 + PAD, panel.header:GetStringWidth() + 2 * PAD,
    footer and (panel.footer:GetStringWidth() + 2 * PAD) or 0)
  panel:SetSize(width, height + 8)
  panel:Show()
end

ns.RefreshPanel = RefreshPanel

---------------------------------------------------------------------------
-- Unit tooltips: overall and class percentile for other players
-- (works when the client knows their rating, e.g. group members)
---------------------------------------------------------------------------
local function OnUnitTooltip(tooltip)
  if tooltip ~= GameTooltip or not KP_DB.tooltips or InCombatLockdown() then return end
  local _, unit = tooltip:GetUnit()
  if not unit or IsSecret(unit) or not UnitIsPlayer(unit) then return end
  local score = GetScore(unit)
  if not score or score <= 0 then return end
  local region = GetRegion()
  local name, realm = UnitName(unit)
  local char = ExactChar(name, realm or GetRealmName(), score)
  local overall = Evaluate(region, "overall", "overall", score, char)
  if not overall then return end
  local text = "M+ " .. PctText(overall)
  local className, _, classID = UnitClass(unit)
  local cls = classID and Evaluate(region, "class:" .. classID, "class", score, char)
  if cls then text = text .. "  ·  " .. className .. " " .. PctText(cls) end
  tooltip:AddLine(text)
end

---------------------------------------------------------------------------
-- Events & slash command
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
ev:RegisterEvent("CHALLENGE_MODE_COMPLETED")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:RegisterEvent("TRAIT_CONFIG_UPDATED")

ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    KP_DB = KP_DB or {}
    if KP_DB.tooltips == nil then KP_DB.tooltips = true end
    local pos = KP_DB.pos
    panel:ClearAllPoints()
    if pos then panel:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else panel:SetPoint("TOP", UIParent, "TOP", 0, -120) end
    if TooltipDataProcessor and Enum.TooltipDataType then
      TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
    end
  elseif event == "PLAYER_ENTERING_WORLD" or event == "CHALLENGE_MODE_COMPLETED" then
    if C_MythicPlus and C_MythicPlus.RequestMapInfo then C_MythicPlus.RequestMapInfo() end
    C_Timer.After(2, RefreshPanel)
  elseif event == "PLAYER_SPECIALIZATION_CHANGED" and arg1 ~= "player" then
    return
  else
    C_Timer.After(0.2, RefreshPanel)
  end
end)

SLASH_KEYSTONEPERCENTILE1 = "/kp"
SLASH_KEYSTONEPERCENTILE2 = "/keystone"
SlashCmdList.KEYSTONEPERCENTILE = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  local cmd, arg = msg:match("^(%S*)%s*(.*)$")
  local tag = "|cff00ff96Keystone Percentile|r: "
  if cmd == "hide" or cmd == "show" then
    KP_DB.hidden = (cmd == "hide")
    RefreshPanel()
  elseif cmd == "lock" then
    KP_DB.locked = not KP_DB.locked
    print(tag .. "panel " .. (KP_DB.locked and "locked" or "unlocked"))
  elseif cmd == "reset" then
    KP_DB.pos = nil
    panel:ClearAllPoints(); panel:SetPoint("TOP", UIParent, "TOP", 0, -120)
  elseif cmd == "tooltips" then
    KP_DB.tooltips = not KP_DB.tooltips
    print(tag .. "tooltips " .. (KP_DB.tooltips and "on" or "off"))
  elseif cmd == "config" or cmd == "options" or cmd == "settings" then
    ns.OpenSettings()
  elseif cmd == "progress" then
    ns.ToggleHistory("progress")
  elseif cmd == "next" then
    ns.ToggleHistory("next")
  elseif cmd == "runs" or cmd == "history" then
    ns.ToggleHistory()
  elseif cmd == "last" then
    ns.ShowLastRun()
  elseif cmd == "popup" then
    KP_DB.popup = (KP_DB.popup == false)
    print(tag .. "end-of-key pop-up " .. (KP_DB.popup and "on" or "off"))
  elseif cmd == "region" then
    KP_DB.region = (arg ~= "" and arg ~= "auto") and arg or nil
    print(tag .. "region = " .. (GetRegion() or "?"))
    RefreshPanel()
  else
    local score = GetScore("player") or 0
    local rows = BuildRows(score)
    print(tag .. string.format("|c%s%s|r", ScoreColor(score), Num(score)))
    for _, row in ipairs(rows) do
      print(string.format("  %s: %s  %s", row[1], PctText(row[2]), RankText(row[2], row[3])))
    end
    print("|cff888888/kp runs, progress, next, last, config|r")
  end
end
