-- M+ Percentile: records your DPS for every key and ranks it against
-- Warcraft Logs benchmarks for your spec, dungeon and key level.
local ADDON, ns = ...

local ANCHORS = { 1, 10, 25, 50, 75 } -- benchmark keys p1, p10, ...

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
local function FormatDPS(v)
  if not v then return "—" end
  if v >= 1e6 then return string.format("%.2fM", v / 1e6) end
  if v >= 1e3 then return string.format("%.1fk", v / 1e3) end
  return string.format("%d", v)
end
ns.FormatDPS = FormatDPS

local function FormatTime(sec)
  if not sec then return "" end
  return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end
ns.FormatTime = FormatTime

local function ClassColor(classFile)
  local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  return c and c.colorStr or "ffffffff"
end

function ns.DungeonName(run)
  if run.map and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
    local name = C_ChallengeMode.GetMapUIInfo(run.map)
    if name then return name end
  end
  if run.map and MPP_DATA.dungeons and MPP_DATA.dungeons[run.map] then return MPP_DATA.dungeons[run.map] end
  return run.dungeon or "Unknown dungeon"
end

---------------------------------------------------------------------------
-- Reading your damage from the game's built-in damage meter.
-- Values are secret during combat, so this is only called out of combat.
---------------------------------------------------------------------------
local function PlayerDamageTotal()
  if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum.DamageMeterSessionType) then
    return nil
  end
  local ok, total = pcall(function()
    local session = C_DamageMeter.GetCombatSessionFromType(
      Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageDone)
    if not session or ns.IsSecret(session) then return nil end
    for _, src in ipairs(session.combatSources or {}) do
      if src.isLocalPlayer then
        local v = src.totalAmount
        if v == nil or ns.IsSecret(v) then return nil end
        return v
      end
    end
    return 0
  end)
  if ok then return total end
end

local function CompletionInfo()
  if C_ChallengeMode.GetChallengeCompletionInfo then
    local ok, i = pcall(C_ChallengeMode.GetChallengeCompletionInfo)
    if ok and i and i.mapChallengeModeID then
      return i.mapChallengeModeID, i.level, i.time, i.onTime, i.keystoneUpgradeLevels
    end
  end
  if C_ChallengeMode.GetCompletionInfo then
    local map, level, time, onTime, upgrades = C_ChallengeMode.GetCompletionInfo()
    return map, level, time, onTime, upgrades
  end
end

---------------------------------------------------------------------------
-- Benchmarks and ranking
---------------------------------------------------------------------------
-- Benchmark for this dungeon/spec/level, or the nearest level within 3.
function ns.Benchmark(map, specID, level)
  local t = MPP_DATA.dps and map and MPP_DATA.dps[map]
  t = t and specID and t[specID]
  if not t or not level then return nil end
  if t[level] then return t[level], level end
  for d = 1, 3 do
    if t[level - d] then return t[level - d], level - d end
    if t[level + d] then return t[level + d], level + d end
  end
end

