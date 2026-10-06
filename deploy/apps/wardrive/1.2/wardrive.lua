-- Wardrive v1.2.1 — LoRa coverage survey with live signal map.
--
-- Three views, tap the tab bar to switch:
--   MAP    — full-screen live track coloured by best SNR (green ≥0 dB, amber ≥-10, red <-10).
--            Current GPS position shown as a dot. Updates every sweep.
--   NODES  — node table sorted by best SNR with per-node asymmetry (↓ heard us, ↑ we heard them).
--   REVIEW — reads the saved CSV back and plots the run on the map, coloured by whichever
--            link direction you ask about. Probing pauses while the review is open.
--
-- Bug fixes from upstream 1.2:
--   · wrote_header is nil-tristate: checks the file on first flush so reopening
--     an existing log never appends a second header (breaks spreadsheets).
--   · Stale harvest guard: ticks pause while the display sleeps; millis() does
--     not. Replies heard at the old position are dropped rather than mislocated.
--   · Rename flush: queued rows land in the old file before the name changes.
--
-- CSV: epoch,lat_e6,lon_e6,alt_m,pubkey,name,type,rssi,snr,their_snr,hops
local ui, sys, mesh, fs, timer = wada.ui, wada.sys, wada.mesh, wada.fs, wada.timer
local C = ui.colors
local app = {}

local clear = ui.clear or function() end
local tr    = sys.tr    or function(x) return x end

-- ── constants ────────────────────────────────────────────────────────────────
local SWEEP_MS   = 20000
local HARVEST_MS = 4000
local STALE_MS   = HARVEST_MS + 3000   -- past this, replies were heard elsewhere
local TYPE       = { [1]="chat", [2]="rep", [3]="room", [4]="sensor" }
local SNR_GOOD, SNR_OK = 0, -10

-- ── persistent survey state (survives view switches) ─────────────────────────
local function default_run_name()
  local dt = sys.datetime and sys.datetime()
  if dt then
    return string.format("wd_%04d%02d%02d_%02d%02d%02d",
      dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec)
  end
  local ep = sys.epoch and sys.epoch()
  if ep then return string.format("wd_%d", ep) end
  return "run"
end

local run, running    = default_run_name(), false
local samples, sweeps = 0, 0
local node_count      = 0
local dropped_sweeps  = 0
local last_err        = nil
local phase, phase_at = "idle", 0
local nodes   = {}   -- pubkey → { name, type, best, worst, their_snr, rssi, seen }
local pending = {}   -- write queue (fs allows 1 write/s)
local track   = {}   -- { lat, lon, snr } live breadcrumb

local function harvest_fresh(now) return (now - phase_at) <= STALE_MS end

-- ── per-view UI handles (rebuilt on every switch) ────────────────────────────
local MAP_VIEW, NODE_VIEW, REVIEW_VIEW = 1, 2, 3
local cur_view   = MAP_VIEW
local map_full   = false   -- fullscreen toggle for MAP_VIEW
local W, H = 0, 0

local map_obj    = nil   -- live survey map handle
local node_list  = nil
local status_lbl = nil
local gps_lbl    = nil
local start_btn  = nil

-- ── helpers ──────────────────────────────────────────────────────────────────
local function logname() return run .. ".csv" end

local function utf8_prefix_bytes(text, max_bytes)
  local offset, last, length = 1, 0, #text
  while offset <= length and offset <= max_bytes do
    local first = text:byte(offset)
    local width = first <= 0x7F and 1
      or (first >= 0xC2 and first <= 0xDF and 2)
      or (first >= 0xE0 and first <= 0xEF and 3)
      or (first >= 0xF0 and first <= 0xF4 and 4) or 0
    if width == 0 or offset + width - 1 > length or offset + width - 1 > max_bytes then break end
    local valid = true
    for i = 2, width do
      local byte = text:byte(offset + i - 1)
      if byte < 0x80 or byte > 0xBF then valid = false; break end
    end
    local second = width > 1 and text:byte(offset + 1) or 0
    if (first == 0xE0 and second < 0xA0) or (first == 0xED and second > 0x9F) or
       (first == 0xF0 and second < 0x90) or (first == 0xF4 and second > 0x8F) then valid = false end
    if not valid then break end
    last = offset + width - 1
    offset = last + 1
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
-- nil = not yet checked; true/false = known. Checking on first flush prevents
-- appending a second header when reopening an existing log file.
local wrote_header = nil

