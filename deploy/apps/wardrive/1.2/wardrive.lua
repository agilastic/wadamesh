-- Wardrive v1.2 — LoRa coverage survey with live signal map.
--
-- How it works: every SWEEP_MS a zero-hop discovery probe goes out; every
-- node in earshot answers. Each reply proves the link works FROM WHERE YOU
-- STAND — listening-only can only tell you what happened to transmit while
-- you were there, which is a weaker claim. Each reply carries both link
-- directions: how well we heard them (snr) and how well they heard us
-- (their_snr). Asymmetry is the normal case and is the whole point.
--
-- Layout: GPS + status bar, then either a map track (if this board supports
-- it) or nothing above a node list sorted by best SNR with per-node asymmetry.
--
-- CSV columns: epoch,lat_e6,lon_e6,alt_m,pubkey,name,type,rssi,snr,their_snr,hops
-- (lat_e6/lon_e6 are exact integers; float lat/lon loses ~1 m of precision.)
local ui, sys, mesh, fs, timer = wada.ui, wada.sys, wada.mesh, wada.fs, wada.timer
local C = ui.colors
local app = {}

-- ── constants ────────────────────────────────────────────────────────────────
local SWEEP_MS   = 20000   -- ≥15 s probe floor enforced by firmware
local HARVEST_MS = 4000    -- replies arrive over ~4 s after a probe
local TYPE = { [1]="chat", [2]="rep", [3]="room", [4]="sensor" }

-- SNR thresholds for colour coding (dB)
local SNR_GOOD = 0      -- ≥ 0 dB  → green
local SNR_OK   = -10    -- ≥-10 dB → amber
                        -- < -10   → red

-- ── state ────────────────────────────────────────────────────────────────────
local run, running = "wd", false
local samples, sweeps, node_count = 0, 0, 0
local last_err = nil
local phase, phase_at = "idle", 0   -- "idle" | "probe" | "wait"
local nodes   = {}   -- pubkey -> { name, type, best, worst, their_snr, seen, rssi }
local pending = {}   -- write queue (filesystem allows 1 write/s)
local wrote_header = false
local track = {}     -- { lat, lon, snr } breadcrumb trail for the map

-- ── UI handles ───────────────────────────────────────────────────────────────
local map_obj = nil
local node_list = nil
local status_lbl, gps_lbl
local start_btn = nil

-- ── helpers ──────────────────────────────────────────────────────────────────
local function default_run_name()
  local dt = sys.datetime and sys.datetime()
  if dt then
    return string.format("wd_%04d%02d%02d_%02d%02d%02d",
      dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec)
  end
  local ep = sys.epoch and sys.epoch()
  if ep then return string.format("wd_%d", ep) end
  return "wd"
end

local function logname() return run .. ".csv" end

-- Safe UTF-8 prefix so fixed-width columns don't split a multi-byte codepoint.
local function utf8_trunc(text, max_bytes)
  local offset, last, len = 1, 0, #text
  while offset <= len and offset <= max_bytes do
    local b = text:byte(offset)
    local w = (b <= 0x7F and 1) or (b >= 0xC2 and b <= 0xDF and 2)
           or (b >= 0xE0 and b <= 0xEF and 3) or (b >= 0xF0 and b <= 0xF4 and 4) or 0
    if w == 0 or offset + w - 1 > len or offset + w - 1 > max_bytes then break end
    local ok = true
    for i = 2, w do
      local c = text:byte(offset + i - 1)
      if c < 0x80 or c > 0xBF then ok = false; break end
    end
    local b2 = w > 1 and text:byte(offset + 1) or 0
    if (b == 0xE0 and b2 < 0xA0) or (b == 0xED and b2 > 0x9F) or
       (b == 0xF0 and b2 < 0x90) or (b == 0xF4 and b2 > 0x8F) then ok = false end
    if not ok then break end
    last = offset + w - 1; offset = last + 1
  end
  return text:sub(1, last)
end

local function snr_color(snr)
  if snr >= SNR_GOOD then return C.good
  elseif snr >= SNR_OK  then return 0xC8A030   -- amber
  else                       return C.bad  end
end

