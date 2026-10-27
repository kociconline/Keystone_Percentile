-- Keystone Percentile: records every key (damage, healing, deaths, avoidable damage,
-- interrupts, and the same for your group) and ranks it against Warcraft Logs
-- benchmarks for the spec, dungeon and key level. Healers are ranked on HPS.
local ADDON, ns = ...
local L = ns.L

local ANCHORS = { 1, 10, 50 } -- benchmark keys p1, p10, p50 (median); #1 is "top"

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
      return i.mapChallengeModeID, i.level, i.time, i.onTime, i.keystoneUpgradeLevels
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
  -- Exact level first, then the nearest level within 3; at each distance your
  -- personal benchmarks (fetched for your own dungeons) win over the shared ones.
  if not level then return nil end
  local mine, shared = BenchTable(KP_PERSONAL, map, specID), BenchTable(KP_DATA, map, specID)
  for d = 0, 3 do
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
  local result = run.timed == true and string.format(L["Timed +%d"], run.upgrades or 1)
    or run.timed == false and L["Over time"] or nil
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
-- End-of-key pop-up
---------------------------------------------------------------------------
local BAR_W, PAD = 340, 14
local popup = CreateFrame("Frame", "KeystonePercentileRunPopup", UIParent, "BackdropTemplate")
popup:SetSize(BAR_W + 2 * PAD + 6, 300)
popup:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
popup:SetFrameStrata("DIALOG")
popup:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
popup:SetBackdropColor(0, 0, 0, 0.85)
popup:SetBackdropBorderColor(0, 0, 0, 1)
popup:SetMovable(true); popup:EnableMouse(true); popup:RegisterForDrag("LeftButton")
popup:SetClampedToScreen(true)
popup:SetScript("OnDragStart", popup.StartMoving)
popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
popup:Hide()
tinsert(UISpecialFrames, "KeystonePercentileRunPopup")

local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

local function FS(font, justify)
  local f = popup:CreateFontString(nil, "OVERLAY", font)
  f:SetJustifyH(justify or "LEFT")
  return f
end

popup.title = FS("GameFontNormalLarge")
popup.result = FS("GameFontHighlightSmall", "RIGHT")
popup.spec = FS("GameFontHighlight")
popup.amount = FS("GameFontHighlightHuge")
popup.amountLabel = FS("GameFontDisableSmall")
popup.top = FS("GameFontNormalLarge", "RIGHT")
popup.sub = FS("GameFontDisableSmall")
popup.why = FS("GameFontHighlightSmall")
popup.groupTitle = FS("GameFontNormal")
popup.footer = FS("GameFontDisableSmall")
popup.goal = FS("GameFontHighlight")

popup.barBG = popup:CreateTexture(nil, "ARTWORK")
popup.barBG:SetColorTexture(0.17, 0.19, 0.23, 1)
popup.barBG:SetSize(BAR_W, 8)
popup.bar = popup:CreateTexture(nil, "ARTWORK", nil, 1)
popup.bar:SetHeight(8)
popup.you = FS("GameFontHighlightSmall", "CENTER")
popup.you:SetText(L["you"])
popup.markers = {}
for i = 1, 6 do
  popup.markers[i] = { tex = popup:CreateTexture(nil, "OVERLAY"), label = FS("GameFontDisableSmall", "CENTER") }
  popup.markers[i].tex:SetSize(1, 16)
end

popup.goals = {}
for i = 1, 4 do popup.goals[i] = { FS("GameFontNormal"), FS("GameFontDisable"), FS("GameFontNormal", "RIGHT") } end
popup.members = {}
for i = 1, 5 do popup.members[i] = { FS("GameFontHighlightSmall"), FS("GameFontDisableSmall", "RIGHT"), FS("GameFontHighlightSmall", "RIGHT") } end

local share = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
share:SetSize(70, 20)
share:SetText(L["Share"])
share:SetPoint("BOTTOMRIGHT", -10, 8)
share:RegisterForClicks("LeftButtonUp")
share:SetScript("OnClick", function() if popup.run then ns.ShareRun(popup.run, IsShiftKeyDown()) end end)
share:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(L["Share"])
  GameTooltip:AddLine(L["Click: group chat. Shift-click: guild chat."], 1, 1, 1, true)
  GameTooltip:Show()
end)
share:SetScript("OnLeave", GameTooltip_Hide)

local function Place(fs, x, y, point)
  fs:ClearAllPoints()
  fs:SetPoint(point or "TOPLEFT", popup, point or "TOPLEFT", x, y)
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

