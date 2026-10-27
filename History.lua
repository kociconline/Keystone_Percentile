-- Keystone Percentile: main window (/kp, minimap button or the Mythic+ window).
-- Tabs: Overview, Runs, Progress, Goals.
local ADDON, ns = ...
local L = ns.L

local W, ROW_H, VISIBLE = 660, 22, 14
local COLS = { -- x offset, width, justify
  date = { 10, 52, "LEFT" }, dungeon = { 66, 190, "LEFT" }, result = { 260, 54, "LEFT" },
  dps = { 316, 66, "RIGHT" }, rank = { 392, 84, "LEFT" }, bar = { 480, 96 },
}

local state = { dungeon = nil, spec = nil, season = nil, sort = "date" }
local SORTS = { "date", "rank", "dps" }
local SORT_NAMES = { date = L["Sort: date"], rank = L["Sort: rank"], dps = L["Sort: DPS / HPS"] }

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local win = CreateFrame("Frame", "KeystonePercentileHistory", UIParent, "BackdropTemplate")
win:SetSize(W, 110 + VISIBLE * ROW_H)
win:SetPoint("CENTER")
win:SetFrameStrata("HIGH")
win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
win:SetBackdropColor(0, 0, 0, 0.85)
win:SetBackdropBorderColor(0, 0, 0, 1)
win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
win:SetClampedToScreen(true)
win:SetScript("OnDragStart", win.StartMoving)
win:SetScript("OnDragStop", win.StopMovingOrSizing)
win:Hide()
tinsert(UISpecialFrames, "KeystonePercentileHistory")

local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

win.icon = win:CreateTexture(nil, "ARTWORK")
win.icon:SetSize(22, 22)
win.icon:SetPoint("TOPLEFT", 10, -8)
win.icon:SetTexture("Interface\\AddOns\\Keystone_Percentile\\Media\\Icon")
win.title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
win.title:SetPoint("TOPLEFT", 36, -12)
win.title:SetText("Keystone Percentile")

-- Each tab is a view frame filling the window; only one is shown.
local tabs, views = {}, {}

local function LayoutTabs()
  table.sort(tabs, function(a, b) return a.order < b.order end)
  for i, b in ipairs(tabs) do
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 225 + (i - 1) * 88, -10)
  end
end

local function NewView(key, label, refresh, order)
  local v = CreateFrame("Frame", nil, win)
  v:SetPoint("TOPLEFT", 0, -34); v:SetPoint("BOTTOMRIGHT")
  v:Hide()
  v.refresh = refresh
  views[key] = v
  local b = CreateFrame("Button", nil, win, "BackdropTemplate")
  b:SetSize(84, 20)
  b.order = order or (#tabs + 1) * 10
  b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.text:SetPoint("CENTER"); b.text:SetText(label)
  b.key = key
  b:SetScript("OnClick", function() ns.ShowHistoryTab(key) end)
  tabs[#tabs + 1] = b
  LayoutTabs()
  return v
end
ns.NewHistoryView = NewView

function ns.ShowHistoryTab(key)
  if not views[key] then key = "overview" end
  KP_DB.historyTab = key
  for k, v in pairs(views) do
    if k == key then v:Show(); if v.refresh then v.refresh() end else v:Hide() end
  end
  for _, b in ipairs(tabs) do
    local on = b.key == key
    b:SetBackdropColor(on and 0.25 or 0.08, on and 0.2 or 0.08, on and 0.05 or 0.1, 1)
    b:SetBackdropBorderColor(on and 0.8 or 0.3, on and 0.65 or 0.3, on and 0.1 or 0.32, 1)
  end
end

local Refresh -- defined below
local runsView = NewView("runs", L["Runs"], function() Refresh() end, 20)
ns.HistoryWindow = win

win.count = runsView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
win.count:SetPoint("TOPRIGHT", -34, 18)

-- Filter buttons cycle through their options on click (right-click goes back).
local function FilterButton(x, width)
  local b = CreateFrame("Button", nil, runsView, "BackdropTemplate")
  b:SetSize(width, 20)
  b:SetPoint("TOPLEFT", x, -4)
  b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  b:SetBackdropColor(0.1, 0.1, 0.12, 1)
  b:SetBackdropBorderColor(0.3, 0.3, 0.32, 1)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 6, 0); b.text:SetPoint("RIGHT", -6, 0); b.text:SetJustifyH("LEFT")
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(0.6, 0.6, 0.62, 1) end)
  b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.3, 0.3, 0.32, 1) end)
  return b
end

win.fSeason = FilterButton(12, 130)
win.fDungeon = FilterButton(148, 160)
win.fSpec = FilterButton(314, 110)
win.fSort = FilterButton(430, 80)

