-- Keystone Percentile: goals ("how much rating and how many keys to Top X%"),
-- the Overview and Goals tabs, and the panel docked to Blizzard's Mythic+ window.
local ADDON, ns = ...
local L = ns.L

-- Brackets a player climbs through. The "next step" is the first one above you.
local LADDER = { 40, 30, 25, 20, 15, 10, 5, 2, 1, 0.5, 0.1 }
local MAX_STEPS = 80

---------------------------------------------------------------------------
-- Route planning
---------------------------------------------------------------------------
local function Summary()
  local ok, s = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, "player")
  if ok and s and not ns.IsSecret(s) then return s end
end

-- Dungeon score per key level, fitted from your own timed dungeons.
local function FitScores(runs)
  local xs, ys = {}, {}
  for _, r in ipairs(runs) do
    if r.finishedSuccess and (r.bestRunLevel or 0) > 0 and (r.mapScore or 0) > 0 then
      xs[#xs + 1], ys[#ys + 1] = r.bestRunLevel, r.mapScore
    end
  end
  local n = #xs
  local slope, intercept = 15, nil
  if n >= 2 then
    local mx, my = 0, 0
    for i = 1, n do mx, my = mx + xs[i], my + ys[i] end
    mx, my = mx / n, my / n
    local sxy, sxx = 0, 0
    for i = 1, n do sxy, sxx = sxy + (xs[i] - mx) * (ys[i] - my), sxx + (xs[i] - mx) ^ 2 end
    if sxx > 0 then slope = math.max(6, math.min(30, sxy / sxx)) end
    intercept = my - slope * mx
  elseif n == 1 then
    intercept = ys[1] - slope * xs[1]
  end
  return slope, intercept, n
end

-- Keys to time, easiest first, until `needed` rating is covered.
-- Each step: { map, level, gain, total }
function ns.PlanRoute(needed)
  local s = Summary()
  local maps = C_ChallengeMode and C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapTable()
  if not s or not maps or #maps == 0 then return nil end
  local runs = s.runs or {}
  local slope, intercept, fitted = FitScores(runs)
  local byMap, lowestTimed = {}, nil
  for _, r in ipairs(runs) do
    if r.challengeModeID then byMap[r.challengeModeID] = r end
    if r.finishedSuccess and r.bestRunLevel and (not lowestTimed or r.bestRunLevel < lowestTimed) then
      lowestTimed = r.bestRunLevel
    end
  end
  local state = {}
  for _, map in ipairs(maps) do
    local r = byMap[map]
    state[#state + 1] = { map = map, level = r and r.bestRunLevel or 0, timed = r and r.finishedSuccess,
      score = r and r.mapScore or 0 }
  end

  local function Next(st)
    local target
    if st.level > 0 then target = st.timed and st.level + 1 or st.level
    else target = lowestTimed or 2 end
    local predicted = intercept and (intercept + slope * target) or (st.score + slope)
    local gain = predicted - st.score
    if gain < slope * 0.5 then gain = slope * 0.5 end
    return target, gain
  end

  local steps, total = {}, 0
  while total < needed and #steps < MAX_STEPS do
    local best, bt, bg
    for _, st in ipairs(state) do
      local t, g = Next(st)
      if not best or t < bt or (t == bt and g > bg) then best, bt, bg = st, t, g end
    end
    if not best then break end
    total = total + bg
    steps[#steps + 1] = { map = best.map, level = bt, gain = math.floor(bg + 0.5), total = total }
    best.level, best.timed, best.score = bt, true, best.score + bg
  end
  return steps, slope, fitted, byMap
end

---------------------------------------------------------------------------
-- Goals for a group (overall or your spec)
---------------------------------------------------------------------------
-- Returns { score, pct, label, goals = { {pct, cutoff, need, keys, progress, isNext, isTitle} },
--           steps, slope, fitted } or nil.
function ns.Goals(cohortKey)
  local score = ns.GetScore("player")
  local co = score and ns.Cohort(ns.GetRegion(), cohortKey or "overall")
  if not co then return nil end
  local pct = ns.EstimatePct(score, co.cutoffs)

  local wanted, basePct = {}, nil
  for _, p in ipairs(LADDER) do
    if p >= pct then basePct = p end
  end
  for _, p in ipairs(LADDER) do
    if p < pct - 1e-9 then
      if p ~= 1 and p ~= 0.1 then wanted[#wanted + 1] = { pct = p, isNext = true } end
      break
    end
  end
  wanted[#wanted + 1] = { pct = 1 }
  wanted[#wanted + 1] = { pct = 0.1, isTitle = true }

  local baseScore = basePct and ns.CutoffScore(co.cutoffs, basePct) or 0
  local goals, maxNeed = {}, 0
  for _, g in ipairs(wanted) do
    local cutoff = ns.CutoffScore(co.cutoffs, g.pct)
    if cutoff then
      g.cutoff = cutoff
      g.need = math.max(0, math.ceil(cutoff - score))
      local span = cutoff - baseScore
      g.progress = g.need == 0 and 1 or (span > 0 and math.max(0, math.min(1, (score - baseScore) / span)) or 0)
      maxNeed = math.max(maxNeed, g.need)
      goals[#goals + 1] = g
    end
  end

  local steps, slope, fitted, best = ns.PlanRoute(maxNeed)
  for _, g in ipairs(goals) do
    if g.need > 0 and steps then
      for i, st in ipairs(steps) do
        if st.total >= g.need then g.keys = i break end
      end
      g.keysOver = not g.keys
    end
  end
  return { score = score, pct = pct, goals = goals, steps = steps or {}, slope = slope, fitted = fitted or 0,
           best = best or {} }
end

-- Bracket names: "Top 2%", "Top 0.1%" (no trailing ".0").
local function Bracket(p)
  local s = (p == math.floor(p)) and string.format("%d", p) or string.format("%g", p)
  return string.format(L["Top %s"], s .. "%")
end
ns.BracketText = Bracket

local function GoalLabel(g)
  return string.format("|c%s%s|r", ns.PctColor(g.pct), Bracket(g.pct))
end

local function NeedText(g)
  if g.need == 0 then return "|cff1eff00" .. L["reached"] .. "|r" end
  local keys
  if g.keys then keys = string.format(L["~%d keys"], g.keys)
  elseif g.keysOver then keys = string.format(L["%d+ keys"], MAX_STEPS)
  end
  local s = string.format(L["+%s rating"], ns.Num(g.need))
  if keys then s = s .. " · |cffffd100" .. keys .. "|r" end
  return "|cffffffff" .. s .. "|r"
end
ns.GoalNeedText, ns.GoalLabelText = NeedText, GoalLabel

-- One line for small places (floating panel, end-of-key pop-up).
function ns.GoalLine()
  local data = ns.Goals("overall")
  if not data then return nil end
  for _, g in ipairs(data.goals) do
    if g.need > 0 then return GoalLabel(g) .. ": " .. NeedText(g) end
  end
  return "|cffff8000" .. Bracket(0.1) .. "|r: |cff1eff00" .. L["reached"] .. "|r"
end

---------------------------------------------------------------------------
-- Goal list widget, used by the Overview and Goals tabs
---------------------------------------------------------------------------
local function SlopeNote(data)
  if not data then return "" end
  if data.fitted >= 2 then
    return string.format(L["About %d rating per key at your level, from your own dungeon scores. Easiest keys first."],
      math.floor(data.slope + 0.5))
  end
  return L["Assumes about 15 rating per key until you've timed more dungeons. Easiest keys first."]
end

local function MapName(map)
  return (C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(map)) or ("#" .. map)
end

-- Steps of a goal grouped by dungeon, in the order they come up (easiest first).
-- Each: { map, from, fromTimed, to, keys, gain }
local function PlanByDungeon(data, g)
  local rows, index = {}, {}
  for k = 1, (g.keys or 0) do
    local st = data.steps[k]
    local r = index[st.map]
    if not r then
      local b = data.best[st.map]
      r = { map = st.map, from = b and b.bestRunLevel or 0, fromTimed = b and b.finishedSuccess, to = st.level,
            keys = 0, gain = 0 }
      index[st.map] = r
      rows[#rows + 1] = r
    end
    r.to, r.keys, r.gain = st.level, r.keys + 1, r.gain + st.gain
  end
  return rows
end

---------------------------------------------------------------------------
-- Overview tab: ranks plus a short goal summary (click a goal for the plan)
---------------------------------------------------------------------------
local overview = ns.NewHistoryView("overview", L["Overview"], function() ns.RefreshOverview() end, 10)
overview.header = overview:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
overview.header:SetPoint("TOPLEFT", 14, -6)
overview.rows, overview.goalRows = {}, {}
overview.goalsTitle = overview:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
overview.goalsTitle:SetText(L["Goals"])
overview.note = overview:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
overview.note:SetPoint("BOTTOMLEFT", 12, 10)
overview.note:SetWidth(610); overview.note:SetJustifyH("LEFT")
overview.empty = overview:CreateFontString(nil, "OVERLAY", "GameFontDisable")
overview.empty:SetPoint("TOP", 0, -60)

local function GoalRow(i)
  if overview.goalRows[i] then return overview.goalRows[i] end
  local r = CreateFrame("Button", nil, overview)
  r:SetSize(610, 34)
  r.hl = r:CreateTexture(nil, "BACKGROUND")
  r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.05); r.hl:Hide()
  r.label = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.label:SetPoint("TOPLEFT", 4, -2)
  r.note = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.note:SetPoint("BOTTOMLEFT", r.label, "BOTTOMRIGHT", 6, 1)
  r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  r.value:SetPoint("TOPRIGHT", -4, -2)
  r.barBG = r:CreateTexture(nil, "ARTWORK")
  r.barBG:SetColorTexture(0.17, 0.19, 0.23, 1)
  r.barBG:SetPoint("TOPLEFT", 4, -22); r.barBG:SetSize(602, 6)
  r.bar = r:CreateTexture(nil, "ARTWORK", nil, 1)
  r.bar:SetPoint("TOPLEFT", r.barBG, "TOPLEFT")
  r:SetScript("OnEnter", function(self) self.hl:Show() end)
  r:SetScript("OnLeave", function(self) self.hl:Hide() end)
  r:SetScript("OnClick", function(self) ns.OpenGoal(self.pct) end)
  overview.goalRows[i] = r
  return r
end

function ns.RefreshOverview()
  local score = ns.GetScore("player")
  if not score then
    overview.empty:SetText(L["Your Mythic+ rating isn't available yet. Try again in a moment."])
    overview.empty:Show()
    return
  end
  overview.empty:Hide()
  local rows, region = ns.BuildRows(score)
  overview.header:SetText(string.format("|c%s%s|r  |cff999999%s, %s|r", ns.ScoreColor(score), ns.Num(score),
    L["M+ rating"], (region or "?"):upper()))
  local y = -34
  for i, row in ipairs(rows) do
    local r = overview.rows[i]
    if not r then
      r = { overview:CreateFontString(nil, "OVERLAY", "GameFontNormal"),
            overview:CreateFontString(nil, "OVERLAY", "GameFontHighlight"),
            overview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
      overview.rows[i] = r
    end
    r[1]:SetText(row[1]); r[2]:SetText(ns.PctText(row[2])); r[3]:SetText(ns.RankText(row[2], row[3]))
    r[1]:ClearAllPoints(); r[1]:SetPoint("TOPLEFT", 14, y)
    r[2]:ClearAllPoints(); r[2]:SetPoint("TOPLEFT", 150, y)
    r[3]:ClearAllPoints(); r[3]:SetPoint("TOPLEFT", 250, y - 1)
    for c = 1, 3 do r[c]:Show() end
    y = y - 18
  end
  for i = #rows + 1, #overview.rows do for c = 1, 3 do overview.rows[i][c]:Hide() end end

  y = y - 10
  overview.goalsTitle:ClearAllPoints(); overview.goalsTitle:SetPoint("TOPLEFT", 14, y)
  y = y - 26
  local data = ns.Goals("overall")
  local goals = data and data.goals or {}
  for i, g in ipairs(goals) do
    local r = GoalRow(i)
    r.pct = g.pct
    r.label:SetText(GoalLabel(g))
    r.note:SetText(g.isNext and L["next step"] or (g.isTitle and L["season title"] or ""))
    r.value:SetText(NeedText(g))
    r.bar:SetSize(math.max(1, 602 * (g.progress or 0)), 6)
    r.bar:SetColorTexture(ns.HexToRGB(ns.PctColor(g.pct)))
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", 10, y); r:Show()
    y = y - 40
  end
  for i = #goals + 1, #overview.goalRows do overview.goalRows[i]:Hide() end
  overview.note:SetText(#goals > 0 and L["Click a goal to see which keys to run."] or "")
end

---------------------------------------------------------------------------
-- Goals tab: a plan for one goal, one row per dungeon
---------------------------------------------------------------------------
local goalsView = ns.NewHistoryView("goals", L["Goals"], function() ns.RefreshGoalsTab() end, 40)
local useSpec, selectedPct = false, nil
goalsView.chips = {}
goalsView.toggle = CreateFrame("Button", nil, goalsView, "UIPanelButtonTemplate")
goalsView.toggle:SetSize(150, 22)
goalsView.toggle:SetPoint("TOPRIGHT", -16, -4)
goalsView.toggle:SetScript("OnClick", function() useSpec = not useSpec; ns.RefreshGoalsTab() end)
goalsView.headline = goalsView:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
goalsView.headline:SetPoint("TOPLEFT", 14, -40)
goalsView.keys = goalsView:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
goalsView.keys:SetPoint("TOPRIGHT", -16, -40)
goalsView.barBG = goalsView:CreateTexture(nil, "ARTWORK")
goalsView.barBG:SetColorTexture(0.17, 0.19, 0.23, 1)
goalsView.barBG:SetPoint("TOPLEFT", 14, -68); goalsView.barBG:SetSize(626, 7)
goalsView.bar = goalsView:CreateTexture(nil, "ARTWORK", nil, 1)
goalsView.bar:SetPoint("TOPLEFT", goalsView.barBG, "TOPLEFT")
goalsView.from = goalsView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
goalsView.from:SetPoint("TOPLEFT", goalsView.barBG, "BOTTOMLEFT", 0, -3)
goalsView.to = goalsView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
goalsView.to:SetPoint("TOPRIGHT", goalsView.barBG, "BOTTOMRIGHT", 0, -3)
goalsView.marks = {}
goalsView.note = goalsView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
goalsView.note:SetPoint("BOTTOMLEFT", 12, 10)
goalsView.note:SetWidth(610); goalsView.note:SetJustifyH("LEFT")
goalsView.empty = goalsView:CreateFontString(nil, "OVERLAY", "GameFontDisable")
goalsView.empty:SetPoint("TOP", 0, -130)

local PCOLS = { { 14, 250, "LEFT" }, { 270, 80, "LEFT" }, { 355, 90, "LEFT" }, { 450, 70, "RIGHT" }, { 530, 100, "RIGHT" } }
goalsView.head = {}
for i, h in ipairs({ L["Dungeon"], L["Best now"], L["Run up to"], L["Keys"], L["Rating"] }) do
  local fs = goalsView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  fs:SetPoint("TOPLEFT", PCOLS[i][1], -100); fs:SetWidth(PCOLS[i][2]); fs:SetJustifyH(PCOLS[i][3])
  fs:SetText(h)
  goalsView.head[i] = fs
end
goalsView.rows = {}

local function Chip(i)
  if goalsView.chips[i] then return goalsView.chips[i] end
  local b = CreateFrame("Button", nil, goalsView, "BackdropTemplate")
  b:SetSize(96, 20)
  b:SetPoint("TOPLEFT", 14 + (i - 1) * 102, -6)
  b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("CENTER")
  b:SetScript("OnClick", function(self) selectedPct = self.pct; ns.RefreshGoalsTab() end)
  goalsView.chips[i] = b
  return b
end

local function PlanRow(i)
  if goalsView.rows[i] then return goalsView.rows[i] end
  local r = {}
  for c = 1, #PCOLS do
    local fs = goalsView:CreateFontString(nil, "OVERLAY", c == 1 and "GameFontHighlight" or "GameFontHighlightSmall")
    fs:SetWidth(PCOLS[c][2]); fs:SetJustifyH(PCOLS[c][3]); fs:SetWordWrap(false)
    r[c] = fs
  end
  goalsView.rows[i] = r
  return r
end

function ns.OpenGoal(pct)
  selectedPct = pct
  ns.ToggleHistory("goals")
  if KP_DB.historyTab ~= "goals" then ns.ShowHistoryTab("goals") end
end

function ns.RefreshGoalsTab()
  local id = ns.GetPlayerIdentity()
  local specKey = id.specID and ("spec:" .. id.specID)
  if not specKey then useSpec = false end
  local data = ns.Goals(useSpec and specKey or "overall")
  goalsView.toggle:SetText(useSpec and L["Show overall"] or (id.specName and string.format(L["Show %s"], id.specName) or L["Overall"]))
  goalsView.toggle:SetShown(specKey ~= nil)

  for _, c in pairs(goalsView.chips) do c:Hide() end
  for _, r in pairs(goalsView.rows) do for c = 1, #PCOLS do r[c]:Hide() end end
  for _, m in pairs(goalsView.marks) do m.tex:Hide(); m.label:Hide() end
  if not data or #data.goals == 0 then
    goalsView.headline:SetText(""); goalsView.keys:SetText(""); goalsView.note:SetText("")
    goalsView.bar:Hide(); goalsView.barBG:Hide(); goalsView.from:SetText(""); goalsView.to:SetText("")
    goalsView.empty:SetText(L["Your Mythic+ rating isn't available yet. Try again in a moment."]); goalsView.empty:Show()
    return
  end
  goalsView.empty:Hide()

  -- Goal chips; keep the chosen goal, else the first one not reached yet
  local g
  for _, x in ipairs(data.goals) do if x.pct == selectedPct then g = x end end
  if not g then
    for _, x in ipairs(data.goals) do if x.need > 0 then g = x break end end
    g = g or data.goals[#data.goals]
  end
  selectedPct = g.pct
  for i, x in ipairs(data.goals) do
    local c = Chip(i)
    c.pct = x.pct
    c.text:SetText(ns.BracketText(x.pct))
    local on = x.pct == g.pct
    c:SetBackdropColor(on and 0.16 or 0.08, on and 0.10 or 0.08, on and 0.03 or 0.1, 1)
    c:SetBackdropBorderColor(ns.HexToRGB(on and ns.PctColor(x.pct) or "ff4d4d52"))
    c:Show()
  end

  local who = useSpec and (id.specName or "") or L["overall"]
  if g.need == 0 then
    goalsView.headline:SetText(string.format("|cff1eff00%s|r %s", L["Reached:"], GoalLabel(g) .. " " .. who))
    goalsView.keys:SetText("")
  else
    goalsView.headline:SetText(string.format(L["+%s rating to %s %s"], ns.Num(g.need), GoalLabel(g), who))
    goalsView.keys:SetText(g.keys and string.format(L["~%d keys"], g.keys) or string.format(L["%d+ keys"], MAX_STEPS))
  end

  -- Bar from your rating to the goal, with other goals marked on the way
  goalsView.barBG:Show(); goalsView.bar:Show()
  local lo, hi = data.score, math.max(g.cutoff, data.score + 1)
  goalsView.bar:SetSize(g.need == 0 and 626 or 1, 7)
  goalsView.bar:SetColorTexture(ns.HexToRGB(ns.PctColor(g.pct)))
  goalsView.from:SetText(ns.Num(data.score)); goalsView.to:SetText(ns.Num(math.ceil(g.cutoff)))
  local mi = 0
  for _, x in ipairs(data.goals) do
    if x ~= g and x.cutoff > lo and x.cutoff < hi then
      mi = mi + 1
      local m = goalsView.marks[mi]
      if not m then
        m = { tex = goalsView:CreateTexture(nil, "OVERLAY"), label = goalsView:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
        m.tex:SetSize(1, 15)
        goalsView.marks[mi] = m
      end
      local xpos = (x.cutoff - lo) / (hi - lo) * 626
      m.tex:SetColorTexture(ns.HexToRGB(ns.PctColor(x.pct)))
      m.tex:ClearAllPoints(); m.tex:SetPoint("TOP", goalsView.barBG, "TOPLEFT", xpos, 4); m.tex:Show()
      m.label:SetText(GoalLabel(x)); m.label:ClearAllPoints(); m.label:SetPoint("TOP", goalsView.barBG, "BOTTOMLEFT", xpos, -3)
      m.label:Show()
    end
  end

  -- One row per dungeon
  local plan = g.need > 0 and PlanByDungeon(data, g) or {}
  for i, p in ipairs(plan) do
    local r = PlanRow(i)
    local y = -118 - (i - 1) * 20
    for c = 1, #PCOLS do r[c]:ClearAllPoints(); r[c]:SetPoint("TOPLEFT", goalsView, "TOPLEFT", PCOLS[c][1], y); r[c]:Show() end
    r[1]:SetText(MapName(p.map))
    r[2]:SetText(p.from > 0 and string.format("%s+%d|r", p.fromTimed and "|cff999999" or "|cffff5555", p.from) or ("|cff777777" .. L["not run"] .. "|r"))
    r[3]:SetText(string.format("|cffffd100+%d|r", p.to))
    r[4]:SetText(tostring(p.keys))
    r[5]:SetText(string.format("|cff1eff00+%d|r", p.gain))
  end
  for c = 1, #PCOLS do goalsView.head[c]:SetShown(#plan > 0) end
  goalsView.note:SetText(#plan > 0 and (L["One row per dungeon: how high to time it. Any order works; lowest keys first is easiest."] .. " " .. SlopeNote(data)) or "")
end

---------------------------------------------------------------------------
-- Panel attached to the right of Blizzard's Mythic+ window
---------------------------------------------------------------------------
local dock, PlaceDock

local function BuildDock()
  if dock or not ChallengesFrame then return end
  dock = CreateFrame("Button", "KeystonePercentileDock", ChallengesFrame, "BackdropTemplate")
  dock:SetWidth(215)
  dock:SetFrameLevel((ChallengesFrame:GetFrameLevel() or 1) + 20)
  dock:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  dock:SetBackdropColor(0.05, 0.05, 0.06, 0.95)
  dock:SetBackdropBorderColor(0, 0, 0, 1)
  dock.icon = dock:CreateTexture(nil, "ARTWORK")
  dock.icon:SetSize(16, 16)
  dock.icon:SetPoint("TOPLEFT", 8, -7)
  dock.icon:SetTexture("Interface\\AddOns\\Keystone_Percentile\\Media\\Icon")
  dock.title = dock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  dock.title:SetPoint("TOPLEFT", 28, -8)
  dock.title:SetText("Keystone Percentile")
  dock.rows, dock.goals = {}, {}
  dock.hint = dock:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  dock:SetScript("OnClick", function() ns.ToggleHistory("overview") end)
  dock:SetClampedToScreen(true)
  ChallengesFrame:HookScript("OnShow", function()
    ns.RefreshDock()
    -- Raider.IO shows its profile a moment after the window opens
    C_Timer.After(0.1, function() if dock:IsShown() then PlaceDock() end end)
    C_Timer.After(0.5, function() if dock:IsShown() then PlaceDock() end end)
  end)
end

-- Under Raider.IO's profile ("Best runs by dungeon") when it's showing next to
-- the Mythic+ window, using the same width; otherwise straight to the right of
-- the window. Nothing of ours sits on top of Blizzard's window.
local hookedRIO
local function RaiderIOPanel()
  local tip = _G.RaiderIO_ProfileTooltip
  if not (tip and tip.IsShown and tip:IsShown()) then return nil, tip end
  local pve = PVEFrame or ChallengesFrame
  local tl, pr = tip:GetLeft(), pve and pve:GetRight()
  -- Only when it's attached to the Mythic+ window, not moved somewhere else
  if tl and pr and math.abs(tl - pr) > 60 then return nil, tip end
  return tip, tip
end

function PlaceDock()
  dock:ClearAllPoints()
  local rio, tip = RaiderIOPanel()
  if tip and not hookedRIO then
    hookedRIO = true
    tip:HookScript("OnShow", function() C_Timer.After(0, function() if dock and dock:IsShown() then PlaceDock() end end) end)
    tip:HookScript("OnHide", function() if dock and dock:IsShown() then PlaceDock() end end)
    tip:HookScript("OnSizeChanged", function() if dock and dock:IsShown() and RaiderIOPanel() then dock:SetWidth(math.max(215, tip:GetWidth() or 0)) end end)
  end
  if rio then
    dock:SetPoint("TOPLEFT", rio, "BOTTOMLEFT", 0, -2)
    dock:SetWidth(math.max(215, rio:GetWidth() or 0))
  else
    dock:SetPoint("TOPLEFT", PVEFrame or ChallengesFrame, "TOPRIGHT", 2, -2)
    dock:SetWidth(215)
  end
end

function ns.RefreshDock()
  if not dock then return end
  if KP_DB.dock == false then dock:Hide() return end
  PlaceDock()
  local score = ns.GetScore("player")
  if not score then dock:Hide() return end
  local rows = ns.BuildRows(score)
  local y = -28
  local n = 0
  for _, row in ipairs(rows) do
    if row[2] then
      n = n + 1
      local r = dock.rows[n]
      if not r then
        r = { dock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"),
              dock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
        dock.rows[n] = r
      end
      r[1]:SetText(row[1]); r[2]:SetText(ns.PctText(row[2]))
      r[1]:ClearAllPoints(); r[1]:SetPoint("TOPLEFT", 10, y)
      r[2]:ClearAllPoints(); r[2]:SetPoint("TOPLEFT", 110, y)
      r[1]:Show(); r[2]:Show()
      y = y - 15
    end
  end
  for i = n + 1, #dock.rows do dock.rows[i][1]:Hide(); dock.rows[i][2]:Hide() end

  local data = ns.Goals("overall")
  y = y - 8
  local gi = 0
  for _, g in ipairs(data and data.goals or {}) do
    gi = gi + 1
    local l = dock.goals[gi]
    if not l then
      l = { dock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
            dock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
      dock.goals[gi] = l
    end
    l[1]:SetText(GoalLabel(g)); l[2]:SetText(NeedText(g))
    l[1]:ClearAllPoints(); l[1]:SetPoint("TOPLEFT", 10, y)
    l[2]:ClearAllPoints(); l[2]:SetPoint("TOPLEFT", 80, y)
    l[1]:Show(); l[2]:Show()
    y = y - 15
  end
  for i = gi + 1, #dock.goals do dock.goals[i][1]:Hide(); dock.goals[i][2]:Hide() end
  dock.hint:SetText(L["Click for details"])
  dock.hint:ClearAllPoints(); dock.hint:SetPoint("TOPLEFT", 10, y - 6)
  dock:SetHeight(-y + 26)
  dock:Show()
end

-- Refresh everything that shows goals (after a key, spec change, new data).
function ns.RefreshAll()
  if ns.RefreshPanel then ns.RefreshPanel() end
  if ns.HistoryWindow and ns.HistoryWindow:IsShown() then ns.ShowHistoryTab(KP_DB.historyTab or "overview") end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, name)
  if name == "Blizzard_ChallengesUI" then
    BuildDock()
    self:UnregisterEvent("ADDON_LOADED")
  end
end)
if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_ChallengesUI") then BuildDock() end
