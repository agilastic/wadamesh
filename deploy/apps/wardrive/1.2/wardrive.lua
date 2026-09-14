-- Wardrive v1.2 — LoRa coverage survey with live signal map.
--
-- Two views, tap the tab bar to switch:
--   MAP   — full-screen track coloured by best SNR. Green ≥0 dB, amber ≥-10,
--            red <-10. Current position shown as a dot.
--   NODES — node table sorted by best SNR with per-node SNR asymmetry.
--            ↓ = they heard us (their_snr), ↑ = we heard them (best SNR).
--
-- Each view rebuilds via ui.clear() on switch; stale handles become no-ops
-- (generation-tagged by the SDK). Map is closed before clear to release it.
--
-- CSV columns: epoch,lat_e6,lon_e6,alt_m,pubkey,name,type,rssi,snr,their_snr,hops
local ui, sys, mesh, fs, timer = wada.ui, wada.sys, wada.mesh, wada.fs, wada.timer
local C = ui.colors
local app = {}

-- ── constants ────────────────────────────────────────────────────────────────
local SWEEP_MS   = 20000   -- ≥15 s probe floor enforced by firmware
local HARVEST_MS = 4000    -- replies arrive over ~4 s after a probe
local TYPE = { [1]="chat", [2]="rep", [3]="room", [4]="sensor" }
local SNR_GOOD, SNR_OK = 0, -10   -- dB thresholds: good / marginal / bad

-- ── persistent survey state (survives view switches) ─────────────────────────
local run, running = "wd", false
local samples, sweeps, node_count = 0, 0, 0
local last_err = nil
local phase, phase_at = "idle", 0
local nodes   = {}   -- pubkey → { name, type, best, worst, their_snr, rssi, seen }
local pending = {}   -- write queue (fs allows 1 write/s)
local wrote_header = false
local track = {}     -- { lat, lon, snr } breadcrumb for the map

-- ── per-view UI handles (rebuilt on every switch) ────────────────────────────
local MAP_VIEW, NODE_VIEW = 1, 2
local cur_view = MAP_VIEW
local W, H = 0, 0

local map_obj   = nil   -- wada.map handle, nil when in node view
local node_list = nil   -- wada.list handle, nil when in map view
local status_lbl = nil
local gps_lbl    = nil
local start_btn  = nil

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
  if     snr >= SNR_GOOD then return C.good
  elseif snr >= SNR_OK   then return 0xC8A030
  else                        return C.bad end
end

-- ── CSV write queue ──────────────────────────────────────────────────────────
local HEADER = "epoch,lat_e6,lon_e6,alt_m,pubkey,name,type,rssi,snr,their_snr,hops"