local function flush()
  if #pending == 0 then return end
  local chunk = table.concat(pending, "\n") .. "\n"
  if wrote_header == nil then
    local d = fs.read(logname(), 0, 8)
    wrote_header = (d ~= nil and #d > 0)
  end
  if not wrote_header then chunk = HEADER .. "\n" .. chunk end
  if fs.append(logname(), chunk) then pending, wrote_header = {}, true end
end

local function record(fix, hit)
  local key = hit.pubkey
  local n = nodes[key]
  if not n then
    n = { name = hit.name or key:sub(1,8), type = hit.type,
          best = hit.snr, worst = hit.snr,
          their_snr = hit.their_snr, rssi = hit.rssi, seen = 0,
          last_lat = fix.lat_e6 / 1e6, last_lon = fix.lon_e6 / 1e6 }
    nodes[key] = n
    node_count = node_count + 1
  else
    if hit.snr > n.best  then n.best  = hit.snr end
    if hit.snr < n.worst then n.worst = hit.snr end
    n.their_snr = hit.their_snr
    n.rssi      = hit.rssi
    n.last_lat  = fix.lat_e6 / 1e6
    n.last_lon  = fix.lon_e6 / 1e6
    if hit.name then n.name = hit.name end
  end
  n.seen = n.seen + 1
  samples = samples + 1
  pending[#pending + 1] = string.format("%d,%d,%d,%d,%s,%s,%d,%d,%.2f,%.2f,%d",
    fix.time or sys.epoch() or 0, fix.lat_e6, fix.lon_e6, fix.alt_m or 0,
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

-- ── live map / node draw ─────────────────────────────────────────────────────
local function redraw_map()
  if not map_obj then return end
  map_obj:clear()
  local fix = sys.gps()
  local my_lat = fix and fix.lat_e6 ~= 0 and fix.lat_e6 / 1e6 or nil
  local my_lon = fix and fix.lon_e6 ~= 0 and fix.lon_e6 / 1e6 or nil
  if my_lat then map_obj:center(my_lat, my_lon) end
  -- survey track coloured by best SNR at each stop
  for i = 2, #track do
    local a, b = track[i-1], track[i]
    map_obj:line(a.lat, a.lon, b.lat, b.lon, b.snr and snr_color(b.snr) or 0x444C54, 3)
  end
  -- lines from current position to last-heard position of every node
  if my_lat then
    for _, n in pairs(nodes) do
      if n.last_lat then
        map_obj:line(my_lat, my_lon, n.last_lat, n.last_lon, snr_color(n.best), 1)
        map_obj:marker(n.last_lat, n.last_lon, snr_color(n.best), 4)
      end
    end
    map_obj:marker(my_lat, my_lon, C.accent, 6)   -- self dot on top
  end
  map_obj:redraw()
end

local function redraw_nodes()
  if not node_list then return end
  node_list:clear()
  local list = {}
  for key, n in pairs(nodes) do list[#list + 1] = { key = key, n = n } end
  table.sort(list, function(a, b) return a.n.best > b.n.best end)
  if #list == 0 then node_list:add(tr("(no replies yet)"), 0, C.sub); return end
  for _, e in ipairs(list) do
    local n = e.n
    local label = string.format("%-10s %-6s  \xe2\x86\x93%+5.1f  \xe2\x86\x91%+5.1f  \xc3\x97%d",
      utf8_prefix_bytes(n.name, 10), TYPE[n.type] or "?", n.their_snr, n.best, n.seen)
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
    gps_lbl:set(tr("no GPS fix — samples discarded until locked"))
    gps_lbl:color(C.bad)
  end
  local state_str
  if not running then
    state_str = tr("stopped")
  elseif phase == "probe" then
    state_str = tr("listening…")
  else
    local rem = math.max(0, SWEEP_MS - (sys.millis() - phase_at))
    state_str = string.format(tr("next probe %ds"), math.ceil(rem / 1000))
  end
  status_lbl:set(string.format("%s  •  %d sweeps  %d nodes%s%s",
    state_str, sweeps, node_count,
    dropped_sweeps > 0 and ("  · " .. dropped_sweeps .. " dropped") or "",
    last_err and ("  [⚠ " .. last_err .. "]") or ""))
  status_lbl:color(last_err and C.bad or (running and C.accent or C.sub))
end

-- ── ⚠️ drop_map MUST be called before any ui.clear() ────────────────────────
-- The map userdata has no generation field: clear() deletes its container but
-- leaves the one-view counter set and the pointer live. Closing first avoids
-- leaking tile pixels, a stuck "only one map view" error, and a later UAF.
local function drop_map()
  if map_obj then pcall(function() map_obj:close() end); map_obj = nil end
end

-- ── review state ─────────────────────────────────────────────────────────────
local MODES = { tr("heard them"), tr("heard us"), tr("asymmetry") }
local mode   = 1
local was_running = false
local rv_map, rv_map_note, rv_stat, rv_legend, rv_plot = nil, nil, nil, nil, nil
local plot_px = 0
local ld      = nil
local READ_WIN = 4096
local MAX_DRAW = 150

local function metric_of(st)
  if mode == 2 then return st.them_max end
  if mode == 3 then return st.asym     end
  return st.snr_max
end

local function colour_for(v)
  if mode == 3 then
    if v > 6 or v < -6 then return C.bad end
    if v > 3 or v < -3 then return C.accent end
    return C.good
  end
  if v >= 0   then return C.good   end
  if v >= -10 then return C.accent end
  return C.bad
end

local function ld_reset()
  ld = { off=0, total=nil, tail="", stops={}, n=0, skipped=0, done=false, plotted=false,
         minlat=nil, maxlat=nil, minlon=nil, maxlon=nil, metres=0, wrapped=false,
         prev_lat=nil, prev_lon=nil, by_node={}, node_n=0, step=1,
         stop_n=0, pos_i=0, keep_every=1, last_key=nil, cur=nil, tailstop=nil }
end

local MAX_STOPS = 400
local function stop_push(lat, lon)
  ld.pos_i  = ld.pos_i  + 1
  ld.stop_n = ld.stop_n + 1
  if #ld.stops >= MAX_STOPS then
    local last = ld.stops[#ld.stops]
    local out, j = {}, 0
    for i = 1, #ld.stops, 2 do j = j + 1; out[j] = ld.stops[i] end
    if out[j] ~= last then j = j + 1; out[j] = last end
    ld.stops = out
    ld.keep_every = ld.keep_every * 2
  end
  local st = { lat=lat, lon=lon, n=0 }
  ld.tailstop = st
  if (ld.pos_i % ld.keep_every) == 0 then
    ld.stops[#ld.stops + 1] = st; st.kept = true
  end
  return st
end

local function stops_finalise()
  local t = ld and ld.tailstop
  if t and not t.kept and #ld.stops > 0 then
    ld.stops[#ld.stops + 1] = t; t.kept = true
  end
end

local function ld_row(line)
  local f, n = {}, 0
  for part in (line .. ","):gmatch("([^,]*),") do
    n = n + 1; f[n] = part; if n >= 11 then break end
  end
  if n < 11 then ld.skipped = ld.skipped + 1; return end
  local lat_e6, lon_e6 = tonumber(f[2]), tonumber(f[3])
  local snr, their     = tonumber(f[9]), tonumber(f[10])
  if not (lat_e6 and lon_e6 and snr and their) then ld.skipped = ld.skipped + 1; return end
  local lat, lon = lat_e6 / 1000000, lon_e6 / 1000000
  if lat_e6 == 0 and lon_e6 == 0 then ld.skipped = ld.skipped + 1; return end
  ld.n = ld.n + 1
  if not ld.minlat or lat < ld.minlat then ld.minlat = lat end
  if not ld.maxlat or lat > ld.maxlat then ld.maxlat = lat end
  if not ld.minlon or lon < ld.minlon then ld.minlon = lon end
  if not ld.maxlon or lon > ld.maxlon then ld.maxlon = lon end
  if ld.prev_lat and wada.geo then
    local ok, d = pcall(wada.geo.distance, ld.prev_lat, ld.prev_lon, lat, lon)
    if ok and d then ld.metres = ld.metres + d end
  end
  ld.prev_lat, ld.prev_lon = lat, lon
  local key = f[5]
  local nd = ld.by_node[key]
  if not nd then
    nd = { name=(f[6] ~= "" and f[6]) or key, type=tonumber(f[7]) or 0,
           best=snr, worst=snr, best_them=their, asym=snr-their, seen=0 }
    ld.by_node[key] = nd; ld.node_n = ld.node_n + 1
  end
  if snr  > nd.best      then nd.best      = snr   end
  if snr  < nd.worst     then nd.worst     = snr   end
  if their > nd.best_them then nd.best_them = their end
  do
    local a = snr - their
    if (a < 0 and -a or a) > (nd.asym < 0 and -nd.asym or nd.asym) then nd.asym = a end
  end
  nd.seen = nd.seen + 1
  local ekey = f[2] .. "," .. f[3]
  if ekey ~= ld.last_key then ld.last_key = ekey; ld.cur = stop_push(lat, lon) end
  local st = ld.cur
  if st then
    st.n = st.n + 1
    if not st.snr_max  or snr   > st.snr_max  then st.snr_max  = snr   end
    if not st.snr_min  or snr   < st.snr_min  then st.snr_min  = snr   end
    if not st.them_max or their > st.them_max  then st.them_max = their end
    if not st.them_min or their < st.them_min  then st.them_min = their end
    local a = snr - their
    if not st.asym or (a < 0 and -a or a) > (st.asym < 0 and -st.asym or st.asym) then st.asym = a end
  end
end

local function ld_step()
  if not ld or ld.done then return false end
  local data = fs.read(logname(), ld.off, READ_WIN)
  if not data then
    if ld.tail ~= "" and not ld.tail:find("^epoch,") then ld_row(ld.tail); ld.tail = "" end
    stops_finalise(); ld.done = true; return false
  end
  ld.off = ld.off + #data
  local buf  = ld.tail .. data
  local last = 0
  for line, pos in buf:gmatch("([^\n]*)\n()") do
    last = pos - 1
    if line ~= "" and not line:find("^epoch,") then ld_row(line) end
  end
  ld.tail = buf:sub(last + 1)
  if #data == 0 then
    if ld.tail ~= "" and not ld.tail:find("^epoch,") then ld_row(ld.tail) end
    ld.tail = ""; stops_finalise(); ld.done = true
  end
  return not ld.done
end

local function merc_y(lat)
  if lat >  85 then lat =  85 end
  if lat < -85 then lat = -85 end
  local r = lat * math.pi / 180
  return 0.5 - math.log(math.tan(math.pi / 4 + r / 2)) / (2 * math.pi)
end
local function merc_lat(y)
  local r = 2 * (math.atan(math.exp((0.5 - y) * 2 * math.pi)) - math.pi / 4)
  return r * 180 / math.pi
end

local function fit_zoom(px, py)
  if not ld or not ld.minlat then return 14 end
  local sy = math.max(math.abs(merc_y(ld.minlat) - merc_y(ld.maxlat)), 1e-9)
  local sx  = (ld.maxlon - ld.minlon) / 360
  if sx > 0.5 then ld.wrapped = true end
  sx = math.max(sx, 1e-9)
  local function z_for(span, pixels)
    if not (pixels > 0) then return 1 end
    local v = pixels / (256 * span)
    if not (v > 1) then return 1 end
    return math.floor(math.log(v) / math.log(2))
  end
  local z = ld.wrapped and z_for(sy, py) or math.min(z_for(sx, px), z_for(sy, py))
  if not (z == z) then z = 14 end
  if z < 1 then z = 1 end; if z > 19 then z = 19 end
  return z
end

local function review_plot()
  if not ld then return end
  local drawn = 0
  local step  = math.max(1, math.ceil(#ld.stops / MAX_DRAW))
  ld.step = step
  if rv_map then
    rv_map:clear()
    if ld.minlat then
      local clat = merc_lat((merc_y(ld.minlat) + merc_y(ld.maxlat)) / 2)
      local clon
      if ld.wrapped then
        local a = ld.minlon < 0 and ld.minlon + 360 or ld.minlon
        local b = ld.maxlon < 0 and ld.maxlon + 360 or ld.maxlon
        clon = (a + b) / 2; if clon > 180 then clon = clon - 360 end
      else
        clon = (ld.minlon + ld.maxlon) / 2
      end
      rv_map:center(clat, clon, fit_zoom(W - 8, plot_px))
      local prev = nil
      for i = 1, #ld.stops, step do
        local st = ld.stops[i]
        if prev then rv_map:line(prev.lat, prev.lon, st.lat, st.lon, C.sub, 1) end
        if rv_map:marker(st.lat, st.lon, colour_for(metric_of(st)), 3) then drawn = drawn + 1 end
        prev = st
      end
    end
    local tiles = 0
    local ok, t = pcall(function() return rv_map:tiles() end)
    if ok and t then tiles = t end
    if not ld.minlat then
      rv_map_note:set("")
    elseif tiles == 0 then
      rv_map_note:set(tr("no tiles cached here - blank ground, not open water")); rv_map_note:color(C.bad)
    else
      rv_map_note:set(string.format("%d tiles  ·  %d of %d stops%s%s", tiles, drawn, ld.stop_n,
        step > 1 and ("  ·  1 in " .. step) or "",
        ld.keep_every > 1 and ("  ·  sampled 1 in " .. ld.keep_every) or ""))
      rv_map_note:color(C.sub)
    end
  elseif rv_plot then
    local pw = math.min(W - 8, 480); local ph = math.min(plot_px, 480)
    rv_plot:fill(C.bg)
    if ld.minlat then
      local dlat = math.max(ld.maxlat - ld.minlat, 1e-6)
      local dlon = math.max(ld.maxlon - ld.minlon, 1e-6)
      local function sx(lon) return math.floor(4 + (lon - ld.minlon) / dlon * (pw - 8)) end
      local function sy(lat) return math.floor(4 + (ld.maxlat - lat) / dlat * (ph - 8)) end
      local prev = nil
      for i = 1, #ld.stops, step do
        local st = ld.stops[i]; local x, y = sx(st.lon), sy(st.lat)
        if prev then rv_plot:line(prev[1], prev[2], x, y, C.sub) end
        rv_plot:circle(x, y, 2, colour_for(metric_of(st))); drawn = drawn + 1; prev = {x, y}
      end
    end
    rv_plot:text(4, 2, string.format(tr("route shape - %d of %d stops"), drawn, ld.stop_n), C.sub, 12)
  end
end

local function review_stat()
  if not ld then return end
  if not ld.done then
    rv_stat:set(string.format(tr("reading %s … %d rows"), logname(), ld.n)); rv_stat:color(C.sub); return
  end
  if ld.n == 0 then
    rv_stat:set(string.format(tr("%s has no plottable rows yet"), logname())); rv_stat:color(C.bad); return
  end
  rv_stat:set(string.format("%s  ·  %d samples, %d stops, %d nodes  ·  %.2f km%s%s",
    run, ld.n, ld.stop_n, ld.node_n, ld.metres / 1000,
    ld.wrapped and "  ·  crosses antimeridian" or "",
    ld.skipped > 0 and ("  ·  " .. ld.skipped .. " unusable") or ""))
  rv_stat:color(C.accent)
  local worst_name, worst_gap = nil, nil
  for _, nd in pairs(ld.by_node) do
    local g = nd.asym < 0 and -nd.asym or nd.asym
    if not worst_gap or g > worst_gap then worst_gap, worst_name = g, nd.name end
  end
  local legend
  if mode == 3 then
    legend = tr("colour: balance — green even, red one-sided")
    if worst_name then
      legend = legend .. string.format("  ·  worst %s %.1f dB", utf8_prefix_bytes(worst_name, 10), worst_gap)
    end
  elseif mode == 2 then legend = tr("colour: how well they heard US")
  else                  legend = tr("colour: how well WE heard them") end
  rv_legend:set(legend); rv_legend:color(C.sub)
end

-- ── view builder ─────────────────────────────────────────────────────────────
local function build_view(v)
  if v ~= MAP_VIEW then map_full = false end
  cur_view = v
  drop_map()   -- MUST precede clear()
  clear()
  node_list, status_lbl, gps_lbl, start_btn = nil, nil, nil, nil
  rv_map, rv_map_note, rv_stat, rv_legend, rv_plot = nil, nil, nil, nil, nil

  local LH = ui.text_h(12)
  local y  = 2
  local has_map = sys.caps().map

  gps_lbl    = ui.label("", 4, y, 12, C.sub);    gps_lbl:width(W - 8);    y = y + LH + 2
  status_lbl = ui.label("", 4, y, 12, C.accent); status_lbl:width(W - 8); y = y + LH + 3

  -- control row
  local bw = math.min(80, (W - 16) // 3)
  start_btn = ui.button(running and tr("Stop") or tr("Start"), 4, y, bw, 26, function()
    running = not running
    if running then phase, phase_at = "idle", 0 end
    start_btn:set(running and tr("Stop") or tr("Start"))
    sys.toast(running and tr("Survey running") or tr("Survey stopped"), 1000)
  end)
  ui.button(tr("Name"), 8 + bw, y, bw, 26, function()
    ui.input(tr("Name this run"), run, function(text)
      if text and text ~= "" then
        flush()                              -- land queued rows into the OLD file first
        pending      = {}                    -- anything the rate limit refused belongs to old run
        run          = text:gsub("[^%w%-_]", "_")
        wrote_header = nil                   -- unknown: new file may or may not have a header
        sys.toast(tr("Logging to ") .. logname(), 1500)
      end
    end)
  end)
  ui.button(tr("Reset"), 12 + bw * 2, y, bw, 26, function()
    nodes, samples, sweeps, pending, node_count = {}, 0, 0, {}, 0
    dropped_sweeps = 0; track = {}; mesh.discover_clear()
    fs.remove(logname()); wrote_header = nil
    run = default_run_name()
    sys.toast(tr("Cleared — new run: ") .. run, 1500)
  end)
  y = y + 30

  -- tab bar
  local tabs = has_map and { tr("Map"), tr("Nodes"), tr("Review") }
                        or { tr("Nodes"), tr("Review") }
  local tab_views = has_map and { MAP_VIEW, NODE_VIEW, REVIEW_VIEW }
                             or { NODE_VIEW, REVIEW_VIEW }
  local tw = (W - 8 - (#tabs - 1) * 4) // #tabs
  for i, label in ipairs(tabs) do
    local tv = tab_views[i]
    local x  = 4 + (i - 1) * (tw + 4)
    local btn = ui.button(label, x, y, tw, 24, function() build_view(tv) end)
    btn:color(v == tv and C.accent or C.sub)
  end
  y = y + 28

  local content_h = H - y - 2

  if v == MAP_VIEW and has_map then
    -- fullscreen: map fills entire body, skip header/tab rows
    local mx, my, mw, mh
    if map_full then
      mx, my, mw, mh = 0, 0, W, H
    else
      mx, my, mw, mh = 4, y, W - 8, content_h
    end
    map_obj = wada.map.view(mx, my, mw, mh)
    local fix = sys.gps()
    if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
      map_obj:center(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6, 13)
    else
      map_obj:zoom(13)
    end
    -- fullscreen toggle button: floating top-right corner over the map
    ui.button(map_full and "[-]" or "[+]", W - 32, 2, 28, 22, function()
      map_full = not map_full
      build_view(MAP_VIEW)
    end)
    redraw_map()

  elseif v == NODE_VIEW then
    node_list = ui.list(4, y, W - 8, content_h, function(_idx) end)
    redraw_nodes()

  elseif v == REVIEW_VIEW then
    -- bank in-flight probe before pausing
    if running and phase == "probe" and harvest_fresh(sys.millis()) then
      do_harvest()
    else
      if phase == "probe" then dropped_sweeps = dropped_sweeps + 1 end
      mesh.discover_clear()
    end
    flush()
    was_running = running
    running = false; phase = "idle"
    ld_reset()
    -- stat line
    rv_stat = ui.label("", 4, y, 12, C.text); rv_stat:width(W - 8)
    y = y + LH + 3
    -- reserve bottom rows, give map/plot the rest
    local BTN_H  = 28
    local footer = (LH + 2) + (LH + 2) + BTN_H + 4
    local plot_h = math.max(40, content_h - (LH + 3) - footer)
    plot_px      = plot_h
    if has_map then
      local ok, m = pcall(function() return wada.map.view(4, y, W - 8, plot_h) end)
      if ok and m then rv_map = m end
    end
    if not rv_map then
      local okc, cv = pcall(ui.canvas, math.min(W - 8, 480), math.min(plot_h, 480))
      if okc and cv then rv_plot = cv; rv_plot:pos(4, y) end
    end
    y = y + plot_h + 4
    rv_map_note = ui.label("", 4, y, 12, C.sub); rv_map_note:width(W - 8); y = y + LH + 2
    rv_legend   = ui.label("", 4, y, 12, C.sub); rv_legend:width(W - 8);   y = y + LH + 2
    local rbw = math.min(80, (W - 16) // 3)
    -- Back: restore running state
    ui.button(tr("Back"), 4, y, rbw, BTN_H, function()
      if rv_map then pcall(function() rv_map:close() end); rv_map = nil end
      running = was_running
      if running then phase, phase_at = "idle", 0 end
      mesh.discover_clear()
      ld = nil
      build_view(has_map and MAP_VIEW or NODE_VIEW)
    end)
    ui.button(tr("Colour"), 8 + rbw, y, rbw, BTN_H, function()
      mode = mode % #MODES + 1
      sys.toast(MODES[mode], 800)
      review_plot(); review_stat()
    end)
    ui.button(tr("Refit"), 12 + rbw * 2, y, rbw, BTN_H, function()
      ld_reset(); review_stat()
    end)
    review_stat()
  end

  redraw_status()
end

-- ── app callbacks ─────────────────────────────────────────────────────────────
function app.on_open(w, h)
  if not sys.caps().discover then
    ui.label(tr("This board cannot send discovery probes,"), 6,  8, 12, C.bad)
    ui.label(tr("so it cannot run a coverage survey."),     6, 26, 12, C.bad)
    return
  end
  W, H = w, h
  ui.scroll(false)
  build_view(sys.caps().map and MAP_VIEW or NODE_VIEW)
  timer.every(1000)
end

function app.on_tick()
  if cur_view == REVIEW_VIEW then
    local more = ld_step()
    review_stat()
    if not more and ld and ld.done and not ld.plotted then
      ld.plotted = true; review_plot()
    end
    flush()
    return
  end

  local map_redrawn = false
  if running then
    local now = sys.millis()
    if phase == "idle" or (phase == "wait" and now - phase_at >= SWEEP_MS) then
      phase, phase_at = do_sweep() and "probe" or "wait", now
    elseif phase == "probe" and now - phase_at >= HARVEST_MS then
      if harvest_fresh(now) then
        do_harvest()
        if cur_view == MAP_VIEW  then redraw_map(); map_redrawn = true end
        if cur_view == NODE_VIEW then redraw_nodes() end
      else
        mesh.discover_clear(); dropped_sweeps = dropped_sweeps + 1
      end
      phase = "wait"
    end
  end
  flush()
  redraw_status()
  -- keep position dot moving between sweeps (skip if redraw_map() already ran this tick)
  if map_obj and not map_redrawn then
    local fix = sys.gps()
    if fix and (fix.lat_e6 ~= 0 or fix.lon_e6 ~= 0) then
      map_obj:center(fix.lat_e6 / 1e6, fix.lon_e6 / 1e6)  -- center() renders internally, no extra :redraw()
    end
  end
end

function app.on_close()
  flush()
  drop_map()
  if rv_map then pcall(function() rv_map:close() end); rv_map = nil end
end

return app