win.summary = runsView:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
win.summary:SetPoint("TOPRIGHT", -14, -8)

-- Column headers
local headers = { { "date", L["Date"] }, { "dungeon", L["Dungeon"] }, { "result", L["Result"] },
  { "dps", L["DPS / HPS"] }, { "rank", L["Rank"] }, { "bar", L["vs #1"] } }
for _, h in ipairs(headers) do
  local c = COLS[h[1]]
  local fs = runsView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  fs:SetPoint("TOPLEFT", c[1], -34)
  fs:SetWidth(c[2]); fs:SetJustifyH(c[3] or "LEFT")
  fs:SetText(h[2])
end

-- Scrolling list
local scroll = CreateFrame("ScrollFrame", "KeystonePercentileHistoryScroll", runsView, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 0, -50)
scroll:SetPoint("BOTTOMRIGHT", -28, 30)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(W - 28, 1)
scroll:SetScrollChild(content)

win.empty = runsView:CreateFontString(nil, "OVERLAY", "GameFontDisable")
win.empty:SetPoint("TOP", 0, -86)
win.empty:SetWidth(W - 60)

win.footer = runsView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
win.footer:SetPoint("BOTTOMLEFT", 12, 10)
win.footer:SetText(L["Click a run to open its summary · |TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12|t best run per dungeon · ~ estimated rank"])

