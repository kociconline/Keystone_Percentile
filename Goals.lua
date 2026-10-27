-- Keystone Percentile: goals ("how much rating and how many keys to Top X%"),
-- the Overview and Goals tabs, and the panel docked to Blizzard's Mythic+ window.
local ADDON, ns = ...
local L = ns.L

-- Brackets a player climbs through. The "next step" is the first one above you.
local LADDER = { 40, 30, 25, 20, 15, 10, 5, 2, 1, 0.5, 0.1 }
local MAX_STEPS = 80
local PLUS = "|TInterface\\Buttons\\UI-PlusButton-Up:14:14|t"
local MINUS = "|TInterface\\Buttons\\UI-MinusButton-Up:14:14|t"

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
  return steps, slope, fitted
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

  local steps, slope, fitted = ns.PlanRoute(maxNeed)
  for _, g in ipairs(goals) do
    if g.need > 0 and steps then
      for i, st in ipairs(steps) do
        if st.total >= g.need then g.keys = i break end
      end
      g.keysOver = not g.keys
    end
  end
  return { score = score, pct = pct, goals = goals, steps = steps or {}, slope = slope, fitted = fitted or 0 }
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
local function NewGoalList(parent, width)
  local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(width, 1)
  scroll:SetScrollChild(content)
  local o = { scroll = scroll, content = content, width = width, blocks = {}, lines = {}, expanded = {} }

  local function Block(i)
    if o.blocks[i] then return o.blocks[i] end
    local b = {}
    b.label = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.note = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.value = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.value:SetJustifyH("RIGHT")
    b.barBG = content:CreateTexture(nil, "ARTWORK")
    b.barBG:SetColorTexture(0.17, 0.19, 0.23, 1)
    b.bar = content:CreateTexture(nil, "ARTWORK", nil, 1)
    b.toggle = CreateFrame("Button", nil, content)
    b.toggle:SetSize(160, 16)
    b.toggle.text = b.toggle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.toggle.text:SetPoint("LEFT")
    b.toggle:SetScript("OnClick", function(self)
      o.expanded[self.pct] = not o.expanded[self.pct]
      if o.onToggle then o.onToggle() end
    end)
    o.blocks[i] = b
    return b
  end

  local function Line(i)
    if o.lines[i] then return o.lines[i] end
    local l = {
      content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
      content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
      content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
    }
    l[1]:SetJustifyH("LEFT"); l[2]:SetJustifyH("RIGHT"); l[3]:SetJustifyH("RIGHT")
    o.lines[i] = l
    return l
  end

  function o:Render(data, expandedDefault)
    for _, b in pairs(self.blocks) do
      b.label:Hide(); b.note:Hide(); b.value:Hide(); b.barBG:Hide(); b.bar:Hide(); b.toggle:Hide()
    end
    for _, l in pairs(self.lines) do l[1]:Hide(); l[2]:Hide(); l[3]:Hide() end
    if not data then return 0 end
    local y, li, W = 0, 0, self.width
    for i, g in ipairs(data.goals) do
      local b = Block(i)
      b.label:SetText(GoalLabel(g)); b.label:ClearAllPoints(); b.label:SetPoint("TOPLEFT", 4, y); b.label:Show()
      local note = g.isNext and L["next step"] or (g.isTitle and L["season title"] or nil)
      if note then
        b.note:SetText(note); b.note:ClearAllPoints()
        b.note:SetPoint("BOTTOMLEFT", b.label, "BOTTOMRIGHT", 6, 1); b.note:Show()
      end
      b.value:SetText(NeedText(g)); b.value:ClearAllPoints(); b.value:SetPoint("TOPRIGHT", -4, y); b.value:Show()
      y = y - 18
      b.barBG:ClearAllPoints(); b.barBG:SetPoint("TOPLEFT", 4, y); b.barBG:SetSize(W - 8, 6); b.barBG:Show()
      b.bar:ClearAllPoints(); b.bar:SetPoint("TOPLEFT", b.barBG, "TOPLEFT")
      b.bar:SetSize(math.max(1, (W - 8) * (g.progress or 0)), 6)
      b.bar:SetColorTexture(ns.HexToRGB(ns.PctColor(g.pct)))
      b.bar:Show()
      y = y - 12

      if g.need > 0 and g.keys then
        local open = self.expanded[g.pct]
        if open == nil then open = expandedDefault end
        b.toggle.pct = g.pct
        if self.expanded[g.pct] == nil then self.expanded[g.pct] = open end
        b.toggle.text:SetText((open and MINUS or PLUS) .. " " .. L["Which keys"])
        b.toggle:ClearAllPoints(); b.toggle:SetPoint("TOPLEFT", 4, y); b.toggle:Show()
        y = y - 18
        if open then
          for k = 1, g.keys do
            local st = data.steps[k]
            li = li + 1
            local l = Line(li)
            local name = C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(st.map) or ("#" .. st.map)
            l[1]:SetText(string.format("|cff999999%d.|r  %s |cffffd100+%d|r", k, name, st.level))
            l[2]:SetText(string.format("|cff1eff00+%d|r", st.gain))
            l[3]:SetText("|cff999999" .. ns.Num(math.floor(data.score + st.total + 0.5)) .. "|r")
            l[1]:ClearAllPoints(); l[1]:SetPoint("TOPLEFT", 22, y)
            l[2]:ClearAllPoints(); l[2]:SetPoint("TOPRIGHT", -74, y)
            l[3]:ClearAllPoints(); l[3]:SetPoint("TOPRIGHT", -4, y)
            l[1]:Show(); l[2]:Show(); l[3]:Show()
            y = y - 15
          end
          y = y - 4
        end
      end
      y = y - 8
    end
    self.content:SetHeight(math.max(1, -y))
    return -y
  end
  return o