function ns.ShowRunPopup(run)
  popup.run = run
  local ev = ns.EvaluateRun(run)
  local y = -12

  popup.title:SetText(string.format("%s +%s", ns.DungeonName(run), run.level or "?"))
  Place(popup.title, PAD, y)
  if run.timed == true then
    popup.result:SetText(string.format("|cff1eff00%s|r |cff999999· %s|r", string.format(L["Timed +%d"], run.upgrades or 1), FormatTime(run.dur)))
  elseif run.timed == false then
    popup.result:SetText(string.format("|cffff5555%s|r |cff999999· %s|r", L["Over time"], FormatTime(run.dur)))
  else
    popup.result:SetText(run.dur and ("|cff999999" .. FormatTime(run.dur) .. "|r") or "")
  end
  Place(popup.result, -30, y - 3, "TOPRIGHT")
  y = y - 20

  local spec = (run.spec or "") .. (run.className and (" " .. run.className) or "")
  if run.hero then spec = spec .. " · " .. run.hero end
  popup.spec:SetText(string.format("|c%s%s|r", ClassColor(run.classFile), spec))
  Place(popup.spec, PAD, y)
  y = y - 24

  popup.amount:SetText(FormatAmount(ev.amount))
  Place(popup.amount, PAD, y)
  popup.amountLabel:SetText(AmountLabel(ev.metric, ev.role) .. (run.approx and (" (" .. L["approx."] .. ")") or ""))
  popup.amountLabel:ClearAllPoints()
  popup.amountLabel:SetPoint("BOTTOMLEFT", popup.amount, "BOTTOMRIGHT", 6, 3)
  popup.amountLabel:Show()
  popup.top:SetText(ns.TopText(ev))
  Place(popup.top, -PAD, y - 2, "TOPRIGHT")
  y = y - 26

  local b = ev.bench
  if ev.amount == nil then
    popup.sub:SetText("|cffff5555" .. L["Couldn't read your damage for this run."] .. "|r")
  elseif ev.exact then
    local n = ev.metric == "hps" and run.hn or run.n
    if n and run.level then
      popup.sub:SetText(string.format(L["of %s logged %s runs at +%d"], ns.Num(n),
        (spec:match("^[^·]+") or ""):gsub("%s+$", ""), run.level))
    else
      popup.sub:SetText(L["Official Warcraft Logs rank for this run"])
    end
  elseif b then
    popup.sub:SetText(string.format(L["of %s logged %s runs at +%d"], ns.Num(b.n or 0), (spec:match("^[^·]+") or ""):gsub("%s+$", ""), ev.benchLevel))
  else
    popup.sub:SetText(L["No Warcraft Logs benchmark for this spec and key level yet."])
  end
  Place(popup.sub, PAD, y)
  y = y - 18

  -- Bar: 0 .. #1, with markers at each percentile
  for _, m in ipairs(popup.markers) do m.tex:Hide(); m.label:Hide() end
  if b and b.top and b.top > 0 and ev.amount then
    y = y - 14
    popup.barBG:ClearAllPoints(); popup.barBG:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD + 3, y); popup.barBG:Show()
    local frac = math.min(ev.amount / b.top, 1)
    popup.bar:ClearAllPoints(); popup.bar:SetPoint("TOPLEFT", popup.barBG, "TOPLEFT")
    popup.bar:SetWidth(math.max(1, frac * BAR_W))
    popup.bar:SetColorTexture(HexToRGB(ns.PctColor(ev.top or 100))); popup.bar:Show()
    popup.you:ClearAllPoints(); popup.you:SetPoint("BOTTOM", popup.barBG, "TOPLEFT", frac * BAR_W, 3); popup.you:Show()
    local lastX = -100
    for i, a in ipairs({ 50, 10, 1 }) do
      local v = b["p" .. a]
      if v then
        local x = math.min(v / b.top, 1) * BAR_W
        local mk = popup.markers[i]
        mk.tex:SetColorTexture(HexToRGB(ns.PctColor(a)))
        mk.tex:ClearAllPoints(); mk.tex:SetPoint("TOP", popup.barBG, "TOPLEFT", x, 4); mk.tex:Show()
        if x - lastX > 24 then
          mk.label:SetText(a == 50 and L["median"] or (a .. "%")); mk.label:ClearAllPoints()
          mk.label:SetPoint("TOP", popup.barBG, "BOTTOMLEFT", x, -4); mk.label:Show()
          lastX = x
        end
      end
    end
    local mk = popup.markers[6]
    mk.tex:SetColorTexture(0.9, 0.8, 0.5, 1)
    mk.tex:ClearAllPoints(); mk.tex:SetPoint("TOP", popup.barBG, "TOPRIGHT", 0, 4); mk.tex:Show()
    mk.label:SetText("#1"); mk.label:ClearAllPoints()
    mk.label:SetPoint("TOPRIGHT", popup.barBG, "BOTTOMRIGHT", 0, -4); mk.label:Show()
    y = y - 32
  else
    popup.barBG:Hide(); popup.bar:Hide(); popup.you:Hide()
  end

  -- Goals
  local goals = {}
  if b and ev.amount then
    for _, a in ipairs({ 50, 10, 1 }) do
      local v = b["p" .. a]
      if v then
        local gap = v - ev.amount
        local label = a == 50 and L["Median"] or string.format(L["Top %s"], a .. "%")
        local diff
        if a == 50 then
          diff = gap > 0 and ("|cffff8080-" .. FormatAmount(gap) .. "|r")
            or ("|cff1eff00+" .. FormatAmount(-gap) .. "|r")
        else
          diff = gap > 0 and ("+" .. FormatAmount(gap)) or ("|cff1eff00" .. L["reached"] .. "|r")
        end
        goals[#goals + 1] = { label, FormatAmount(v), diff }
      end
    end
    if b.top then
      goals[#goals + 1] = { "#1", FormatAmount(b.top), string.format(L["you're at %d%%"], math.floor((ev.ofTop or 0) * 100 + 0.5)) }
    end
  end
  for i, g in ipairs(popup.goals) do
    local row = goals[i]
    if row then
      g[1]:SetText(row[1]); Place(g[1], PAD, y)
      g[2]:SetText(row[2]); Place(g[2], PAD + 80, y)
      g[3]:SetText(row[3]); Place(g[3], -PAD, y, "TOPRIGHT")
      y = y - 17
    else
      for c = 1, 3 do g[c]:Hide() end
    end
  end

  -- Why: deaths, avoidable damage, interrupts
  local why = WhyText(run)
  if why then
    y = y - 6
    popup.why:SetText(why); popup.why:SetWidth(BAR_W + 6); Place(popup.why, PAD, y)
    y = y - popup.why:GetStringHeight() - 2
  else
    popup.why:Hide()
  end

  -- Whole group, each against their own spec
  local members = run.group or {}
  if #members > 0 and KP_DB.groupRanks ~= false then
    y = y - 10
    popup.groupTitle:SetText(L["Your group"]); Place(popup.groupTitle, PAD, y)
    y = y - 17
    for i, row in ipairs(popup.members) do
      local m = members[i]
      if m then
        local info = ns.SpecInfo(m.specID)
        local metric = (info and info.role == "healer") and "hps" or "dps"
        local mev = ns.Rank(run.map, m.specID, run.level, metric, m[metric])
        local label = string.format("|c%s%s|r |cff999999%s|r", ClassColor(m.classFile), m.name or "?", info and info.name or "")
        row[1]:SetText(label); Place(row[1], PAD, y)
        row[2]:SetText(FormatAmount(m[metric]) .. " " .. (metric == "hps" and "HPS" or "DPS")); Place(row[2], -110, y, "TOPRIGHT")
        row[3]:SetText(ns.TopText(mev)); Place(row[3], -PAD, y, "TOPRIGHT")
        y = y - 15
      else
        for c = 1, 3 do row[c]:Hide() end
      end
    end
  else
    popup.groupTitle:Hide()
    for _, row in ipairs(popup.members) do for c = 1, 3 do row[c]:Hide() end end
  end

  local foot
  if ev.exact and run.report then
    foot = "Warcraft Logs · " .. run.report
  elseif b then
    foot = L["Warcraft Logs benchmarks"] .. " · " .. (KP_DATA.updatedAt or "")
    if ev.benchLevel ~= run.level then foot = foot .. " · " .. string.format(L["using +%d data"], ev.benchLevel) end
  else
    foot = run.src == "logs" and L["Imported from Warcraft Logs"] or L["Recorded in game"]
  end
  -- Your next goal, only for the key you just finished
  local live = ns.LiveRuns()
  local goal = (run.src == "live" and live[#live] == run and ns.GoalLine) and ns.GoalLine() or nil
  if goal then
    y = y - 10
    popup.goal:SetText(goal); Place(popup.goal, PAD, y)
    y = y - 16
  else
    popup.goal:Hide()
  end

  popup.footer:SetText(foot)
  popup.footer:SetWidth(BAR_W - 70)
  y = y - 10
  Place(popup.footer, PAD, y)
  popup:SetHeight(-y + 34)
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
  local map, level, timeMs, onTime, upgrades = CompletionInfo()
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