local function Anchors(b)
  local list = {}
  if b.top and b.n and b.n > 0 then list[#list + 1] = { pct = math.max(100 / b.n, 0.01), v = b.top } end
  for _, a in ipairs(ANCHORS) do
    local v = b["p" .. a]
    if v and (#list == 0 or v < list[#list].v) then list[#list + 1] = { pct = a, v = v } end
  end
  return list -- best first
end

-- Top X% for a DPS value against a benchmark.
local function EstimateTop(dps, b)
  local c = Anchors(b)
  if #c == 0 then return nil end
  if dps >= c[1].v then return c[1].pct end
  for i = 1, #c - 1 do
    local hi, lo = c[i], c[i + 1]
    if dps >= lo.v then
      if hi.v == lo.v then return lo.pct end
      local t = (dps - lo.v) / (hi.v - lo.v)
      return math.exp(math.log(lo.pct) + t * (math.log(hi.pct) - math.log(lo.pct)))
    end
  end
  local last = c[#c]
  if dps <= 0 or last.v <= 0 then return 100 end
  return last.pct + (100 - last.pct) * (1 - dps / last.v)
end

-- Everything the pop-up and history need about one run.
function ns.EvaluateRun(run)
  local ev = {}
  local b, bLevel = ns.Benchmark(run.map, run.specID, run.level)
  ev.bench, ev.benchLevel = b, bLevel
  if run.pct then -- official Warcraft Logs percentile (higher is better)
    ev.top, ev.exact = math.max(100 - run.pct, 0.1), true
  elseif b and run.dps then
    ev.top = EstimateTop(run.dps, b)
  end
  if b and b.top and run.dps and b.top > 0 then ev.ofTop = run.dps / b.top end
  return ev
end

function ns.TopText(ev)
  if not ev or not ev.top then return "|cff777777—|r" end
  return string.format("|c%s%sTop %s|r", ns.PctColor(ev.top), ev.exact and "" or "~", ns.FormatPct(ev.top))
end

---------------------------------------------------------------------------
-- Run storage
---------------------------------------------------------------------------
local function MyKey() return ns.Key(UnitName("player"), GetRealmName()) end

function ns.LiveRuns(key)
  MPP_RUNS = MPP_RUNS or {}
  key = key or MyKey()
  MPP_RUNS[key] = MPP_RUNS[key] or {}
  return MPP_RUNS[key]
end

-- Live runs merged with runs imported from Warcraft Logs. A run that was
-- recorded live and also uploaded appears once, with the official rank.
function ns.AllRuns(key)
  key = key or MyKey()
  local out, used = {}, {}
  local imported = (MPP_DATA.imported and MPP_DATA.imported[key]) or {}
  for _, live in ipairs(ns.LiveRuns(key)) do
    local r = {}
    for k, v in pairs(live) do r[k] = v end
    for i, imp in ipairs(imported) do
      if not used[i] and imp.level == live.level
        and ((imp.map and imp.map == live.map) or (not imp.map and imp.dungeon == ns.DungeonName(live)))
        and math.abs((imp.t or 0) - (live.t or 0)) < 3 * 3600 then
        used[i] = true
        r.pct, r.report, r.src = imp.pct, imp.report, "both"
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

---------------------------------------------------------------------------
-- End-of-key pop-up
---------------------------------------------------------------------------
local BAR_W = 320
local popup = CreateFrame("Frame", "MPlusPercentileRunPopup", UIParent, "BackdropTemplate")
popup:SetSize(BAR_W + 40, 220)
popup:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
popup:SetFrameStrata("DIALOG")
popup:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
popup:SetBackdropColor(0, 0, 0, 0.82)
popup:SetBackdropBorderColor(0, 0, 0, 1)
popup:SetMovable(true); popup:EnableMouse(true); popup:RegisterForDrag("LeftButton")
popup:SetClampedToScreen(true)
popup:SetScript("OnDragStart", popup.StartMoving)
popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
popup:Hide()
tinsert(UISpecialFrames, "MPlusPercentileRunPopup")

local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

local function FS(font, ...)
  local f = popup:CreateFontString(nil, "OVERLAY", font)
  f:SetPoint(...)
  f:SetJustifyH("LEFT")
  return f
end

popup.title = FS("GameFontNormalLarge", "TOPLEFT", 14, -12)
popup.result = FS("GameFontHighlightSmall", "TOPRIGHT", -30, -15)
popup.spec = FS("GameFontHighlight", "TOPLEFT", 14, -32)
popup.dps = FS("GameFontHighlightHuge", "TOPLEFT", 14, -56)
popup.dpsLabel = FS("GameFontDisableSmall", "BOTTOMLEFT", popup.dps, "BOTTOMRIGHT", 6, 3)
popup.top = FS("GameFontNormalLarge", "TOPRIGHT", -16, -58)
popup.sub = FS("GameFontDisableSmall", "TOPLEFT", 14, -82)

popup.barBG = popup:CreateTexture(nil, "ARTWORK")
popup.barBG:SetColorTexture(0.17, 0.19, 0.23, 1)
popup.barBG:SetSize(BAR_W, 8)
popup.barBG:SetPoint("TOPLEFT", 20, -114)
popup.bar = popup:CreateTexture(nil, "ARTWORK", nil, 1)
popup.bar:SetPoint("TOPLEFT", popup.barBG, "TOPLEFT")
popup.bar:SetHeight(8)
popup.you = FS("GameFontHighlightSmall", "BOTTOM", popup.barBG, "TOPLEFT", 0, 3)
popup.you:SetText("you")

popup.markers = {}
for i = 1, 6 do
  local t = popup:CreateTexture(nil, "OVERLAY")
  t:SetSize(1, 16)
  local l = popup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  popup.markers[i] = { tex = t, label = l }
end

popup.rows = {}
for i = 1, 3 do
  popup.rows[i] = {
    FS("GameFontNormal", "TOPLEFT", 14, -150 - (i - 1) * 17),
    FS("GameFontDisable", "TOPLEFT", 90, -150 - (i - 1) * 17),
    FS("GameFontNormal", "TOPRIGHT", -16, -150 - (i - 1) * 17),
  }
  popup.rows[i][3]:SetJustifyH("RIGHT")
end
popup.footer = FS("GameFontDisableSmall", "BOTTOMLEFT", 14, 10)

local function HexToRGB(hex)
  return tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, tonumber(hex:sub(7, 8), 16) / 255
end

function ns.ShowRunPopup(run)
  local ev = ns.EvaluateRun(run)
  popup.title:SetText(string.format("%s +%s", ns.DungeonName(run), run.level or "?"))

  if run.timed == true then
    popup.result:SetText(string.format("|cff1eff00Timed +%d|r |cff999999· %s|r", run.upgrades or 1, FormatTime(run.dur)))
  elseif run.timed == false then
    popup.result:SetText(string.format("|cffff5555Over time|r |cff999999· %s|r", FormatTime(run.dur)))
  else
    popup.result:SetText(run.dur and ("|cff999999" .. FormatTime(run.dur) .. "|r") or "")
  end

  local spec = (run.spec or "") .. (run.className and (" " .. run.className) or "")
  if run.hero then spec = spec .. " · " .. run.hero end
  popup.spec:SetText(string.format("|c%s%s|r", ClassColor(run.classFile), spec))

  popup.dps:SetText(FormatDPS(run.dps))
  popup.dpsLabel:SetText(run.approx and "your DPS (approx.)" or "your DPS")
  popup.top:SetText(ns.TopText(ev))

  local b = ev.bench
  if run.dps == nil then
    popup.sub:SetText("|cffff5555Couldn't read your damage for this run.|r")
  elseif ev.exact then
    popup.sub:SetText("Official Warcraft Logs rank for this run")
  elseif b then
    popup.sub:SetText(string.format("of %s logged %s%s runs at +%d", ns.Num(b.n or 0), run.spec or "",
      run.className and (" " .. run.className) or "", ev.benchLevel))
  else
    popup.sub:SetText("No Warcraft Logs benchmark for this spec and key level yet.")
  end

  -- Bar: 0 .. #1 DPS, with markers at each percentile.
  local showBar = b and b.top and b.top > 0 and run.dps
  for _, m in ipairs(popup.markers) do m.tex:Hide(); m.label:Hide() end
  if showBar then
    popup.barBG:Show(); popup.bar:Show(); popup.you:Show()
    local frac = math.min(run.dps / b.top, 1)
    popup.bar:SetWidth(math.max(1, frac * BAR_W))
    popup.bar:SetColorTexture(HexToRGB(ns.PctColor(ev.top or 100)))
    popup.you:ClearAllPoints()
    popup.you:SetPoint("BOTTOM", popup.barBG, "TOPLEFT", frac * BAR_W, 3)

    local marks = { { 50, "50%" }, { 25, "25%" }, { 10, "10%" }, { 1, "1%" } }
    local lastX = -100
    for i, m in ipairs(marks) do
      local v = b["p" .. m[1]]
      if v then
        local x = math.min(v / b.top, 1) * BAR_W
        local mk = popup.markers[i]
        mk.tex:SetColorTexture(HexToRGB(ns.PctColor(m[1])))
        mk.tex:ClearAllPoints(); mk.tex:SetPoint("TOP", popup.barBG, "TOPLEFT", x, 4); mk.tex:Show()
        if x - lastX > 24 then
          mk.label:SetText(m[2]); mk.label:ClearAllPoints()
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
  else
    popup.barBG:Hide(); popup.bar:Hide(); popup.you:Hide()
  end

  -- Goal rows
  local rows = {}
  if b and run.dps then
    for _, a in ipairs({ 10, 1 }) do
      local v = b["p" .. a]
      if v then
        local gap = v - run.dps
        rows[#rows + 1] = { "Top " .. a .. "%", FormatDPS(v),
          gap > 0 and ("+" .. FormatDPS(gap)) or "|cff1eff00reached|r" }
      end
    end
    if b.top then
      rows[#rows + 1] = { "#1", FormatDPS(b.top), string.format("you're at %d%%", math.floor((ev.ofTop or 0) * 100 + 0.5)) }
    end
  end
  for i, fs in ipairs(popup.rows) do
    local r = rows[i]
    for c = 1, 3 do fs[c]:SetText(r and r[c] or "") end
  end

  local foot
  if ev.exact and run.report then
    foot = "Warcraft Logs report " .. run.report
  elseif b then
    foot = "Warcraft Logs benchmarks · " .. (MPP_DATA.updatedAt or "")
    if ev.benchLevel ~= run.level then foot = foot .. string.format(" · using +%d data", ev.benchLevel) end
  else
    foot = run.src == "logs" and "Imported from Warcraft Logs" or "Recorded in game"
  end
  popup.footer:SetText(foot)

  local h = 150 + #rows * 17 + 30
  if not showBar then h = h - 30 end
  popup:SetHeight(math.max(h, 130))
  popup:Show()
end

function ns.ShowLastRun()
  local runs = ns.AllRuns()
  if runs[1] then ns.ShowRunPopup(runs[1])
  else print("|cff00ff96M+ Percentile|r: no runs recorded yet.") end
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

  local total = PlayerDamageTotal()
  if total == nil and retries < 5 then
    retries = retries + 1
    scheduled = true
    C_Timer.After(2, Finalize)
    return
  end
  pending, retries = false, 0

  local active = MPP_DB.activeKey
  local base = active and active.map == map and active.base or nil
  local dmg = total
  if total and base and total >= base then dmg = total - base end
  local dur = timeMs and timeMs / 1000 or nil
  local id = ns.GetPlayerIdentity()
  local _, classFile = UnitClass("player")

  local run = {
    t = GetServerTime(), season = MPP_DATA.season, map = map, level = level,
    timed = onTime and true or false, upgrades = onTime and (upgrades or 1) or 0, dur = dur,
    dps = (dmg and dur and dur > 0) and math.floor(dmg / dur + 0.5) or nil,
    specID = id.specID, spec = id.specName, className = id.className, classFile = classFile,
    hero = id.hero, src = "live", approx = (base == nil) or nil,
  }
  table.insert(ns.LiveRuns(), run)
  MPP_DB.activeKey = nil
  if MPP_DB.popup ~= false then ns.ShowRunPopup(run) end
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
    MPP_DB.activeKey = {
      map = C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID(),
      level = level, start = GetServerTime(),
      base = (not InCombatLockdown()) and PlayerDamageTotal() or nil,
    }
  elseif event == "CHALLENGE_MODE_RESET" then
    MPP_DB.activeKey = nil
  elseif event == "CHALLENGE_MODE_COMPLETED" then
    pending, retries = true, 0
    TryFinalize()
  elseif event == "PLAYER_REGEN_ENABLED" and pending then
    TryFinalize()
  end
end)