local rows = {}
local function GetRow(i)
  if rows[i] then return rows[i] end
  local r = CreateFrame("Button", nil, content)
  r:SetSize(W - 28, ROW_H)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r.hl = r:CreateTexture(nil, "BACKGROUND")
  r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.06); r.hl:Hide()
  r.line = r:CreateTexture(nil, "BACKGROUND")
  r.line:SetPoint("TOPLEFT", 8, 0); r.line:SetPoint("TOPRIGHT", -4, 0); r.line:SetHeight(1)
  r.line:SetColorTexture(1, 1, 1, 0.08)
  for key, c in pairs(COLS) do
    if key ~= "bar" then
      local fs = r:CreateFontString(nil, "OVERLAY", key == "dungeon" and "GameFontHighlight" or "GameFontHighlightSmall")
      fs:SetPoint("LEFT", c[1], 0); fs:SetWidth(c[2]); fs:SetJustifyH(c[3]); fs:SetWordWrap(false)
      r[key] = fs
    end
  end
  local c = COLS.bar
  r.barBG = r:CreateTexture(nil, "ARTWORK")
  r.barBG:SetPoint("LEFT", c[1], 0); r.barBG:SetSize(c[2], 6)
  r.barBG:SetColorTexture(0.17, 0.19, 0.23, 1)
  r.bar = r:CreateTexture(nil, "ARTWORK", nil, 1)
  r.bar:SetPoint("LEFT", r.barBG, "LEFT"); r.bar:SetHeight(6)
  r:SetScript("OnEnter", function(self)
    self.hl:Show()
    if self.run and self.run.report then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Warcraft Logs report")
      GameTooltip:AddLine(self.run.report, 1, 1, 1)
      GameTooltip:Show()
    end
  end)
  r:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
  r:SetScript("OnClick", function(self) if self.run then ns.ShowRunPopup(self.run) end end)
  rows[i] = r
  return r
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
local function Options(runs, field, label)
  local seen, list = {}, {}
  for _, r in ipairs(runs) do
    local v = field(r)
    if v and not seen[v] then seen[v] = true; list[#list + 1] = v end
  end
  table.sort(list)
  return list
end

local function Cycle(list, current, dir)
  if #list == 0 then return nil end
  local idx = 0
  for i, v in ipairs(list) do if v == current then idx = i end end
  idx = idx + dir
  if idx < 0 then idx = #list end
  if idx > #list then idx = 0 end
  return idx == 0 and nil or list[idx]
end

local function Median(t)
  if #t == 0 then return nil end
  table.sort(t)
  local m = math.floor((#t + 1) / 2)
  return (#t % 2 == 1) and t[m] or (t[m] + t[m + 1]) / 2
end

local function ResultText(run)
  if run.timed == true then return "|cff1eff00+" .. (run.upgrades or 1) .. "|r" end
  if run.timed == false then return "|cffff5555Over|r" end
  return "|cff777777—|r"
end

local all = {}

function Refresh()
  all = ns.AllRuns()
  if state.season == nil and not state.seasonTouched then state.season = KP_DATA.season end

  local seasons = Options(all, function(r) return r.season end)
  local dungeons = Options(all, function(r) return ns.DungeonName(r) end)
  local specs = Options(all, function(r) return r.spec end)

  win.fSeason.text:SetText(state.season or L["All seasons"])
  win.fDungeon.text:SetText(state.dungeon or L["All dungeons"])
  win.fSpec.text:SetText(state.spec or L["All specs"])
  win.fSort.text:SetText(SORT_NAMES[state.sort])
  win.fSeason.options, win.fDungeon.options, win.fSpec.options = seasons, dungeons, specs

  -- Filter
  local list = {}
  for _, r in ipairs(all) do
    if (not state.season or r.season == state.season)
      and (not state.dungeon or ns.DungeonName(r) == state.dungeon)
      and (not state.spec or r.spec == state.spec) then
      r._ev = ns.EvaluateRun(r)
      list[#list + 1] = r
    end
  end

  -- Best run per dungeon (lowest top %), plus summary
  local best, tops = {}, {}
  for _, r in ipairs(list) do
    local top = r._ev.top
    if top then
      tops[#tops + 1] = top
      local d = ns.DungeonName(r)
      if not best[d] or top < best[d]._ev.top then best[d] = r end
    end
  end
  local bestAll = nil
  for _, t in ipairs(tops) do if not bestAll or t < bestAll then bestAll = t end end
  local med = Median(tops)
  if bestAll then
    win.summary:SetText(string.format("|cff999999%s|r |c%s%s|r  |cff999999· %s|r |c%s%s|r",
      L["Best"], ns.PctColor(bestAll), string.format(L["Top %s"], ns.FormatPct(bestAll)),
      L["Median"], ns.PctColor(med), string.format(L["Top %s"], ns.FormatPct(med))))
  else
    win.summary:SetText("")
  end

  -- Sort
  if state.sort == "rank" then
    table.sort(list, function(a, b) return (a._ev.top or 999) < (b._ev.top or 999) end)
  elseif state.sort == "dps" then
    table.sort(list, function(a, b) return (a._ev.amount or 0) > (b._ev.amount or 0) end)
  end

  win.count:SetText(string.format("%s · %d %s", state.season or L["All seasons"], #list, #list == 1 and L["run"] or L["runs"]))

  for i, r in ipairs(list) do
    local row = GetRow(i)
    row.run = r
    row.date:SetText("|cffaaaaaa" .. date("%b %d", r.t or 0) .. "|r")
    row.dungeon:SetText(string.format("%s +%s", ns.DungeonName(r), r.level or "?"))
    row.result:SetText(ResultText(r))
    row.dps:SetText(ns.FormatDPS(r._ev.amount) .. (r._ev.metric == "hps" and " |cff888888H|r" or ""))
    local star = (best[ns.DungeonName(r)] == r) and " |TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12|t" or ""
    row.rank:SetText(ns.TopText(r._ev) .. star)
    if r._ev.ofTop then
      row.barBG:Show(); row.bar:Show()
      row.bar:SetWidth(math.max(1, math.min(r._ev.ofTop, 1) * COLS.bar[2]))
      local hex = ns.PctColor(r._ev.top or 100)
      row.bar:SetColorTexture(tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255,
        tonumber(hex:sub(7, 8), 16) / 255, 1)
    else
      row.barBG:Hide(); row.bar:Hide()
    end
    row:Show()
  end
  for i = #list + 1, #rows do rows[i]:Hide(); rows[i].run = nil end
  content:SetHeight(math.max(1, #list * ROW_H))

  if #list == 0 then
    win.empty:SetText(#all == 0
      and L["No runs yet. Finish a key, or import your Warcraft Logs runs with tools/update_data.py."]
      or L["No runs match these filters."])
    win.empty:Show()
  else
    win.empty:Hide()
  end
end

local function Bind(btn, field)
  btn:SetScript("OnClick", function(self, button)
    state[field] = Cycle(self.options or {}, state[field], button == "RightButton" and -1 or 1)
    if field == "season" then state.seasonTouched = true end
    Refresh()
  end)
end
Bind(win.fSeason, "season")
Bind(win.fDungeon, "dungeon")
Bind(win.fSpec, "spec")
win.fSort:SetScript("OnClick", function()
  for i, s in ipairs(SORTS) do
    if s == state.sort then state.sort = SORTS[i % #SORTS + 1] break end
  end
  Refresh()
end)

function ns.ToggleHistory(tab)
  if win:IsShown() and (not tab or tab == KP_DB.historyTab) then win:Hide() return end
  win:Show()
  ns.ShowHistoryTab(tab or KP_DB.historyTab or "overview")
end

-- Keep the window current when a key finishes while it's open.
local ev = CreateFrame("Frame")
ev:RegisterEvent("CHALLENGE_MODE_COMPLETED")
ev:SetScript("OnEvent", function()
  C_Timer.After(5, function()
    if win:IsShown() then ns.ShowHistoryTab(KP_DB.historyTab or "overview") end
  end)
end)
