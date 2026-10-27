-- Keystone Percentile: records every key (damage, healing, deaths, avoidable damage,
-- interrupts, and the same for your group) and ranks it against Warcraft Logs
-- benchmarks for the spec, dungeon and key level. Healers are ranked on HPS.
local ADDON, ns = ...
local L = ns.L

-- Benchmark keys p0.1 ... p50 (DPS at that Top %, same class and spec); #1 is "top".
local ANCHORS = { 0.1, 0.5, 1, 2, 5, 10, 25, 50 }

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
local function FormatAmount(v)
  if not v then return "—" end
  if v >= 1e6 then return string.format("%.2fM", v / 1e6) end
  if v >= 1e3 then return string.format("%.1fk", v / 1e3) end
  return string.format("%d", v)
end
ns.FormatDPS = FormatAmount

local function FormatTime(sec)
  if not sec then return "" end
  return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end
ns.FormatTime = FormatTime

-- Run percentiles with two decimals below 10% and one above, e.g. "Top 5.02%".
local function RunPct(p)
  if p < 10 then return string.format("%.2f%%", p) end
  return string.format("%.1f%%", p)
end

local function ClassColor(classFile)
  local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  return c and c.colorStr or "ffffffff"
end
ns.ClassColor = ClassColor

local function HexToRGB(hex)
  return tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, tonumber(hex:sub(7, 8), 16) / 255
end
ns.HexToRGB = HexToRGB

function ns.DungeonName(run)
  if run.map and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
    local name = C_ChallengeMode.GetMapUIInfo(run.map)
    if name then return name end
  end
  if run.map and KP_DATA.dungeons and KP_DATA.dungeons[run.map] then return KP_DATA.dungeons[run.map] end
  return run.dungeon or "?"
end

---------------------------------------------------------------------------
-- Specs: role, names and the icon -> spec lookup used for group members
---------------------------------------------------------------------------
local specByIcon
local function SpecFromIcon(icon)
  if not specByIcon then
    specByIcon = {}
    local n = GetNumClasses and GetNumClasses() or 13
    for classID = 1, n do
      local count = GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID) or 0
      for i = 1, count do
        local id, _, _, specIcon = GetSpecializationInfoForClassID(classID, i)
        if id and specIcon then specByIcon[specIcon] = id end
      end
    end
  end
  return icon and specByIcon[icon]
end

local ROLE_FROM_GAME = { HEALER = "healer", TANK = "tank", DAMAGER = "dps" }
function ns.SpecInfo(specID)
  if not specID or not GetSpecializationInfoByID then return nil end
  local id, name, _, icon, role, classFile, className = GetSpecializationInfoByID(specID)
  if not id then return nil end
  return { name = name, icon = icon, role = ROLE_FROM_GAME[role] or "dps", classFile = classFile, className = className }
end

-- "hps" for healers, "dps" for everyone else.
function ns.RunMetric(run)
  local role = run.role
  if not role then
    local info = ns.SpecInfo(run.specID)
    role = info and info.role
  end
  return role == "healer" and "hps" or "dps", role or "dps"
end

---------------------------------------------------------------------------
-- Reading the game's damage meter. Values are secret during combat, so this
-- only runs out of combat (at key start, and right after the key ends).
---------------------------------------------------------------------------
local METER_TYPES = {
  damage = "DamageDone", healing = "HealingDone", taken = "DamageTaken",
  avoidable = "AvoidableDamageTaken", interrupts = "Interrupts", deaths = "Deaths",
}

local function ShortName(name)
  return name and name:match("^[^%-]+") or name
end

local function GroupNames()
  local names = {}
  for i = 1, 4 do
    local n = UnitName("party" .. i)
    if n then names[n] = true end
  end
  return names
end

-- { me = {damage=..,...}, ["Name"] = {damage=.., classFile=.., specIcon=..}, ... }
local function MeterSnapshot()
  if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum.DamageMeterSessionType
      and Enum.DamageMeterType) then
    return nil
  end
  local party = GroupNames()
  local snap = {}
  for field, enumName in pairs(METER_TYPES) do
    local mtype = Enum.DamageMeterType[enumName]
    if mtype then
      pcall(function()
        local session = C_DamageMeter.GetCombatSessionFromType(Enum.DamageMeterSessionType.Overall, mtype)
        if not session or ns.IsSecret(session) then return end
        for _, src in ipairs(session.combatSources or {}) do
          local v = src.totalAmount
          if v ~= nil and not ns.IsSecret(v) then
            local key
            if src.isLocalPlayer then
              key = "me"
            elseif src.name and not ns.IsSecret(src.name) and party[ShortName(src.name)] then
              key = ShortName(src.name)
            end
            if key then
              local e = snap[key] or {}
              e[field] = v
              e.classFile = e.classFile or src.classFilename
              e.specIcon = e.specIcon or src.specIconID
              snap[key] = e
            end
          end
        end
      end)
    end
  end
  return snap -- may be empty: an empty meter is a valid zero baseline