end

local function SlopeNote(data)
  if not data then return "" end
  if data.fitted >= 2 then
    return string.format(L["About %d rating per key at your level, from your own dungeon scores. Easiest keys first."],
      math.floor(data.slope + 0.5))
  end
  return L["Assumes about 15 rating per key until you've timed more dungeons. Easiest keys first."]
end

---------------------------------------------------------------------------
-- Overview tab
---------------------------------------------------------------------------
local overview = ns.NewHistoryView("overview", L["Overview"], function() ns.RefreshOverview() end, 10)
overview.header = overview:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
overview.header:SetPoint("TOPLEFT", 14, -6)
overview.rows = {}
overview.goalsTitle = overview:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
overview.goalsTitle:SetText(L["Goals"])
overview.note = overview:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
overview.note:SetPoint("BOTTOMLEFT", 12, 10)
overview.note:SetWidth(590); overview.note:SetJustifyH("LEFT")
overview.empty = overview:CreateFontString(nil, "OVERLAY", "GameFontDisable")
overview.empty:SetPoint("TOP", 0, -60)
local ovGoals = NewGoalList(overview, 580)
ovGoals.onToggle = function() ns.RefreshOverview() end

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
  y = y - 24
  ovGoals.scroll:ClearAllPoints()
  ovGoals.scroll:SetPoint("TOPLEFT", 10, y)
  ovGoals.scroll:SetPoint("BOTTOMRIGHT", -30, 28)
  local data = ns.Goals("overall")
  ovGoals:Render(data, false)
  overview.note:SetText(SlopeNote(data))
end

---------------------------------------------------------------------------
-- Goals tab: every goal with its keys, for overall or your spec
---------------------------------------------------------------------------
local goalsView = ns.NewHistoryView("goals", L["Goals"], function() ns.RefreshGoalsTab() end, 40)
goalsView.which = goalsView:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
goalsView.which:SetPoint("TOPLEFT", 14, -6)
goalsView.toggle = CreateFrame("Button", nil, goalsView, "UIPanelButtonTemplate")
goalsView.toggle:SetSize(150, 22)
goalsView.toggle:SetPoint("TOPRIGHT", -16, -4)
goalsView.note = goalsView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
goalsView.note:SetPoint("BOTTOMLEFT", 12, 10)
goalsView.note:SetWidth(590); goalsView.note:SetJustifyH("LEFT")
local gvGoals = NewGoalList(goalsView, 580)
gvGoals.scroll:SetPoint("TOPLEFT", 10, -40)
gvGoals.scroll:SetPoint("BOTTOMRIGHT", -30, 28)
gvGoals.onToggle = function() ns.RefreshGoalsTab() end
local useSpec = false
goalsView.toggle:SetScript("OnClick", function()
  useSpec = not useSpec
  gvGoals.expanded = {}
  ns.RefreshGoalsTab()
end)

function ns.RefreshGoalsTab()
  local id = ns.GetPlayerIdentity()
  local specKey = id.specID and ("spec:" .. id.specID)
  if not specKey then useSpec = false end
  local key = useSpec and specKey or "overall"
  local data = ns.Goals(key)
  local name = useSpec and (id.specName .. " " .. (id.className or "")) or L["Overall"]
  goalsView.which:SetText(string.format("%s  |c%s%s|r", name,
    data and ns.PctColor(data.pct) or "ffcccccc",
    data and string.format(L["Top %s"], ns.FormatPct(data.pct)) or ""))
  goalsView.toggle:SetText(useSpec and L["Show overall"] or (id.specName and string.format(L["Show %s"], id.specName) or L["Overall"]))
  goalsView.toggle:SetShown(specKey ~= nil)
  gvGoals:Render(data, true)
  goalsView.note:SetText(SlopeNote(data))
end

---------------------------------------------------------------------------
-- Panel docked to the right of Blizzard's Mythic+ window
---------------------------------------------------------------------------
local dock

local function BuildDock()
  if dock or not ChallengesFrame then return end
  dock = CreateFrame("Button", "KeystonePercentileDock", ChallengesFrame, "BackdropTemplate")
  dock:SetWidth(240)
  dock:SetPoint("TOPLEFT", PVEFrame or ChallengesFrame, "TOPRIGHT", 2, -2)
  dock:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  dock:SetBackdropColor(0, 0, 0, 0.85)
  dock:SetBackdropBorderColor(0, 0, 0, 1)
  dock.title = dock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  dock.title:SetPoint("TOPLEFT", 10, -8)
  dock.title:SetText("Keystone Percentile")
  dock.rows, dock.goals = {}, {}
  dock.hint = dock:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  dock:SetScript("OnClick", function() ns.ToggleHistory("overview") end)
  ChallengesFrame:HookScript("OnShow", function() ns.RefreshDock() end)
end

function ns.RefreshDock()
  if not dock then return end
  if KP_DB.dock == false then dock:Hide() return end
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
