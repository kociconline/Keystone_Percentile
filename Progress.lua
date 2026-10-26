-- M+ Percentile: rating history graph ("Progress" tab) and next-key
-- suggestions ("Next keys" tab).
local ADDON, ns = ...
local L = ns.L

local DAY = 86400
local MAX_SNAPSHOTS = 400

---------------------------------------------------------------------------
-- Daily rating snapshots
---------------------------------------------------------------------------
local function History(key)
  MPP_DB.ratingHistory = MPP_DB.ratingHistory or {}
  key = key or ns.MyKey()
  MPP_DB.ratingHistory[key] = MPP_DB.ratingHistory[key] or {}
  return MPP_DB.ratingHistory[key]
end

-- Overall and spec "Top X%" for a score, for the current player.
local function Percentiles(score)
  local region = ns.GetRegion()
  local id = ns.GetPlayerIdentity()
  local overall = ns.EvaluateCohort(region, "overall", "overall", score, nil)
  local spec = id.specID and ns.EvaluateCohort(region, "spec:" .. id.specID, "spec_" .. id.specID, score, nil)
  return overall and overall.pct, spec and spec.pct, id
end

function ns.RecordSnapshot()
  local score = ns.GetScore("player")
  if not score or score <= 0 then return end
  local top, specTop, id = Percentiles(score)
  local hist = History()
  local day = date("%Y-%m-%d", GetServerTime())
  local last = hist[#hist]
  local entry = { d = day, t = GetServerTime(), score = score, top = top, specTop = specTop, specID = id.specID,
    season = MPP_DATA.season }
  if last and last.d == day then hist[#hist] = entry else hist[#hist + 1] = entry end
  while #hist > MAX_SNAPSHOTS do table.remove(hist, 1) end
end

-- The snapshot closest to (and not after) a time.
local function SnapshotAt(t)
  local found
  for _, e in ipairs(History()) do
    if e.t <= t then found = e else break end
  end
  return found
end

---------------------------------------------------------------------------
-- Progress view
---------------------------------------------------------------------------
local GW, GH = 540, 200
local range = 30 -- days; 0 = whole season

local view = ns.NewHistoryView("progress", L["Progress"], function() ns.RefreshProgress() end)
ns.ProgressView = view

view.today = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
view.today:SetPoint("TOPLEFT", 14, -6)
view.change7 = view:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
view.change7:SetPoint("TOPLEFT", 14, -30)
view.change30 = view:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
view.change30:SetPoint("TOPLEFT", 14, -48)

local graph = CreateFrame("Frame", nil, view, "BackdropTemplate")
graph:SetSize(GW, GH)
graph:SetPoint("TOPLEFT", 40, -80)
graph:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
graph:SetBackdropColor(1, 1, 1, 0.03)

graph.maxLabel = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
graph.maxLabel:SetPoint("TOPRIGHT", graph, "TOPLEFT", -4, 0)
graph.minLabel = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
graph.minLabel:SetPoint("BOTTOMRIGHT", graph, "BOTTOMLEFT", -4, 0)
graph.startLabel = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
graph.startLabel:SetPoint("TOPLEFT", graph, "BOTTOMLEFT", 0, -4)
graph.endLabel = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
graph.endLabel:SetPoint("TOPRIGHT", graph, "BOTTOMRIGHT", 0, -4)
graph.empty = view:CreateFontString(nil, "OVERLAY", "GameFontDisable")
graph.empty:SetPoint("CENTER", graph)
graph.empty:SetWidth(GW - 40)

local rangeBtn = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
rangeBtn:SetSize(110, 20)
rangeBtn:SetPoint("TOPRIGHT", -16, -6)
rangeBtn:SetScript("OnClick", function()
  range = (range == 30) and 0 or 30
  ns.RefreshProgress()
end)

view.note = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
view.note:SetPoint("BOTTOMLEFT", 12, 10)
view.note:SetText(L["Your rating is saved once a day while you play. Hover the graph for details."])

local lines, dots, gridLines = {}, {}, {}

local function Line(i)
  if not lines[i] then
    local l = graph.CreateLine and graph:CreateLine(nil, "ARTWORK") or nil
    if l then l:SetThickness(2) end
    lines[i] = l or false
  end
  return lines[i] or nil
end

local function Dot(i)
  if not dots[i] then
    local b = CreateFrame("Button", nil, graph)
    b:SetSize(10, 10)
    b.tex = b:CreateTexture(nil, "OVERLAY")
    b.tex:SetSize(5, 5); b.tex:SetPoint("CENTER")
    b:SetScript("OnEnter", function(self)
      local e = self.entry
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(e.d)
      GameTooltip:AddDoubleLine(L["Rating"], ns.Num(e.score), 1, 1, 1, 1, 1, 1)
      if e.top then GameTooltip:AddDoubleLine(L["Overall"], string.format(L["Top %s"], ns.FormatPct(e.top)), 1, 1, 1, ns.HexToRGB(ns.PctColor(e.top))) end
      if e.specTop then
        local info = ns.SpecInfo(e.specID)
        GameTooltip:AddDoubleLine(info and info.name or L["Spec"], string.format(L["Top %s"], ns.FormatPct(e.specTop)),
          1, 1, 1, ns.HexToRGB(ns.PctColor(e.specTop)))
      end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    dots[i] = b
  end
  return dots[i]
end

local function ChangeText(label, old, now)
  if not old then return string.format("|cff888888%s: %s|r", label, L["not enough history yet"]) end
  local diff = now.score - old.score
  local s = string.format("%s: |cff%s%s%d|r %s", label, diff >= 0 and "1eff00" or "ff5555", diff >= 0 and "+" or "",
    diff, L["rating"])
  if old.top and now.top then
    s = s .. string.format("  ·  |c%s%s|r → |c%s%s|r", ns.PctColor(old.top), string.format(L["Top %s"], ns.FormatPct(old.top)),
      ns.PctColor(now.top), string.format(L["Top %s"], ns.FormatPct(now.top)))
  end
  return s
end

function ns.RefreshProgress()
  ns.RecordSnapshot()
  local hist = History()
  local now = hist[#hist]
  rangeBtn:SetText(range == 30 and L["Last 30 days"] or L["Whole season"])

  if now then
    local spec = now.specTop and string.format("  ·  %s |c%s%s|r", (ns.SpecInfo(now.specID) or {}).name or "",
      ns.PctColor(now.specTop), string.format(L["Top %s"], ns.FormatPct(now.specTop))) or ""
    view.today:SetText(string.format("|c%s%s|r  |c%s%s|r %s%s", ns.PctColor(now.top or 100), ns.Num(now.score),
      ns.PctColor(now.top or 100), now.top and string.format(L["Top %s"], ns.FormatPct(now.top)) or "",
      now.top and L["overall"] or "", spec))
    view.change7:SetText(ChangeText(L["This week"], SnapshotAt(now.t - 7 * DAY), now))
    view.change30:SetText(ChangeText(L["Last 30 days"], SnapshotAt(now.t - 30 * DAY), now))
  else
    view.today:SetText(""); view.change7:SetText(""); view.change30:SetText("")
  end

  -- Points in range, current season only
  local pts = {}
  local from = (range > 0 and now) and (now.t - range * DAY) or 0
  for _, e in ipairs(hist) do
    if e.t >= from and (not now or e.season == now.season) then pts[#pts + 1] = e end
  end
  for _, l in pairs(lines) do if l then l:Hide() end end
  for _, d in pairs(dots) do d:Hide() end
  for _, g in pairs(gridLines) do g:Hide() end

  if #pts < 2 then
    graph.empty:SetText(L["The graph appears after two days of play. Your rating is saved once a day."])
    graph.empty:Show()
    graph.maxLabel:SetText(""); graph.minLabel:SetText(""); graph.startLabel:SetText(""); graph.endLabel:SetText("")
    return
  end
  graph.empty:Hide()

  local lo, hi = math.huge, -math.huge
  for _, e in ipairs(pts) do lo = math.min(lo, e.score); hi = math.max(hi, e.score) end
  if hi - lo < 50 then lo, hi = lo - 25, hi + 25 end
  local t0, t1 = pts[1].t, pts[#pts].t
  if t1 == t0 then t1 = t0 + 1 end
  graph.maxLabel:SetText(ns.Num(math.floor(hi))); graph.minLabel:SetText(ns.Num(math.floor(lo)))
  graph.startLabel:SetText(pts[1].d); graph.endLabel:SetText(pts[#pts].d)

  -- Faint horizontal guides at quarters
  for i = 1, 3 do
    local g = gridLines[i]
    if not g then
      g = graph:CreateTexture(nil, "BACKGROUND", nil, 1)
      g:SetColorTexture(1, 1, 1, 0.06); g:SetHeight(1)
      gridLines[i] = g
    end
    g:ClearAllPoints()
    g:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, GH * i / 4)
    g:SetPoint("BOTTOMRIGHT", graph, "BOTTOMRIGHT", 0, GH * i / 4)
    g:Show()
  end

  local function XY(e)
    return (e.t - t0) / (t1 - t0) * (GW - 10) + 5, (e.score - lo) / (hi - lo) * (GH - 10) + 5
  end
  local px, py
  for i, e in ipairs(pts) do
    local x, y = XY(e)
    local r, g, b = ns.HexToRGB(ns.PctColor(e.top or 100))
    if px then
      local l = Line(i)
      if l then
        l:SetColorTexture(r, g, b, 0.9)
        l:SetStartPoint("BOTTOMLEFT", graph, px, py)
        l:SetEndPoint("BOTTOMLEFT", graph, x, y)
        l:Show()
      end
    end
    local d = Dot(i)
    d.entry = e
    d.tex:SetColorTexture(r, g, b, 1)
    d:ClearAllPoints(); d:SetPoint("CENTER", graph, "BOTTOMLEFT", x, y); d:Show()
    px, py = x, y
  end
end

---------------------------------------------------------------------------
-- Next keys: which dungeon to push for the most rating
---------------------------------------------------------------------------
local nextView = ns.NewHistoryView("next", L["Next keys"], function() ns.RefreshNextKeys() end)
ns.NextKeysView, ns.NextKeysRows = nextView, nil

nextView.intro = nextView:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
nextView.intro:SetPoint("TOPLEFT", 14, -6)
nextView.intro:SetWidth(560); nextView.intro:SetJustifyH("LEFT")

local NCOLS = { { 14, 170, "LEFT" }, { 188, 90, "LEFT" }, { 282, 70, "LEFT" }, { 356, 70, "RIGHT" }, { 436, 140, "LEFT" } }
local nheaders = { L["Dungeon"], L["Your best"], L["Next"], L["Rating"], L["New rank"] }
for i, h in ipairs(nheaders) do
  local fs = nextView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  fs:SetPoint("TOPLEFT", NCOLS[i][1], -40); fs:SetWidth(NCOLS[i][2]); fs:SetJustifyH(NCOLS[i][3])
  fs:SetText(h)
end
nextView.note = nextView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
nextView.note:SetPoint("BOTTOMLEFT", 12, 10)
nextView.note:SetWidth(570); nextView.note:SetJustifyH("LEFT")

local nrows = {}
ns.NextKeysRows = nrows
local function NRow(i)
  if not nrows[i] then
    local r = {}
    for c = 1, #NCOLS do
      local fs = nextView:CreateFontString(nil, "OVERLAY", c == 1 and "GameFontHighlight" or "GameFontHighlightSmall")
      fs:SetWidth(NCOLS[c][2]); fs:SetJustifyH(NCOLS[c][3]); fs:SetWordWrap(false)
      r[c] = fs
    end
    nrows[i] = r
  end
  return nrows[i]
end

-- Rating per key level, fitted from your own timed dungeons.
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

function ns.RefreshNextKeys()
  local ok, summary = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, "player")
  local score = ns.GetScore("player")
  for _, r in pairs(nrows) do for c = 1, #NCOLS do r[c]:Hide() end end
  if not ok or not summary or not score then
    nextView.intro:SetText(L["Your Mythic+ rating isn't available yet. Try again in a moment."])
    return
  end

  local runs = summary.runs or {}
  local byMap = {}
  for _, r in ipairs(runs) do if r.challengeModeID then byMap[r.challengeModeID] = r end end
  local maps = (C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapTable()) or {}
  local slope, intercept, fitted = FitScores(runs)

  local lowestTimed
  for _, r in ipairs(runs) do
    if r.finishedSuccess and r.bestRunLevel and (not lowestTimed or r.bestRunLevel < lowestTimed) then
      lowestTimed = r.bestRunLevel
    end
  end

  local list = {}
  for _, map in ipairs(maps) do
    local r = byMap[map]
    local cur = r and r.mapScore or 0
    local best = r and r.bestRunLevel or 0
    local target
    if r and best > 0 then
      target = r.finishedSuccess and best + 1 or best
    else
      target = lowestTimed or 2
    end
    local predicted = intercept and (intercept + slope * target) or (cur + slope)
    local gain = math.max(0, math.floor(predicted - cur + 0.5))
    if r and r.finishedSuccess and gain < slope * 0.5 then gain = math.floor(slope + 0.5) end
    list[#list + 1] = { map = map, best = best, timed = r and r.finishedSuccess, cur = cur, target = target, gain = gain }
  end
  table.sort(list, function(a, b) return a.gain > b.gain end)

  local region, id = ns.GetRegion(), ns.GetPlayerIdentity()
  local nowOverall = ns.EvaluateCohort(region, "overall", "overall", score, nil)
  nextView.intro:SetText(string.format(L["Your rating: %s. Timing each dungeon one level higher would give about:"],
    "|c" .. ns.PctColor(nowOverall and nowOverall.pct or 100) .. ns.Num(score) .. "|r"))

  for i, e in ipairs(list) do
    local row = NRow(i)
    local y = -56 - (i - 1) * 20
    for c = 1, #NCOLS do row[c]:ClearAllPoints(); row[c]:SetPoint("TOPLEFT", nextView, "TOPLEFT", NCOLS[c][1], y); row[c]:Show() end
    local name = C_ChallengeMode.GetMapUIInfo(e.map) or ("#" .. e.map)
    row[1]:SetText(name)
    if e.best > 0 then
      row[2]:SetText(string.format("%s+%d|r |cff888888%d|r", e.timed and "|cff1eff00" or "|cffff5555", e.best, math.floor(e.cur + 0.5)))
    else
      row[2]:SetText("|cff777777" .. L["not run"] .. "|r")
    end
    row[3]:SetText("+" .. e.target)
    row[4]:SetText(string.format("|cffffd100+%d|r", e.gain))
    local newScore = score + e.gain
    local o = ns.EvaluateCohort(region, "overall", "overall", newScore, nil)
    local s = id.specID and ns.EvaluateCohort(region, "spec:" .. id.specID, "spec_" .. id.specID, newScore, nil)
    local text = o and string.format("|c%s%s|r", ns.PctColor(o.pct), string.format(L["Top %s"], ns.FormatPct(o.pct))) or "—"
    if s then text = text .. string.format(" |cff888888·|r |c%s%s|r", ns.PctColor(s.pct), ns.FormatPct(s.pct)) end
    row[5]:SetText(text)
  end

  nextView.note:SetText(fitted >= 2
    and string.format(L["Estimates use your own dungeon scores (about %d rating per key level). New rank: overall · your spec."], math.floor(slope + 0.5))
    or L["Estimates assume about 15 rating per key level until you've timed more dungeons. New rank: overall · your spec."])
end

---------------------------------------------------------------------------
-- When to take snapshots
---------------------------------------------------------------------------
ns.OnRunRecorded = function() C_Timer.After(5, ns.RecordSnapshot) end
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, _, isLogin)
  if isLogin then C_Timer.After(8, ns.RecordSnapshot) end
end)