end

local function Diff(now, base, field)
  local v = now and now[field]
  if v == nil then return nil end
  local b = base and base[field]
  if b and v >= b then return v - b end
  return v
end

local function CompletionInfo()
  if C_ChallengeMode.GetChallengeCompletionInfo then
    local ok, i = pcall(C_ChallengeMode.GetChallengeCompletionInfo)
    if ok and i and i.mapChallengeModeID then
      return i.mapChallengeModeID, i.level, i.time, i.onTime, i.keystoneUpgradeLevels, i.newOverallDungeonScore
    end
  end
  if C_ChallengeMode.GetCompletionInfo then
    return C_ChallengeMode.GetCompletionInfo()
  end
end

---------------------------------------------------------------------------
-- Benchmarks and ranking
---------------------------------------------------------------------------
-- Benchmark for this dungeon/spec/level, or the nearest level within 3.
local function BenchTable(source, map, specID)
  local t = source and source.dps and map and source.dps[map]
  return t and specID and t[specID]
end

function ns.Benchmark(map, specID, level)
  -- Same key level first; one level up or down only when that's all there is
  -- (shown as "nearest key level"). Your personal benchmarks (fetched for your
  -- own keys) win over the shared ones.
  if not level then return nil end
  local mine, shared = BenchTable(KP_PERSONAL, map, specID), BenchTable(KP_DATA, map, specID)
  for d = 0, 1 do
    for _, lv in ipairs(d == 0 and { level } or { level - d, level + d }) do
      if mine and mine[lv] then return mine[lv], lv end
      if shared and shared[lv] then return shared[lv], lv end
    end
  end
end