local function flush()
  if #pending == 0 then return end
  local chunk = table.concat(pending, "\n") .. "\n"
  if not wrote_header then chunk = HEADER .. "\n" .. chunk end
  if fs.append(logname(), chunk) then pending, wrote_header = {}, true end
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
    if hit.snr > n.best  then n.best  = hit.snr end
    if hit.snr < n.worst then n.worst = hit.snr end
    n.their_snr = hit.their_snr
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
  if not fix then mesh.discover_clear(); return end
  local best_snr = nil
  for _, hit in ipairs(mesh.discovered()) do
    record(fix, hit)
    if not best_snr or hit.snr > best_snr then best_snr = hit.snr end
  end
  mesh.discover_clear()
  if fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0 then
    track[#track + 1] = { lat = fix.lat_e6 / 1e6, lon = fix.lon_e6 / 1e6, snr = best_snr }
  end
end

-- ── draw helpers (called from on_tick; handles may be nil if wrong view) ─────
local function redraw_map()
  if not map_obj then return end
  map_obj:clear()
  local fix = sys.gps()
  if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
    map_obj:center(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6)
  end
  for i = 2, #track do
    local a, b = track[i-1], track[i]
    map_obj:line(a.lat, a.lon, b.lat, b.lon, b.snr and snr_color(b.snr) or 0x444C54, 3)
  end
  if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
    map_obj:marker(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6, C.accent, 6)
  end
  map_obj:redraw()
end

local function redraw_nodes()
  if not node_list then return end
  node_list:clear()
  local list = {}
  for key, n in pairs(nodes) do list[#list + 1] = { key = key, n = n } end
  table.sort(list, function(a, b) return a.n.best > b.n.best end)
  if #list == 0 then node_list:add("(no replies yet)", 0, C.sub); return end
  for _, e in ipairs(list) do
    local n = e.n
    local label = string.format("%-10s %-6s  \xe2\x86\x93%+5.1f  \xe2\x86\x91%+5.1f  \xc3\x97%d",
      utf8_trunc(n.name, 10), TYPE[n.type] or "?", n.their_snr, n.best, n.seen)
    node_list:add(label, 0, snr_color(n.best))
  end
end

local function redraw_status()
  if not status_lbl then return end
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
    local rem = math.max(0, SWEEP_MS - (sys.millis() - phase_at))
    state_str = string.format("next probe %ds", math.ceil(rem / 1000))
  end
  status_lbl:set(string.format("%s  \xe2\x80\xa2  %d sweeps  %d nodes%s",
    state_str, sweeps, node_count,
    last_err and ("  [\xe2\x9a\xa0 " .. last_err .. "]") or ""))
  status_lbl:color(last_err and C.bad or (running and C.accent or C.sub))
end

-- ── view builder (called on open and on every tab switch) ────────────────────
local function build_view(v)
  cur_view = v

  -- release map before wiping widgets (one-at-a-time SDK limit)
  if map_obj then map_obj:close(); map_obj = nil end
  ui.clear()

  -- null out handles — generation bump made them stale anyway
  node_list, status_lbl, gps_lbl, start_btn = nil, nil, nil, nil

  local LH = ui.text_h(12)
  local y = 2

  gps_lbl    = ui.label("", 4, y, 12, C.sub);    gps_lbl:width(W - 8);    y = y + LH + 2
  status_lbl = ui.label("", 4, y, 12, C.accent); status_lbl:width(W - 8); y = y + LH + 3

  -- control row
  local bw = math.min(80, (W - 16) // 3)
  start_btn = ui.button("Start", 4, y, bw, 26, function()
    running = not running
    if running then phase, phase_at = "idle", 0 end
    start_btn:set(running and "Stop" or "Start")
    sys.toast(running and "Survey running" or "Survey stopped", 1000)
  end)
  if running then start_btn:set("Stop") end
  ui.button("Name", 8 + bw, y, bw, 26, function()
    ui.input("Name this run", run, function(text)
      if text and text ~= "" then
        run = text:gsub("[^%w%-_]", "_")
        wrote_header = false
        sys.toast("Logging to " .. logname(), 1500)
      end
    end)
  end)
  ui.button("Reset", 12 + bw * 2, y, bw, 26, function()
    nodes, samples, sweeps, pending, node_count = {}, 0, 0, {}, 0
    track = {}; mesh.discover_clear()
    fs.remove(logname()); wrote_header = false
    run = default_run_name()
    sys.toast("Cleared \xe2\x80\x94 new run: " .. run, 1500)
    redraw_nodes(); redraw_map()
  end)
  y = y + 30

  -- tab bar
  local has_map = sys.caps().map
  if has_map then
    local tw = (W - 12) // 2
    local mb = ui.button("Map",   4,      y, tw, 24, function() build_view(MAP_VIEW)  end)
    local nb = ui.button("Nodes", 8 + tw, y, tw, 24, function() build_view(NODE_VIEW) end)
    mb:color(v == MAP_VIEW  and C.accent or C.sub)
    nb:color(v == NODE_VIEW and C.accent or C.sub)
    y = y + 28
  end

  local content_h = H - y - 2

  if v == MAP_VIEW and has_map then
    map_obj = wada.map.view(4, y, W - 8, content_h)
    local fix = sys.gps()
    if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
      map_obj:center(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6, 13)
    else
      map_obj:zoom(13)
    end
    redraw_map()
  else
    -- NODE_VIEW, or MAP_VIEW on a board without map support
    node_list = ui.list(4, y, W - 8, content_h, function(_idx) end)
    redraw_nodes()
  end

  redraw_status()
end

-- ── app callbacks ─────────────────────────────────────────────────────────────
function app.on_open(w, h)
  if not sys.caps().discover then
    ui.label("This board does not support discovery probes.", 6, 8, 12, C.bad)
    return
  end
  W, H = w, h
  run = default_run_name()
  ui.scroll(false)
  build_view(MAP_VIEW)
  timer.every(1000)
end

function app.on_tick()
  if running then
    local now = sys.millis()
    if phase == "idle" or (phase == "wait" and now - phase_at >= SWEEP_MS) then
      phase, phase_at = do_sweep() and "probe" or "wait", now
    elseif phase == "probe" and now - phase_at >= HARVEST_MS then
      do_harvest()
      phase = "wait"
      redraw_map()
      redraw_nodes()
    end
  end
  flush()
  redraw_status()
  -- keep position dot moving between sweeps
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