-- ── CSV write queue ──────────────────────────────────────────────────────────
local HEADER = "epoch,lat_e6,lon_e6,alt_m,pubkey,name,type,rssi,snr,their_snr,hops"

local function flush()
  if #pending == 0 then return end
  local chunk = table.concat(pending, "\n") .. "\n"
  if not wrote_header then chunk = HEADER .. "\n" .. chunk end
  if fs.append(logname(), chunk) then
    pending, wrote_header = {}, true
  end
end

local function record(fix, hit)
  local key = hit.pubkey
  local n = nodes[key]
  if not n then
    n = { name = hit.name or key:sub(1,8), type = hit.type,
          best = hit.snr, worst = hit.snr,
          their_snr = hit.their_snr, rssi = hit.rssi, seen = 0 }
    nodes[key] = n
    node_count = node_count + 1
  else
    if hit.snr  > n.best  then n.best  = hit.snr  end
    if hit.snr  < n.worst then n.worst = hit.snr  end
    n.their_snr = hit.their_snr   -- keep most recent
    n.rssi      = hit.rssi
    if hit.name then n.name = hit.name end
  end
  n.seen = n.seen + 1
  samples = samples + 1
  pending[#pending + 1] = string.format("%d,%d,%d,%d,%s,%s,%d,%d,%.2f,%.2f,%d",
    fix.time or sys.epoch(), fix.lat_e6, fix.lon_e6, fix.alt_m or 0,
    key, (hit.name or ""):gsub(",", " "), hit.type,
    hit.rssi, hit.snr, hit.their_snr, hit.hops)
end

-- ── probe / harvest ──────────────────────────────────────────────────────────
local function do_sweep()
  local ok, err = mesh.discover()
  if not ok then last_err = err; return false end
  last_err = nil; sweeps = sweeps + 1; return true
end

local function do_harvest()
  local fix = sys.gps()
  if not fix then mesh.discover_clear(); return end   -- no fix → discard (no Null Island points)
  local best_snr = nil
  for _, hit in ipairs(mesh.discovered()) do
    record(fix, hit)
    if not best_snr or hit.snr > best_snr then best_snr = hit.snr end
  end
  mesh.discover_clear()
  if fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0 then
    track[#track + 1] = { lat = fix.lat_e6 / 1e6, lon = fix.lon_e6 / 1e6,
                          snr = best_snr }   -- nil snr = no reply this sweep
  end
end

-- ── map overlay ──────────────────────────────────────────────────────────────
local function redraw_map()
  if not map_obj then return end
  map_obj:clear()
  local fix = sys.gps()
  if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
    map_obj:center(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6)
  end
  for i = 2, #track do
    local a, b = track[i-1], track[i]
    local col = b.snr and snr_color(b.snr) or 0x444C54
    map_obj:line(a.lat, a.lon, b.lat, b.lon, col, 3)
  end
  if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
    map_obj:marker(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6, C.accent, 6)
  end
  map_obj:redraw()
end