local function Anchors(b)
  local list = {}
  if b.top and b.n and b.n > 0 then list[#list + 1] = { pct = math.max(100 / b.n, 0.01), v = b.top } end
  for _, a in ipairs(ANCHORS) do
    local v = b["p" .. a]
    if v and (#list == 0 or v < list[#list].v) then list[#list + 1] = { pct = a, v = v } end
  end
  return list
end

local function EstimateTop(amount, b)
  local c = Anchors(b)
  if #c == 0 then return nil end
  if amount >= c[1].v then return c[1].pct end
  for i = 1, #c - 1 do
    local hi, lo = c[i], c[i + 1]
    if amount >= lo.v then
      if hi.v == lo.v then return lo.pct end
      local t = (amount - lo.v) / (hi.v - lo.v)
      return math.exp(math.log(lo.pct) + t * (math.log(hi.pct) - math.log(lo.pct)))
    end
  end
  local last = c[#c]
  if amount <= 0 or last.v <= 0 then return 100 end
  return last.pct + (100 - last.pct) * (1 - amount / last.v)
end

-- Rank one amount (DPS or HPS) for a spec in a dungeon/level.
function ns.Rank(map, specID, level, metric, amount, officialPct)
  local ev = { metric = metric, amount = amount }
  local b, bLevel = ns.Benchmark(map, specID, level)
  if b and b.m and b.m ~= metric then b = nil end
  ev.bench, ev.benchLevel = b, bLevel
  if officialPct then
    ev.top, ev.exact = math.max(100 - officialPct, 0.01), true
  elseif b and amount then
    ev.top = EstimateTop(amount, b)
  end
  if b and b.top and amount and b.top > 0 then ev.ofTop = amount / b.top end
  return ev
end

function ns.EvaluateRun(run)
  local metric, role = ns.RunMetric(run)
  local amount = run[metric]
  local official = metric == "hps" and run.hpct or run.pct
  local ev = ns.Rank(run.map, run.specID, run.level, metric, amount, official)
  ev.role = role
  return ev
end

function ns.TopText(ev)
  if not ev or not ev.top then return "|cff777777—|r" end
  return string.format("|c%s%s%s|r", ns.PctColor(ev.top), ev.exact and "" or "~",
    string.format(L["Top %s"], RunPct(ev.top)))
end

local function AmountLabel(metric, role)
  if metric == "hps" then return L["your HPS"] end
  if role == "tank" then return L["your DPS (tank)"] end
  return L["your DPS"]
end

---------------------------------------------------------------------------
-- Run storage
---------------------------------------------------------------------------
local function MyKey() return ns.Key(UnitName("player"), GetRealmName()) end
ns.MyKey = MyKey

function ns.LiveRuns(key)
  KP_RUNS = KP_RUNS or {}
  key = key or MyKey()
  KP_RUNS[key] = KP_RUNS[key] or {}
  return KP_RUNS[key]
end

-- Live runs merged with runs imported from Warcraft Logs. A run that was
-- recorded live and also uploaded appears once, with the official rank.
function ns.AllRuns(key)
  key = key or MyKey()
  local out, used = {}, {}
  local imported = (KP_PERSONAL and KP_PERSONAL.imported and KP_PERSONAL.imported[key])
    or (KP_DATA.imported and KP_DATA.imported[key]) or {}
  for _, live in ipairs(ns.LiveRuns(key)) do
    local r = {}
    for k, v in pairs(live) do r[k] = v end
    for i, imp in ipairs(imported) do
      if not used[i] and imp.level == live.level
        and ((imp.map and imp.map == live.map) or (not imp.map and imp.dungeon == ns.DungeonName(live)))
        and math.abs((imp.t or 0) - (live.t or 0)) < 3 * 3600 then
        used[i] = true
        r.pct, r.hpct, r.report, r.src = imp.pct, imp.hpct, imp.report, "both"
        r.n, r.hn, r.score = imp.n, imp.hn, imp.score
        if r.dps == nil then r.dps = imp.dps end
        if r.hps == nil then r.hps = imp.hps end
        break
      end
    end
    out[#out + 1] = r
  end
  for i, imp in ipairs(imported) do
    if not used[i] then out[#out + 1] = imp end
  end
  table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
  return out
end

-- Your averages over recorded runs, for "is this run unusual?"
local function Averages()
  local n, deaths, avoid, kicks = 0, 0, 0, 0
  for _, r in ipairs(ns.LiveRuns()) do
    if r.deaths and r.avoidPct then
      n = n + 1
      deaths, avoid, kicks = deaths + r.deaths, avoid + r.avoidPct, kicks + (r.interrupts or 0)
    end
  end
  if n < 3 then return nil end
  return { deaths = deaths / n, avoid = avoid / n, kicks = kicks / n, n = n }
end

---------------------------------------------------------------------------
-- Sharing a run in chat
---------------------------------------------------------------------------
function ns.ShareText(run)
  local ev = ns.EvaluateRun(run)
  local spec = (run.spec or "") .. (run.className and (" " .. run.className) or "")
  local timed, up = ns.RunResult(run)
  local result = timed == true and string.format(L["Timed +%d"], up or 1)
    or timed == false and L["Over time"] or nil
  local parts = { string.format("%s +%s%s", ns.DungeonName(run), run.level or "?", result and (" (" .. result .. ")") or "") }
  if spec ~= "" then parts[#parts + 1] = spec end
  if ev.amount then parts[#parts + 1] = FormatAmount(ev.amount) .. " " .. (ev.metric == "hps" and "HPS" or "DPS") end
  if ev.top then
    parts[#parts + 1] = (ev.exact and "" or "~") .. string.format(L["Top %s"], RunPct(ev.top))
      .. (ev.exact and " (Warcraft Logs)" or "")
  end
  return "[Keystone Percentile] " .. table.concat(parts, " · ")
end

local function SendChat(msg, channel)
  if C_ChatInfo and C_ChatInfo.SendChatMessage then
    C_ChatInfo.SendChatMessage(msg, channel)
  else
    SendChatMessage(msg, channel)
  end
end

function ns.ShareRun(run, toGuild)
  local msg = ns.ShareText(run)
  local channel
  if toGuild then
    channel = IsInGuild() and "GUILD" or nil
  elseif IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    channel = "INSTANCE_CHAT"
  elseif IsInGroup() then
    channel = "PARTY"
  end
  if channel then SendChat(msg, channel) else print(msg) end
end

---------------------------------------------------------------------------
-- Run result (timed / over time). Imported runs without a medal get it from
-- their time against the dungeon's timer.
---------------------------------------------------------------------------
function ns.RunResult(run)
  if run.timed ~= nil then return run.timed, run.upgrades end
  if run.dur and run.map and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
    local _, _, limit = C_ChallengeMode.GetMapUIInfo(run.map)
    if limit and limit > 0 then
      if run.dur > limit then return false, 0 end
      return true, (run.dur <= limit * 0.6 and 3) or (run.dur <= limit * 0.8 and 2) or 1
    end
  end
end

function ns.ResultText(run)
  local timed, up = ns.RunResult(run)
  if timed == true then return "|cff1eff00" .. string.format(L["Timed +%d"], up or 1) .. "|r" end
  if timed == false then return "|cffff5555" .. L["Over time"] .. "|r" end
  return "|cff777777" .. L["Result unknown"] .. "|r"
end

---------------------------------------------------------------------------
-- Comparisons with the same class and spec, dungeon and key level
---------------------------------------------------------------------------
local NEXT_STEPS = { 25, 10, 5, 2, 0.5 } -- shown as "next step" between median, 1% and 0.1%

-- "Elemental Shaman"
function ns.SpecLabel(run)
  local spec = run.spec
  local cls = run.className
  if (not spec or not cls) and run.specID then
    local info = ns.SpecInfo(run.specID)
    spec, cls = spec or (info and info.name), cls or (info and info.className)
  end
  return ((spec or "") .. (cls and (" " .. cls) or "")):gsub("^%s+", "")
end

-- "+22%" (green) or "−9%" (red): your amount against a benchmark value.
function ns.DiffText(amount, v)
  if not amount or not v or v <= 0 then return "|cff777777—|r" end
  local d = (amount - v) / v * 100
  local txt = math.abs(d) < 1 and string.format("%.1f%%", math.abs(d)) or string.format("%d%%", math.floor(math.abs(d) + 0.5))
  if d >= 0 then return "|cff1eff00+" .. txt .. "|r" end
  return "|cffff6060−" .. txt .. "|r"
end

-- The next bracket above your rank that sits between the median and Top 1%.
local function NextStep(ev)
  local b = ev.bench
  if not (b and ev.top) then return nil end
  for _, a in ipairs(NEXT_STEPS) do
    if a < ev.top and b["p" .. a] and not (a < 1 and ev.top > 1) then return a end
  end
end

function ns.CompareRows(run, ev)
  ev = ev or ns.EvaluateRun(run)
  local b, out = ev.bench, {}
  if not b then return out end
  local who = ns.SpecLabel(run)
  local function Add(kind, label, v, note)
    if v and v > 0 then out[#out + 1] = { kind = kind, label = label, v = v, note = note } end
  end
  Add("median", string.format(L["Median %s"], who), b.p50)
  local nxt = NextStep(ev)
  if nxt and nxt ~= 1 then Add("next", string.format(L["Top %s"], nxt .. "%"), b["p" .. nxt], L["your next step"]) end
  Add("p1", string.format(L["Top %s"], "1%"), b.p1)
  Add("p01", string.format(L["Top %s"], "0.1%"), b["p0.1"])
  Add("top", string.format(L["#1 %s"], who), b.top)
  return out
end

-- "#14 of 1,672"
local function Position(ev, run)
  local n = ev.exact and ((ev.metric == "hps") and run.hn or run.n) or (ev.bench and ev.bench.n)
  if not (n and ev.top) then return nil end
  return math.max(1, math.floor(ev.top / 100 * n + 0.5)), n
end

---------------------------------------------------------------------------
-- Run detail: used by the end-of-key pop-up and the page inside the window
---------------------------------------------------------------------------
local Detail = {}
Detail.__index = Detail

function ns.NewRunDetail(parent, width, opts)
  opts = opts or {}
  local d = setmetatable({ f = parent, w = width, pad = 14, opts = opts }, Detail)
  local function FS(font, justify)
    local f = parent:CreateFontString(nil, "OVERLAY", font)
    f:SetJustifyH(justify or "LEFT")
    f:SetWordWrap(false)
    return f
  end
  d.FS = FS
  d.title = FS("GameFontNormalLarge")
  d.result = FS("GameFontHighlight")
  d.meta = FS("GameFontDisableSmall", "RIGHT")
  d.spec = FS("GameFontHighlightSmall")
  d.boxes = {}
  for i = 1, 3 do
    local bx = { bg = parent:CreateTexture(nil, "ARTWORK"),
      label = FS("GameFontDisableSmall"), value = FS("GameFontHighlightLarge"), sub = FS("GameFontDisableSmall") }
    bx.bg:SetColorTexture(1, 1, 1, 0.06)
    d.boxes[i] = bx
  end
  d.cmpTitle = FS("GameFontNormal")
  d.barBG = parent:CreateTexture(nil, "ARTWORK")
  d.barBG:SetColorTexture(0.17, 0.19, 0.23, 1)
  d.bar = parent:CreateTexture(nil, "ARTWORK", nil, 1)
  d.you = FS("GameFontHighlightSmall", "CENTER")
  d.you:SetText(L["you"])
  d.markers = {}
  for i = 1, 6 do
    d.markers[i] = { tex = parent:CreateTexture(nil, "OVERLAY"), label = FS("GameFontDisableSmall", "CENTER") }
    d.markers[i].tex:SetSize(2, 16)
  end
  d.cmp = {}
  for i = 1, 6 do
    d.cmp[i] = { stripe = parent:CreateTexture(nil, "ARTWORK"), label = FS("GameFontHighlight"),
      value = FS("GameFontHighlight", "RIGHT"), diff = FS("GameFontHighlight", "RIGHT"), note = FS("GameFontDisableSmall", "RIGHT") }
    d.cmp[i].stripe:SetColorTexture(1, 1, 1, 0.04)
  end
  d.noData = FS("GameFontDisable")
  d.why = FS("GameFontHighlightSmall")
  d.why:SetWordWrap(true)
  d.groupTitle = FS("GameFontNormal")
  d.members = {}
  for i = 1, 5 do d.members[i] = { FS("GameFontHighlightSmall"), FS("GameFontDisableSmall", "RIGHT"), FS("GameFontHighlightSmall", "RIGHT") } end
  d.goal = FS("GameFontHighlight")
  d.footer = FS("GameFontDisableSmall")

  local share = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  share:SetSize(70, 20)
  share:SetText(L["Share"])
  share:SetScript("OnClick", function() if d.run then ns.ShareRun(d.run, IsShiftKeyDown()) end end)
  share:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(L["Share"])
    GameTooltip:AddLine(L["Click: group chat. Shift-click: guild chat."], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  share:SetScript("OnLeave", GameTooltip_Hide)
  d.share = share
  return d
end

function Detail:Place(fs, x, y, point)
  fs:ClearAllPoints()
  fs:SetPoint(point or "TOPLEFT", self.f, point or "TOPLEFT", x, y)
  fs:Show()
end

local function WhyText(run)
  if run.deaths == nil and run.avoidPct == nil and run.interrupts == nil then return nil end
  local avg = Averages()
  local parts = {}
  if run.deaths ~= nil then
    local bad = run.deaths > 0 and (not avg or run.deaths > avg.deaths)
    local word = run.deaths == 1 and L["death"] or L["deaths"]
    parts[#parts + 1] = string.format("|cff%s%d %s|r", bad and "ff5555" or "dddddd", run.deaths, word)
  end
  if run.avoidPct ~= nil then
    local bad = avg and run.avoidPct > avg.avoid * 1.2
    parts[#parts + 1] = string.format("|cff%s%d%% %s|r", bad and "ff5555" or "dddddd",
      math.floor(run.avoidPct + 0.5), L["avoidable damage"])
  end
  if run.interrupts ~= nil then
    parts[#parts + 1] = string.format("|cffdddddd%d %s|r", run.interrupts, L["interrupts"])
  end
  local s = table.concat(parts, "  ·  ")
  if avg then
    s = s .. string.format("\n|cff888888%s: %.1f %s · %d%% %s · %.1f %s|r", L["your average"],
      avg.deaths, L["deaths"], math.floor(avg.avoid + 0.5), L["avoidable"], avg.kicks, L["interrupts"])
  end
  return s
end

-- Draws a run; returns the height used.
function Detail:Render(run)
  self.run = run
  local P, W = self.pad, self.w
  local ev = ns.EvaluateRun(run)
  local b = ev.bench
  local who = ns.SpecLabel(run)
  local y = -(self.opts.top or 12)
  local x0 = self.opts.titleX or P

  -- Header: dungeon and key, result, date
  self.title:SetText(string.format("%s +%s", ns.DungeonName(run), run.level or "?"))
  self:Place(self.title, x0, y)
  self.result:SetText(ns.ResultText(run))
  self.result:ClearAllPoints(); self.result:SetPoint("LEFT", self.title, "RIGHT", 10, 0); self.result:Show()
  local meta = date("%b %d", run.t or 0)
  if run.dur then meta = meta .. " · " .. FormatTime(run.dur) end
  self.meta:SetText(meta)
  self:Place(self.meta, -(self.opts.metaRight or P), y - 4, "TOPRIGHT")
  y = y - 20
  local spec = who
  if run.hero then spec = spec .. " · " .. run.hero end
  self.spec:SetText(string.format("|c%s%s|r", ClassColor(run.classFile), spec))
  self:Place(self.spec, x0, y)
  y = y - 22

  -- Three boxes: your DPS, your rank, #1 of your spec
  local gap = 8
  local bw = (W - 2 * P - 2 * gap) / 3
  local pos, n = Position(ev, run)
  local metricName = ev.metric == "hps" and "HPS" or "DPS"
  local boxes = {
    { AmountLabel(ev.metric, ev.role) .. (run.approx and (" (" .. L["approx."] .. ")") or ""),
      ev.amount and FormatAmount(ev.amount) or "|cff777777—|r",
      ev.amount and "" or L["Couldn't read your damage for this run."] },
    { L["Your rank"], ns.TopText(ev),
      pos and string.format(L["#%s of %s at +%d"], ns.Num(pos), ns.Num(n), (not ev.exact and ev.benchLevel) or run.level or 0)
        or (ev.top and "" or L["No data for this key yet"]) },
    { string.format(L["#1 %s"], who), b and b.top and FormatAmount(b.top) or "|cff777777—|r",
      (ev.ofTop and string.format(L["you're at %d%% of it"], math.floor(ev.ofTop * 100 + 0.5))) or "" },
  }
  for i, bx in ipairs(self.boxes) do
    local x = P + (i - 1) * (bw + gap)
    bx.bg:ClearAllPoints(); bx.bg:SetPoint("TOPLEFT", self.f, "TOPLEFT", x, y); bx.bg:SetSize(bw, 56); bx.bg:Show()
    bx.label:SetText(boxes[i][1]); bx.label:SetWidth(bw - 16); self:Place(bx.label, x + 8, y - 7)
    bx.value:SetText(boxes[i][2]); self:Place(bx.value, x + 8, y - 21)
    bx.sub:SetText(boxes[i][3]); bx.sub:SetWidth(bw - 16); self:Place(bx.sub, x + 8, y - 41)
  end
  y = y - 66

  -- Comparison with the same class and spec at this dungeon and key level
  local rowsData = ns.CompareRows(run, ev)
  for _, m in ipairs(self.markers) do m.tex:Hide(); m.label:Hide() end
  if b and #rowsData > 0 then
    local lvlNote = (ev.benchLevel and ev.benchLevel ~= run.level)
      and ("  |cff888888" .. string.format(L["(using +%d, the nearest key with data)"], ev.benchLevel) .. "|r") or ""
    self.cmpTitle:SetText(string.format(L["Compared with %s players · %s +%d"], who, ns.DungeonName(run), run.level or 0)
      .. string.format(" |cff888888· %s %s|r", ns.Num(b.n or 0), L["logged runs"]) .. lvlNote)
    self.cmpTitle:SetWidth(W - 2 * P)
    self:Place(self.cmpTitle, P, y)
    y = y - 30
    self.noData:Hide()

    -- Bar from 0 to #1 with markers
    local BW = W - 2 * P - 6
    if ev.amount and b.top and b.top > 0 then
      self.barBG:ClearAllPoints(); self.barBG:SetPoint("TOPLEFT", self.f, "TOPLEFT", P + 3, y); self.barBG:SetSize(BW, 8); self.barBG:Show()
      local frac = math.min(ev.amount / b.top, 1)
      self.bar:ClearAllPoints(); self.bar:SetPoint("TOPLEFT", self.barBG, "TOPLEFT")
      self.bar:SetSize(math.max(1, frac * BW), 8)
      self.bar:SetColorTexture(HexToRGB(ns.PctColor(ev.top or 100))); self.bar:Show()
      self.you:ClearAllPoints(); self.you:SetPoint("BOTTOM", self.barBG, "TOPLEFT", frac * BW, 3); self.you:Show()
      local lastX, mi = -100, 0
      for _, r in ipairs(rowsData) do
        if r.kind ~= "top" then
          mi = mi + 1
          local mk = self.markers[mi]
          local xm = math.min(r.v / b.top, 1) * BW
          mk.tex:SetColorTexture(0.9, 0.88, 0.8, 0.9)
          mk.tex:ClearAllPoints(); mk.tex:SetPoint("TOP", self.barBG, "TOPLEFT", xm, 4); mk.tex:Show()
          if xm - lastX > 40 then
            local short = r.kind == "median" and L["median"] or (r.kind == "p1" and "1%") or (r.kind == "p01" and "0.1%")
              or r.label:match("[%d%.]+%%") or ""
            mk.label:SetText(short); mk.label:ClearAllPoints()
            mk.label:SetPoint("TOP", self.barBG, "BOTTOMLEFT", xm, -4); mk.label:Show()
            lastX = xm
          end
        end
      end
      local mk = self.markers[6]
      mk.tex:SetColorTexture(1, 0.82, 0, 1)
      mk.tex:ClearAllPoints(); mk.tex:SetPoint("TOP", self.barBG, "TOPRIGHT", 0, 4); mk.tex:Show()
      mk.label:SetText("#1"); mk.label:ClearAllPoints()
      mk.label:SetPoint("TOPRIGHT", self.barBG, "BOTTOMRIGHT", 0, -4); mk.label:Show()
      y = y - 30
    else
      self.barBG:Hide(); self.bar:Hide(); self.you:Hide()
    end

    -- Table: each point with its DPS and how far you are from it
    for i, row in ipairs(self.cmp) do
      local r = rowsData[i]
      if r then
        row.stripe:ClearAllPoints(); row.stripe:SetPoint("TOPLEFT", self.f, "TOPLEFT", P, y + 3)
        row.stripe:SetSize(W - 2 * P, 18); row.stripe:SetShown(i % 2 == 1)
        row.label:SetText(r.label); row.label:SetWidth(W * 0.42); self:Place(row.label, P + 6, y)
        row.value:SetText(FormatAmount(r.v) .. " " .. metricName); self:Place(row.value, -(P + W * 0.30), y, "TOPRIGHT")
        local diff = ev.amount and ns.DiffText(ev.amount, r.v) or "|cff777777—|r"
        local gapTxt = ""
        if ev.amount and r.v > ev.amount then gapTxt = "|cff888888" .. string.format(L["%s short"], FormatAmount(r.v - ev.amount)) .. "|r" end
        row.diff:SetText(diff); self:Place(row.diff, -(P + W * 0.17), y, "TOPRIGHT")
        row.note:SetText(r.note and ("|cffffd100" .. r.note .. "|r") or gapTxt); self:Place(row.note, -(P + 6), y + 1, "TOPRIGHT")
        y = y - 19
      else
        row.stripe:Hide(); row.label:Hide(); row.value:Hide(); row.diff:Hide(); row.note:Hide()
      end
    end
  else
    self.cmpTitle:Hide(); self.barBG:Hide(); self.bar:Hide(); self.you:Hide()
    for _, row in ipairs(self.cmp) do row.stripe:Hide(); row.label:Hide(); row.value:Hide(); row.diff:Hide(); row.note:Hide() end
    self.noData:SetText(string.format(L["No Warcraft Logs data yet for %s in %s +%d."], who, ns.DungeonName(run), run.level or 0)
      .. "\n|cff888888" .. L["Run tools/update_data.py to fetch it for your keys."] .. "|r")
    self.noData:SetWordWrap(true); self.noData:SetWidth(W - 2 * P)
    self:Place(self.noData, P, y)
    y = y - 34
  end

  -- What happened: deaths, avoidable damage, interrupts
  local why = WhyText(run)
  if why then
    y = y - 8
    self.why:SetText(why); self.why:SetWidth(W - 2 * P); self:Place(self.why, P, y)
    y = y - self.why:GetStringHeight() - 2
  else
    self.why:Hide()
  end

  -- Whole group, each against their own spec
  local members = run.group or {}
  if #members > 0 and KP_DB.groupRanks ~= false then
    y = y - 10
    self.groupTitle:SetText(L["Your group"]); self:Place(self.groupTitle, P, y)
    y = y - 17
    for i, row in ipairs(self.members) do
      local m = members[i]
      if m then
        local info = ns.SpecInfo(m.specID)
        local metric = (info and info.role == "healer") and "hps" or "dps"
        local mev = ns.Rank(run.map, m.specID, run.level, metric, m[metric])
        row[1]:SetText(string.format("|c%s%s|r |cff999999%s|r", ClassColor(m.classFile), m.name or "?", info and info.name or ""))
        self:Place(row[1], P, y)
        row[2]:SetText(FormatAmount(m[metric]) .. " " .. (metric == "hps" and "HPS" or "DPS")); self:Place(row[2], -(P + 110), y, "TOPRIGHT")
        row[3]:SetText(ns.TopText(mev)); self:Place(row[3], -P, y, "TOPRIGHT")
        y = y - 15
      else
        for c = 1, 3 do row[c]:Hide() end
      end
    end
  else
    self.groupTitle:Hide()
    for _, row in ipairs(self.members) do for c = 1, 3 do row[c]:Hide() end end
  end

  -- Your next rating goal, only right after the key you just finished
  local live = ns.LiveRuns()
  local goal = (self.opts.showGoal and run.src == "live" and live[#live] == run and ns.GoalLine) and ns.GoalLine() or nil
  if goal then
    y = y - 10
    self.goal:SetText(goal); self:Place(self.goal, P, y)
    y = y - 16
  else
    self.goal:Hide()
  end

  local foot
  if ev.exact and run.report then
    foot = "Warcraft Logs · " .. run.report
  elseif b then
    foot = L["Warcraft Logs benchmarks"] .. " · " .. (KP_DATA.updatedAt or "")
  else
    foot = run.src == "logs" and L["Imported from Warcraft Logs"] or L["Recorded in game"]
  end
  if ev.top and not ev.exact then foot = foot .. " · " .. L["~ estimated rank"] end
  y = y - 12
  self.footer:SetText(foot); self.footer:SetWidth(W - 2 * P - 80)
  self:Place(self.footer, P, y)
  self.share:ClearAllPoints(); self.share:SetPoint("TOPRIGHT", self.f, "TOPRIGHT", -P, y + 4); self.share:Show()
  return -y + 20
end

---------------------------------------------------------------------------
-- End-of-key pop-up (solid, movable)
---------------------------------------------------------------------------
local POP_W = 470
local popup = CreateFrame("Frame", "KeystonePercentileRunPopup", UIParent, "BackdropTemplate")
popup:SetSize(POP_W, 300)
popup:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
popup:SetFrameStrata("DIALOG")
popup:SetToplevel(true)
popup:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
popup:SetBackdropColor(0.06, 0.06, 0.07, 1)
popup:SetBackdropBorderColor(0.45, 0.37, 0.18, 1)
popup:SetMovable(true); popup:EnableMouse(true); popup:RegisterForDrag("LeftButton")
popup:SetClampedToScreen(true)
popup:SetScript("OnDragStart", popup.StartMoving)
popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
popup:Hide()
tinsert(UISpecialFrames, "KeystonePercentileRunPopup")

local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

local popDetail = ns.NewRunDetail(popup, POP_W, { metaRight = 34, showGoal = true })

function ns.ShowRunPopup(run)
  popup:SetHeight(popDetail:Render(run))
  popup:Show()
end

function ns.ShowLastRun()
  local runs = ns.AllRuns()
  if runs[1] then ns.ShowRunPopup(runs[1])
  else print("|cff00ff96Keystone Percentile|r: " .. L["No runs recorded yet."]) end
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
local pending, retries, scheduled = false, 0, false

local function Finalize()
  scheduled = false
  if not pending then return end
  local map, level, timeMs, onTime, upgrades, newRating = CompletionInfo()
  if not map then pending = false return end

  local snap = MeterSnapshot()
  if (not snap or not snap.me) and retries < 5 then
    retries = retries + 1
    scheduled = true
    C_Timer.After(2, Finalize)
    return
  end
  pending, retries = false, 0

  local active = KP_DB.activeKey
  local base = active and active.map == map and active.snap or nil
  local dur = timeMs and timeMs / 1000 or nil
  local function PerSec(v) return (v and dur and dur > 0) and math.floor(v / dur + 0.5) or nil end

  local me, meBase = snap and snap.me, base and base.me
  local damage, healing = Diff(me, meBase, "damage"), Diff(me, meBase, "healing")
  local taken, avoidable = Diff(me, meBase, "taken"), Diff(me, meBase, "avoidable")
  local id = ns.GetPlayerIdentity()
  local _, classFile = UnitClass("player")

  local run = {
    t = GetServerTime(), season = KP_DATA.season, map = map, level = level,
    timed = onTime and true or false, upgrades = onTime and (upgrades or 1) or 0, dur = dur,
    dps = PerSec(damage), hps = PerSec(healing),
    deaths = Diff(me, meBase, "deaths"), interrupts = Diff(me, meBase, "interrupts"),
    avoidPct = (taken and taken > 0 and avoidable) and (avoidable / taken * 100) or nil,
    specID = id.specID, spec = id.specName, className = id.className, classFile = classFile,
    role = id.role == "healer" and "healer" or (id.role == "tank" and "tank" or "dps"),
    hero = id.hero, src = "live", approx = (base == nil) or nil,
    rating = (type(newRating) == "number" and not ns.IsSecret(newRating) and newRating > 0) and newRating or nil,
  }

  -- Group members (everyone but you who the meter saw)
  if snap then
    local group = {}
    for name, e in pairs(snap) do
      if name ~= "me" then
        local b = base and base[name]
        group[#group + 1] = {
          name = name, classFile = e.classFile, specID = SpecFromIcon(e.specIcon),
          dps = PerSec(Diff(e, b, "damage")), hps = PerSec(Diff(e, b, "healing")),
        }
      end
    end
    table.sort(group, function(a, b2) return (a.dps or 0) > (b2.dps or 0) end)
    if #group > 0 then run.group = group end
  end

  table.insert(ns.LiveRuns(), run)
  KP_DB.activeKey = nil
  if ns.OnRunRecorded then ns.OnRunRecorded(run) end
  if KP_DB.popup ~= false then ns.ShowRunPopup(run) end
end

local function TryFinalize()
  if scheduled then return end
  if InCombatLockdown() or UnitAffectingCombat("player") then return end -- PLAYER_REGEN_ENABLED retries
  scheduled = true
  C_Timer.After(1, Finalize)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHALLENGE_MODE_START")
ev:RegisterEvent("CHALLENGE_MODE_COMPLETED")
ev:RegisterEvent("CHALLENGE_MODE_RESET")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event)
  if event == "CHALLENGE_MODE_START" then
    local level = C_ChallengeMode.GetActiveKeystoneInfo and C_ChallengeMode.GetActiveKeystoneInfo()
    KP_DB.activeKey = {
      map = C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID(),
      level = level, start = GetServerTime(),
      snap = (not InCombatLockdown()) and MeterSnapshot() or nil,
    }
  elseif event == "CHALLENGE_MODE_RESET" then
    KP_DB.activeKey = nil
  elseif event == "CHALLENGE_MODE_COMPLETED" then
    pending, retries = true, 0
    TryFinalize()
  elseif event == "PLAYER_REGEN_ENABLED" and pending then
    TryFinalize()
  end
end)