-- ── node list ────────────────────────────────────────────────────────────────
local function redraw_nodes()
  if not node_list then return end
  node_list:clear()
  local list = {}
  for key, n in pairs(nodes) do list[#list + 1] = { key = key, n = n } end
  table.sort(list, function(a, b) return a.n.best > b.n.best end)
  if #list == 0 then
    node_list:add("(no replies yet)", 0, C.sub)
    return
  end
  for _, e in ipairs(list) do
    local n = e.n
    -- ↓ = they heard us (their_snr), ↑ = we heard them (best)
    local label = string.format("%-10s %-6s  \xe2\x86\x93%+5.1f  \xe2\x86\x91%+5.1f  \xc3\x97%d",
      utf8_trunc(n.name, 10), TYPE[n.type] or "?",
      n.their_snr, n.best, n.seen)
    node_list:add(label, 0, snr_color(n.best))
  end
end

-- ── status bar ───────────────────────────────────────────────────────────────
local function redraw_status()
  local fix = sys.gps()
  if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
    gps_lbl:set(string.format("%.5f %.5f  %dm  %dsat",
      fix.lat_e6 / 1e6, fix.lon_e6 / 1e6, fix.alt_m or 0, fix.sats or 0))
    gps_lbl:color(C.good)
  else
    gps_lbl:set("no GPS fix \xe2\x80\x94 samples discarded until locked")
    gps_lbl:color(C.bad)
  end

  local state_str
  if not running then
    state_str = "stopped"
  elseif phase == "probe" then
    state_str = "listening\xe2\x80\xa6"
  else
    local remaining = math.max(0, SWEEP_MS - (sys.millis() - phase_at))
    state_str = string.format("next probe %ds", math.ceil(remaining / 1000))
  end

  status_lbl:set(string.format("%s  \xe2\x80\xa2  %d sweeps  %d samples  %d nodes%s",
    state_str, sweeps, samples, node_count,
    last_err and ("  [\xe2\x9a\xa0 " .. last_err .. "]") or ""))
  status_lbl:color(last_err and C.bad or (running and C.accent or C.sub))
end

-- ── on_open ──────────────────────────────────────────────────────────────────
function app.on_open(w, h)
  if not sys.caps().discover then
    ui.label("This board does not support discovery probes.", 6, 8, 12, C.bad)
    return
  end
  run = default_run_name()
  ui.scroll(false)

  local LH = ui.text_h(12)
  local y = 2

  gps_lbl = ui.label("", 4, y, 12, C.sub); gps_lbl:width(w - 8)
  y = y + LH + 2

  status_lbl = ui.label("", 4, y, 12, C.sub); status_lbl:width(w - 8)
  y = y + LH + 4

  -- control row: Start/Stop · Name · Reset
  local bw = math.min(80, (w - 16) // 3)
  start_btn = ui.button("Start", 4, y, bw, 28, function()
    running = not running
    if running then phase, phase_at = "idle", 0 end
    start_btn:set(running and "Stop" or "Start")
    sys.toast(running and "Survey running" or "Survey stopped", 1000)
  end)
  ui.button("Name", 8 + bw, y, bw, 28, function()
    ui.input("Name this run", run, function(text)
      if text and text ~= "" then
        run = text:gsub("[^%w%-_]", "_")
        wrote_header = false
        sys.toast("Logging to " .. logname(), 1500)
      end
    end)
  end)
  ui.button("Reset", 12 + bw * 2, y, bw, 28, function()
    nodes, samples, sweeps, pending, node_count = {}, 0, 0, {}, 0
    track = {}
    mesh.discover_clear()
    fs.remove(logname())
    wrote_header = false
    run = default_run_name()
    sys.toast("Cleared \xe2\x80\x94 new run: " .. run, 1500)
    redraw_nodes()
    if map_obj then map_obj:clear(); map_obj:redraw() end
  end)
  y = y + 32

  -- map (top portion, boards that support it)
  local has_map = sys.caps().map
  local map_h = has_map and math.floor((h - y) * 0.45) or 0
  if has_map then
    map_obj = wada.map.view(4, y, w - 8, map_h)
    local fix = sys.gps()
    if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
      map_obj:center(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6, 13)
    else
      map_obj:zoom(13)
    end
    y = y + map_h + 4
  end

  -- node list (remainder of height)
  node_list = ui.list(4, y, w - 8, h - y - 2, function(_idx) end)

  redraw_status()
  redraw_nodes()
  timer.every(1000)
end

-- ── on_tick (1 Hz) ───────────────────────────────────────────────────────────
function app.on_tick()
  if running then
    local now = sys.millis()
    if phase == "idle" or (phase == "wait" and now - phase_at >= SWEEP_MS) then
      phase, phase_at = do_sweep() and "probe" or "wait", now
    elseif phase == "probe" and now - phase_at >= HARVEST_MS then
      do_harvest()
      phase = "wait"   -- phase_at stays at probe time → cadence stays on schedule
      redraw_map()
      redraw_nodes()
    end
  end
  flush()
  redraw_status()
  -- Keep position dot moving on the map even between sweeps
  if map_obj then
    local fix = sys.gps()
    if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
      map_obj:center(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6)
      map_obj:redraw()
    end
  end
end

function app.on_close()
  flush()
  if map_obj then map_obj:close() end
end

return app
