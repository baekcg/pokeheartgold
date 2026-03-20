-- Korean HeartGold DeSmuME bridge.
-- Lua owns emulator integration: battle-state detection, memory I/O, joypad,
-- savestate, and JSON file exchange. Higher-level battle decisions stay in
-- Python and arrive as command.json.

local CONFIG = {
  bridge_dir = "runtime/desmume",
  state_path = "runtime/desmume/state.json",
  state_tmp_path = "runtime/desmume/state.json.tmp",
  command_path = "runtime/desmume/command.json",
  rescan_interval_frames = 30,
  near_ctx_scan_radius = 0x20000,
  schema_version = 1,
}

local ARM9_SCAN_START = 0x02200000
local ARM9_SCAN_END = 0x023F0000
local SCAN_STEP = 4

local BATTLEMON_STRIDE = 0xC0
local OFFSET_COMMAND = 0x08
local OFFSET_COMMAND_NEXT = 0x0C
local OFFSET_BATTLESTATUS = 0x213C
local OFFSET_BATTLESTATUS2 = 0x2140
local OFFSET_DAMAGE = 0x2144
local OFFSET_HIT_DAMAGE = 0x2148
local OFFSET_BATTLEMONS = 0x2D40
local OFFSET_MOVE_NO_TEMP = 0x3040
local OFFSET_MOVE_NO_CUR = 0x3044
local OFFSET_MOVE_NO_PREV = 0x3048
local OFFSET_BATTLERS_ON_FIELD = 0x3150

local OFF_SPECIES = 0x00
local OFF_MOVES = 0x0C
local OFF_STAT_CHANGES = 0x18
local OFF_WEIGHT = 0x20
local OFF_TYPE1 = 0x24
local OFF_TYPE2 = 0x25
local OFF_ABILITY = 0x27
local OFF_MOVE_PP_CUR = 0x2C
local OFF_MOVE_PP_MAX = 0x30
local OFF_LEVEL = 0x34
local OFF_FRIENDSHIP = 0x35
local OFF_HP = 0x4C
local OFF_MAX_HP = 0x50
local OFF_EXP = 0x64
local OFF_STATUS = 0x6C
local OFF_STATUS2 = 0x70
local OFF_ITEM = 0x78
local OFF_MOVE_EFFECT_FLAGS = 0x80

local CONTROLLER_COMMAND_SELECTION_SCREEN_INPUT = 5
local CONTROLLER_COMMAND_FIGHT_INPUT = 13
local CONTROLLER_COMMAND_RUN_SCRIPT = 22
local CONTROLLER_COMMAND_23 = 23
local CONTROLLER_COMMAND_39 = 39
local CONTROLLER_COMMAND_MAX = 46
local NUM_STATS = 8
local MAX_SPECIES = 600
local MAX_MOVES = 600
local MAX_LEVEL = 100
local MAX_HP = 4096
local MAX_PP = 63
local MAX_TYPE = 17

local BUTTON_ORDER = {
  "A",
  "B",
  "X",
  "Y",
  "L",
  "R",
  "Start",
  "Select",
  "Up",
  "Down",
  "Left",
  "Right",
  "Touch",
  "Debug",
  "Lid",
  "Reset",
}

local VALID_BUTTONS = {}
for _, button_name in ipairs(BUTTON_ORDER) do
  VALID_BUTTONS[button_name] = true
end

local BATTLE_ROLE_NAMES = {
  [1] = "player",
  [2] = "enemy",
  [3] = "player_partner",
  [4] = "enemy_partner",
}

local STATUS_SLEEP = 0x07
local STATUS_POISON = 0x08
local STATUS_BURN = 0x10
local STATUS_FREEZE = 0x20
local STATUS_PARALYSIS = 0x40
local STATUS_BAD_POISON = 0x80

local STAT_STAGE_KEYS = {
  [2] = "attack",
  [3] = "defense",
  [4] = "speed",
  [5] = "special_attack",
  [6] = "special_defense",
  [7] = "accuracy",
  [8] = "evasion",
}

local STAT_STAGE_ORDER = { 2, 3, 4, 5, 6, 7, 8 }

local function resolve_function(candidates)
  for _, path in ipairs(candidates) do
    local value = _G
    local ok = true
    for _, key in ipairs(path) do
      value = value[key]
      if value == nil then
        ok = false
        break
      end
    end
    if ok and type(value) == "function" then
      return value
    end
  end
  return nil
end

local function normalize_u8(v)
  if v < 0 then
    return v + 0x100
  end
  return v
end

local function normalize_u16(v)
  if v < 0 then
    return v + 0x10000
  end
  return v
end

local function normalize_u32(v)
  if v < 0 then
    return v + 0x100000000
  end
  return v
end

local bit_band = nil
if type(bit32) == "table" and type(bit32.band) == "function" then
  bit_band = bit32.band
elseif type(bit) == "table" and type(bit.band) == "function" then
  bit_band = bit.band
end

local function band_u32(a, b)
  if bit_band ~= nil then
    return bit_band(a, b)
  end

  local value_a = normalize_u32(a)
  local value_b = normalize_u32(b)
  local result = 0
  local bit_value = 1

  while value_a > 0 and value_b > 0 do
    if value_a % 2 == 1 and value_b % 2 == 1 then
      result = result + bit_value
    end
    value_a = math.floor(value_a / 2)
    value_b = math.floor(value_b / 2)
    bit_value = bit_value * 2
  end

  return result
end

local raw_read_u8 = resolve_function({
  { "memory", "readbyteunsigned" },
  { "memory", "readbyte" },
  { "mainmemory", "read_u8" },
})

local raw_read_u16 = resolve_function({
  { "memory", "readwordunsigned" },
  { "memory", "readword" },
  { "mainmemory", "read_u16_le" },
})

local raw_read_u32 = resolve_function({
  { "memory", "readdwordunsigned" },
  { "memory", "readdword" },
  { "mainmemory", "read_u32_le" },
})

local raw_write_u32 = resolve_function({
  { "memory", "writedword" },
  { "memory", "writedwordunsigned" },
  { "mainmemory", "write_u32_le" },
})

local raw_write_u16 = resolve_function({
  { "memory", "writeword" },
  { "memory", "writewordunsigned" },
  { "mainmemory", "write_u16_le" },
})

local raw_write_u8 = resolve_function({
  { "memory", "writebyte" },
  { "memory", "writebyteunsigned" },
  { "mainmemory", "write_u8" },
})

local gui_text = resolve_function({
  { "gui", "text" },
  { "gui", "drawText" },
})

local frame_advance = resolve_function({
  { "emu", "frameadvance" },
})

local joypad_set = resolve_function({
  { "joypad", "set" },
  { "input", "set" },
})

local savestate_save = resolve_function({
  { "savestate", "save" },
  { "savestate", "saveslot" },
  { "state", "save" },
  { "state", "saveSlot" },
})

if raw_read_u8 == nil or raw_read_u16 == nil or raw_read_u32 == nil then
  error("No supported memory read API found for this Lua environment")
end

local function read_u8(addr)
  return normalize_u8(raw_read_u8(addr))
end

local function read_u16(addr)
  return normalize_u16(raw_read_u16(addr))
end

local function read_u32(addr)
  return normalize_u32(raw_read_u32(addr))
end

local function read_s32(addr)
  local value = read_u32(addr)
  if value >= 0x80000000 then
    return value - 0x100000000
  end
  return value
end

local function write_u32(addr, value)
  if raw_write_u32 == nil then
    return false, "memory_write_u32_unavailable"
  end
  local ok, err = pcall(raw_write_u32, addr, value)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

local function write_u16(addr, value)
  if raw_write_u16 ~= nil then
    local ok, err = pcall(raw_write_u16, addr, value)
    if not ok then
      return false, tostring(err)
    end
    return true, nil
  end
  if raw_write_u32 == nil then
    return false, "memory_write_u16_unavailable"
  end
  local aligned = addr - (addr % 4)
  local bytes = {
    read_u8(aligned),
    read_u8(aligned + 1),
    read_u8(aligned + 2),
    read_u8(aligned + 3),
  }
  local offset = addr - aligned
  bytes[offset + 1] = value % 0x100
  bytes[offset + 2] = math.floor(value / 0x100) % 0x100
  local packed = bytes[1]
    + bytes[2] * 0x100
    + bytes[3] * 0x10000
    + bytes[4] * 0x1000000
  return write_u32(aligned, packed)
end

local function write_u8(addr, value)
  if raw_write_u8 ~= nil then
    local ok, err = pcall(raw_write_u8, addr, value)
    if not ok then
      return false, tostring(err)
    end
    return true, nil
  end
  if raw_write_u32 == nil then
    return false, "memory_write_u8_unavailable"
  end
  local aligned = addr - (addr % 4)
  local bytes = {
    read_u8(aligned),
    read_u8(aligned + 1),
    read_u8(aligned + 2),
    read_u8(aligned + 3),
  }
  bytes[(addr - aligned) + 1] = value % 0x100
  local packed = bytes[1]
    + bytes[2] * 0x100
    + bytes[3] * 0x10000
    + bytes[4] * 0x1000000
  return write_u32(aligned, packed)
end

local function hex8(value)
  return string.format("0x%08X", value)
end

local function is_array(tbl)
  if type(tbl) ~= "table" then
    return false
  end
  local max = 0
  for key, _ in pairs(tbl) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    if key > max then
      max = key
    end
  end
  for i = 1, max do
    if tbl[i] == nil then
      return false
    end
  end
  return true
end

local function escape_json_string(value)
  local out = { '"' }
  for i = 1, #value do
    local ch = string.sub(value, i, i)
    local byte = string.byte(ch)
    if ch == '"' then
      out[#out + 1] = '\\"'
    elseif ch == "\\" then
      out[#out + 1] = "\\\\"
    elseif ch == "\b" then
      out[#out + 1] = "\\b"
    elseif ch == "\f" then
      out[#out + 1] = "\\f"
    elseif ch == "\n" then
      out[#out + 1] = "\\n"
    elseif ch == "\r" then
      out[#out + 1] = "\\r"
    elseif ch == "\t" then
      out[#out + 1] = "\\t"
    elseif byte < 0x20 then
      out[#out + 1] = string.format("\\u%04X", byte)
    else
      out[#out + 1] = ch
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function json_encode(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" then
    if value then
      return "true"
    end
    return "false"
  end
  if t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("Cannot encode non-finite number to JSON")
    end
    return tostring(value)
  end
  if t == "string" then
    return escape_json_string(value)
  end
  if t ~= "table" then
    error("Unsupported JSON value type: " .. t)
  end

  if is_array(value) then
    local items = {}
    for i = 1, #value do
      items[#items + 1] = json_encode(value[i])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do
    if type(key) ~= "string" then
      error("JSON object keys must be strings")
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = escape_json_string(key) .. ":" .. json_encode(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function json_decode(text)
  local idx = 1
  local len = #text

  local function decode_error(message)
    error("JSON parse error at byte " .. idx .. ": " .. message)
  end

  local function skip_ws()
    while idx <= len do
      local ch = string.sub(text, idx, idx)
      if ch ~= " " and ch ~= "\n" and ch ~= "\r" and ch ~= "\t" then
        break
      end
      idx = idx + 1
    end
  end

  local parse_value

  local function parse_string()
    if string.sub(text, idx, idx) ~= '"' then
      decode_error("expected string")
    end
    idx = idx + 1
    local out = {}
    while idx <= len do
      local ch = string.sub(text, idx, idx)
      if ch == '"' then
        idx = idx + 1
        return table.concat(out)
      end
      if ch == "\\" then
        idx = idx + 1
        if idx > len then
          decode_error("unterminated escape")
        end
        local esc = string.sub(text, idx, idx)
        if esc == '"' or esc == "\\" or esc == "/" then
          out[#out + 1] = esc
        elseif esc == "b" then
          out[#out + 1] = "\b"
        elseif esc == "f" then
          out[#out + 1] = "\f"
        elseif esc == "n" then
          out[#out + 1] = "\n"
        elseif esc == "r" then
          out[#out + 1] = "\r"
        elseif esc == "t" then
          out[#out + 1] = "\t"
        elseif esc == "u" then
          local hex = string.sub(text, idx + 1, idx + 4)
          if #hex ~= 4 or not string.match(hex, "^[0-9A-Fa-f]+$") then
            decode_error("invalid unicode escape")
          end
          out[#out + 1] = string.char(tonumber(hex, 16))
          idx = idx + 4
        else
          decode_error("unsupported escape '" .. esc .. "'")
        end
      else
        out[#out + 1] = ch
      end
      idx = idx + 1
    end
    decode_error("unterminated string")
  end

  local function parse_number()
    local start_idx = idx
    local ch = string.sub(text, idx, idx)
    if ch == "-" then
      idx = idx + 1
    end
    if idx > len then
      decode_error("truncated number")
    end
    ch = string.sub(text, idx, idx)
    if ch == "0" then
      idx = idx + 1
    elseif string.match(ch, "%d") then
      repeat
        idx = idx + 1
        ch = string.sub(text, idx, idx)
      until not string.match(ch, "%d")
    else
      decode_error("invalid number")
    end

    ch = string.sub(text, idx, idx)
    if ch == "." then
      idx = idx + 1
      if not string.match(string.sub(text, idx, idx), "%d") then
        decode_error("invalid fraction")
      end
      repeat
        idx = idx + 1
        ch = string.sub(text, idx, idx)
      until not string.match(ch, "%d")
    end

    ch = string.sub(text, idx, idx)
    if ch == "e" or ch == "E" then
      idx = idx + 1
      ch = string.sub(text, idx, idx)
      if ch == "+" or ch == "-" then
        idx = idx + 1
      end
      if not string.match(string.sub(text, idx, idx), "%d") then
        decode_error("invalid exponent")
      end
      repeat
        idx = idx + 1
        ch = string.sub(text, idx, idx)
      until not string.match(ch, "%d")
    end

    local value = tonumber(string.sub(text, start_idx, idx - 1))
    if value == nil then
      decode_error("invalid number")
    end
    return value
  end

  local function parse_literal(literal, value)
    if string.sub(text, idx, idx + #literal - 1) ~= literal then
      decode_error("expected '" .. literal .. "'")
    end
    idx = idx + #literal
    return value
  end

  local function parse_array()
    idx = idx + 1
    skip_ws()
    local arr = {}
    if string.sub(text, idx, idx) == "]" then
      idx = idx + 1
      return arr
    end
    while true do
      arr[#arr + 1] = parse_value()
      skip_ws()
      local ch = string.sub(text, idx, idx)
      if ch == "]" then
        idx = idx + 1
        return arr
      end
      if ch ~= "," then
        decode_error("expected ',' or ']'")
      end
      idx = idx + 1
      skip_ws()
    end
  end

  local function parse_object()
    idx = idx + 1
    skip_ws()
    local obj = {}
    if string.sub(text, idx, idx) == "}" then
      idx = idx + 1
      return obj
    end
    while true do
      if string.sub(text, idx, idx) ~= '"' then
        decode_error("expected string key")
      end
      local key = parse_string()
      skip_ws()
      if string.sub(text, idx, idx) ~= ":" then
        decode_error("expected ':'")
      end
      idx = idx + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local ch = string.sub(text, idx, idx)
      if ch == "}" then
        idx = idx + 1
        return obj
      end
      if ch ~= "," then
        decode_error("expected ',' or '}'")
      end
      idx = idx + 1
      skip_ws()
    end
  end

  function parse_value()
    skip_ws()
    local ch = string.sub(text, idx, idx)
    if ch == '"' then
      return parse_string()
    end
    if ch == "{" then
      return parse_object()
    end
    if ch == "[" then
      return parse_array()
    end
    if ch == "-" or string.match(ch, "%d") then
      return parse_number()
    end
    if ch == "t" then
      return parse_literal("true", true)
    end
    if ch == "f" then
      return parse_literal("false", false)
    end
    if ch == "n" then
      return parse_literal("null", nil)
    end
    decode_error("unexpected character '" .. ch .. "'")
  end

  local value = parse_value()
  skip_ws()
  if idx <= len then
    decode_error("trailing content")
  end
  return value
end

local function shell_quote(value)
  return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

local function shell_quote_windows(value)
  return '"' .. string.gsub(value, '"', '""') .. '"'
end

local function is_windows_host()
  if type(package) ~= "table" or type(package.config) ~= "string" then
    return false
  end
  return string.sub(package.config, 1, 1) == "\\"
end

local function ensure_bridge_dir()
  local probe = io.open(CONFIG.state_tmp_path, "w")
  if probe ~= nil then
    probe:close()
    os.remove(CONFIG.state_tmp_path)
    return true, nil
  end
  if os.execute == nil then
    return false, "os_execute_unavailable"
  end
  local mkdir_cmd = nil
  if is_windows_host() then
    mkdir_cmd = "mkdir " .. shell_quote_windows(CONFIG.bridge_dir) .. " >NUL 2>NUL"
  else
    mkdir_cmd = "mkdir -p " .. shell_quote(CONFIG.bridge_dir)
  end
  local ok = os.execute(mkdir_cmd)
  if ok == true or ok == 0 then
    return true, nil
  end
  return false, "mkdir_failed"
end

local function write_text_atomic(path, tmp_path, content)
  local ok, err = ensure_bridge_dir()
  if not ok then
    return false, err
  end
  local handle, open_err = io.open(tmp_path, "w")
  if handle == nil then
    return false, open_err
  end
  handle:write(content)
  handle:close()
  local renamed, rename_err = os.rename(tmp_path, path)
  if not renamed and is_windows_host() then
    os.remove(path)
    renamed, rename_err = os.rename(tmp_path, path)
  end
  if not renamed then
    os.remove(tmp_path)
    return false, rename_err
  end
  return true, nil
end

local function read_text(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function move_in_range(move)
  return move == 0 or move == 0xFFFF or move == 0xFFFFFFFF or move <= MAX_MOVES
end

local function battlemon_is_zero(base)
  if read_u16(base + OFF_SPECIES) ~= 0 then
    return false
  end
  if read_u8(base + OFF_LEVEL) ~= 0 then
    return false
  end
  if read_u32(base + OFF_MAX_HP) ~= 0 then
    return false
  end
  for i = 0, 3 do
    if read_u16(base + OFF_MOVES + i * 2) ~= 0 then
      return false
    end
  end
  return true
end

local function battlemon_is_plausible(base)
  local species = read_u16(base + OFF_SPECIES)
  local level = read_u8(base + OFF_LEVEL)
  local hp = read_s32(base + OFF_HP)
  local max_hp = read_u32(base + OFF_MAX_HP)
  local type1 = read_u8(base + OFF_TYPE1)
  local type2 = read_u8(base + OFF_TYPE2)
  local nonzero_move = false

  if species == 0 or species > MAX_SPECIES then
    return false
  end
  if level == 0 or level > MAX_LEVEL then
    return false
  end
  if max_hp == 0 or max_hp > MAX_HP then
    return false
  end
  if hp < 0 or hp > max_hp then
    return false
  end
  if type1 > MAX_TYPE or type2 > MAX_TYPE then
    return false
  end

  for i = 0, 3 do
    local move = read_u16(base + OFF_MOVES + i * 2)
    local pp = read_u8(base + OFF_MOVE_PP_CUR + i)
    if not move_in_range(move) then
      return false
    end
    if pp > MAX_PP then
      return false
    end
    if move ~= 0 then
      nonzero_move = true
    end
  end

  if not nonzero_move then
    return false
  end

  for i = 0, NUM_STATS - 1 do
    local stat_change = read_u8(base + OFF_STAT_CHANGES + i)
    if stat_change > 12 then
      return false
    end
  end

  return true
end

local function context_header_is_plausible(ctx)
  local command = read_u32(ctx + OFFSET_COMMAND)
  local command_next = read_u32(ctx + OFFSET_COMMAND_NEXT)
  local battlers_on_field = read_u32(ctx + OFFSET_BATTLERS_ON_FIELD)
  local move_no_temp = read_u32(ctx + OFFSET_MOVE_NO_TEMP)
  local move_no_cur = read_u32(ctx + OFFSET_MOVE_NO_CUR)
  local move_no_prev = read_u32(ctx + OFFSET_MOVE_NO_PREV)
  local active_control_fields = command ~= 0
    or command_next ~= 0
    or move_no_temp ~= 0
    or move_no_cur ~= 0
    or move_no_prev ~= 0

  if command >= CONTROLLER_COMMAND_MAX then
    return false
  end
  if command_next >= CONTROLLER_COMMAND_MAX then
    return false
  end
  if battlers_on_field ~= 0 and battlers_on_field ~= 2 and battlers_on_field ~= 4 then
    return false
  end
  if battlers_on_field == 0 and not active_control_fields then
    return false
  end
  if not move_in_range(move_no_temp) then
    return false
  end
  if not move_in_range(move_no_cur) then
    return false
  end
  if not move_in_range(move_no_prev) then
    return false
  end

  return true
end

local function context_is_plausible(ctx)
  if ctx < ARM9_SCAN_START or ctx > ARM9_SCAN_END - OFFSET_BATTLERS_ON_FIELD - 4 then
    return false
  end
  if not context_header_is_plausible(ctx) then
    return false
  end

  local mon0 = ctx + OFFSET_BATTLEMONS
  local mon1 = mon0 + BATTLEMON_STRIDE
  local mon2 = mon1 + BATTLEMON_STRIDE
  local mon3 = mon2 + BATTLEMON_STRIDE

  if not battlemon_is_plausible(mon0) then
    return false
  end
  if not battlemon_is_plausible(mon1) then
    return false
  end
  if not (battlemon_is_zero(mon2) or battlemon_is_plausible(mon2)) then
    return false
  end
  if not (battlemon_is_zero(mon3) or battlemon_is_plausible(mon3)) then
    return false
  end

  return true
end

local function align_down(value, alignment)
  return value - (value % alignment)
end

local function validate_context_from_mon(mon0)
  if not battlemon_is_plausible(mon0) then
    return nil
  end
  local ctx = mon0 - OFFSET_BATTLEMONS
  if context_is_plausible(ctx) then
    return ctx
  end
  return nil
end

local function find_battle_context_in_range(first_mon, last_mon)
  for mon0 = first_mon, last_mon, SCAN_STEP do
    local ctx = validate_context_from_mon(mon0)
    if ctx ~= nil then
      return ctx
    end
  end
  return nil
end

local function find_battle_context_near_hint(ctx_hint, first_mon, last_mon)
  if ctx_hint == nil then
    return nil, nil, nil
  end

  local center_mon = ctx_hint + OFFSET_BATTLEMONS
  if center_mon < first_mon or center_mon > last_mon then
    return nil, nil, nil
  end

  local near_first_mon = math.max(first_mon, center_mon - CONFIG.near_ctx_scan_radius)
  local near_last_mon = math.min(last_mon, center_mon + CONFIG.near_ctx_scan_radius)
  local center_aligned = align_down(center_mon, SCAN_STEP)
  local max_distance = math.max(center_aligned - near_first_mon, near_last_mon - center_aligned)

  for distance = 0, max_distance, SCAN_STEP do
    local forward = center_aligned + distance
    if forward >= near_first_mon and forward <= near_last_mon then
      local ctx = validate_context_from_mon(forward)
      if ctx ~= nil then
        return ctx, near_first_mon, near_last_mon
      end
    end

    if distance ~= 0 then
      local backward = center_aligned - distance
      if backward >= near_first_mon and backward <= near_last_mon then
        local ctx = validate_context_from_mon(backward)
        if ctx ~= nil then
          return ctx, near_first_mon, near_last_mon
        end
      end
    end
  end

  return nil, near_first_mon, near_last_mon
end

local function find_battle_context(ctx_hint)
  local first_mon = ARM9_SCAN_START + OFFSET_BATTLEMONS
  local last_mon = ARM9_SCAN_END - (OFFSET_BATTLERS_ON_FIELD + 4 - OFFSET_BATTLEMONS)

  local ctx, near_first_mon, near_last_mon = find_battle_context_near_hint(ctx_hint, first_mon, last_mon)
  if ctx ~= nil then
    return ctx
  end

  if near_first_mon ~= nil and first_mon < near_first_mon then
    ctx = find_battle_context_in_range(first_mon, near_first_mon - SCAN_STEP)
    if ctx ~= nil then
      return ctx
    end
  end

  if near_last_mon ~= nil and near_last_mon < last_mon then
    ctx = find_battle_context_in_range(near_last_mon + SCAN_STEP, last_mon)
    if ctx ~= nil then
      return ctx
    end
  end

  if near_first_mon == nil then
    ctx = find_battle_context_in_range(first_mon, last_mon)
    if ctx ~= nil then
      return ctx
    end
  end

  return nil
end

local function read_battlemon(base)
  local moves = {}
  local pp = {}
  local stat_changes = {}
  for i = 0, 3 do
    moves[#moves + 1] = read_u16(base + OFF_MOVES + i * 2)
    pp[#pp + 1] = read_u8(base + OFF_MOVE_PP_CUR + i)
  end
  for i = 0, NUM_STATS - 1 do
    stat_changes[#stat_changes + 1] = read_u8(base + OFF_STAT_CHANGES + i)
  end

  return {
    base = base,
    species = read_u16(base + OFF_SPECIES),
    level = read_u8(base + OFF_LEVEL),
    hp = read_s32(base + OFF_HP),
    max_hp = read_u32(base + OFF_MAX_HP),
    status = read_u32(base + OFF_STATUS),
    status2 = read_u32(base + OFF_STATUS2),
    item = read_u16(base + OFF_ITEM),
    exp = read_u32(base + OFF_EXP),
    ability = read_u8(base + OFF_ABILITY),
    friendship = read_u8(base + OFF_FRIENDSHIP),
    weight = read_u32(base + OFF_WEIGHT),
    move_effect_flags = read_u32(base + OFF_MOVE_EFFECT_FLAGS),
    stat_changes = stat_changes,
    moves = moves,
    pp = pp,
  }
end

local function infer_battlers_on_field(raw_value, battlers)
  if raw_value == 2 or raw_value == 4 then
    return raw_value
  end
  if battlemon_is_zero(battlers[3].base) and battlemon_is_zero(battlers[4].base) then
    return 2
  end
  return 4
end

local function normalize_battler(mon)
  if mon == nil then
    return nil
  end

  local present = not battlemon_is_zero(mon.base)

  local status_flags = {}
  local primary_status = "healthy"
  if present and band_u32(mon.status, STATUS_SLEEP) ~= 0 then
    status_flags[#status_flags + 1] = "sleep"
    primary_status = "sleep"
  end
  if present and band_u32(mon.status, STATUS_BAD_POISON) ~= 0 then
    status_flags[#status_flags + 1] = "bad_poison"
    if primary_status == "healthy" then
      primary_status = "bad_poison"
    end
  end
  if present and band_u32(mon.status, STATUS_POISON) ~= 0 then
    status_flags[#status_flags + 1] = "poison"
    if primary_status == "healthy" then
      primary_status = "poison"
    end
  end
  if present and band_u32(mon.status, STATUS_BURN) ~= 0 then
    status_flags[#status_flags + 1] = "burn"
    if primary_status == "healthy" then
      primary_status = "burn"
    end
  end
  if present and band_u32(mon.status, STATUS_FREEZE) ~= 0 then
    status_flags[#status_flags + 1] = "freeze"
    if primary_status == "healthy" then
      primary_status = "freeze"
    end
  end
  if present and band_u32(mon.status, STATUS_PARALYSIS) ~= 0 then
    status_flags[#status_flags + 1] = "paralysis"
    if primary_status == "healthy" then
      primary_status = "paralysis"
    end
  end

  local stat_stages = {}
  local boosted_stats = {}
  local lowered_stats = {}
  for _, index in ipairs(STAT_STAGE_ORDER) do
    local key = STAT_STAGE_KEYS[index]
    local raw_stage = 6
    if present then
      raw_stage = mon.stat_changes[index] or 6
    end
    local delta = raw_stage - 6
    stat_stages[key] = delta
    if delta > 0 then
      boosted_stats[#boosted_stats + 1] = key
    elseif delta < 0 then
      lowered_stats[#lowered_stats + 1] = key
    end
  end

  return {
    battler_id = nil,
    role = nil,
    present = present,
    species = mon.species,
    level = mon.level,
    hp = mon.hp,
    max_hp = mon.max_hp,
    status = mon.status,
    status2 = mon.status2,
    primary_status = primary_status,
    status_flags = status_flags,
    item = mon.item,
    ability = mon.ability,
    friendship = mon.friendship,
    weight = mon.weight,
    move_effect_flags = mon.move_effect_flags,
    stat_changes = mon.stat_changes,
    stat_stages = stat_stages,
    boosted_stats = boosted_stats,
    lowered_stats = lowered_stats,
    has_stat_boosts = #boosted_stats > 0,
    has_stat_drops = #lowered_stats > 0,
    moves = mon.moves,
    pp = mon.pp,
  }
end

local function read_state(ctx)
  local battlers = {}
  for i = 0, 3 do
    battlers[i + 1] = read_battlemon(ctx + OFFSET_BATTLEMONS + i * BATTLEMON_STRIDE)
  end
  local raw_battlers_on_field = read_u32(ctx + OFFSET_BATTLERS_ON_FIELD)

  return {
    in_battle = true,
    ctx = ctx,
    command = read_u32(ctx + OFFSET_COMMAND),
    command_next = read_u32(ctx + OFFSET_COMMAND_NEXT),
    battle_status = read_u32(ctx + OFFSET_BATTLESTATUS),
    battle_status2 = read_u32(ctx + OFFSET_BATTLESTATUS2),
    damage = read_s32(ctx + OFFSET_DAMAGE),
    hit_damage = read_s32(ctx + OFFSET_HIT_DAMAGE),
    move_no_temp = read_u32(ctx + OFFSET_MOVE_NO_TEMP),
    move_no_cur = read_u32(ctx + OFFSET_MOVE_NO_CUR),
    battlers_on_field_raw = raw_battlers_on_field,
    battlers_on_field = infer_battlers_on_field(raw_battlers_on_field, battlers),
    battlers = battlers,
    player = battlers[1],
    enemy = battlers[2],
    player_partner = battlers[3],
    enemy_partner = battlers[4],
  }
end

local tracker = {
  ctx = nil,
  ctx_hint = nil,
  rescan_in = 0,
  frame = 0,
  battle_serial = 0,
  session_id = nil,
  in_battle_last_frame = false,
  last_summary = nil,
  last_command_id = nil,
  last_command_status = "idle",
  last_command_error = nil,
  last_command_file = nil,
  last_invalid_command_file = nil,
  completed_command_ids = {},
  current_command = nil,
  input_queue = nil,
}

local function refresh_state()
  if tracker.ctx ~= nil and context_is_plausible(tracker.ctx) then
    tracker.ctx_hint = tracker.ctx
    return read_state(tracker.ctx)
  end

  if tracker.rescan_in > 0 then
    tracker.rescan_in = tracker.rescan_in - 1
    return nil
  end

  tracker.rescan_in = CONFIG.rescan_interval_frames
  tracker.ctx = find_battle_context(tracker.ctx or tracker.ctx_hint)
  if tracker.ctx == nil then
    return nil
  end
  tracker.ctx_hint = tracker.ctx
  return read_state(tracker.ctx)
end

local function update_session(state)
  if state == nil then
    tracker.ctx = nil
    if tracker.in_battle_last_frame then
      tracker.current_command = nil
      tracker.input_queue = nil
    end
    tracker.in_battle_last_frame = false
    tracker.session_id = nil
    return
  end

  if not tracker.in_battle_last_frame or tracker.ctx ~= state.ctx or tracker.session_id == nil then
    tracker.battle_serial = tracker.battle_serial + 1
    tracker.session_id = string.format("%08X-%d", state.ctx, tracker.battle_serial)
    tracker.current_command = nil
    tracker.input_queue = nil
  end
  tracker.ctx = state.ctx
  tracker.ctx_hint = state.ctx
  tracker.in_battle_last_frame = true
end

local function build_summary(state, phase)
  if state == nil then
    return "battle=0"
  end
  return string.format(
    "battle=1 session=%s phase=%s ctx=%s cmd=%d next=%d player=%d@%d/%d enemy=%d@%d/%d",
    tracker.session_id or "none",
    phase,
    hex8(state.ctx),
    state.command,
    state.command_next,
    state.player.species,
    state.player.hp,
    state.player.max_hp,
    state.enemy.species,
    state.enemy.hp,
    state.enemy.max_hp
  )
end

local function set_last_command_status(command_id, status, err)
  tracker.last_command_id = command_id
  tracker.last_command_status = status
  tracker.last_command_error = err
end

local function finalize_command(command_id, status, err)
  tracker.completed_command_ids[command_id] = status
  if tracker.current_command ~= nil and tracker.current_command.command_id == command_id then
    tracker.current_command = nil
    tracker.input_queue = nil
  end
  set_last_command_status(command_id, status, err)
end

local function begin_input_queue(steps)
  if joypad_set == nil then
    return false, "joypad_unavailable"
  end
  tracker.input_queue = {
    steps = steps,
    step_index = 1,
    frames_left = steps[1].hold_frames,
    post_status = nil,
  }
  return true, nil
end

local function button_map_from_list(buttons)
  local result = {}
  for _, name in ipairs(buttons) do
    result[name] = true
  end
  return result
end

local function hold_step(buttons, hold_frames)
  return {
    buttons = button_map_from_list(buttons),
    hold_frames = hold_frames or 1,
  }
end

local function move_slot_input_steps(slot_index)
  local steps = {
    hold_step({ "Up", "Left" }, 2),
  }
  if slot_index == 2 then
    steps[#steps + 1] = hold_step({ "Right" }, 2)
  elseif slot_index == 3 then
    steps[#steps + 1] = hold_step({ "Down" }, 2)
  elseif slot_index == 4 then
    steps[#steps + 1] = hold_step({ "Down" }, 2)
    steps[#steps + 1] = hold_step({ "Right" }, 2)
  end
  steps[#steps + 1] = hold_step({ "A" }, 2)
  return steps
end

local function target_input_steps(command, state)
  if state.battlers_on_field <= 2 then
    return {
      hold_step({ "A" }, 2),
    }, nil
  end
  if command.target_battler == 1 then
    return {
      hold_step({ "A" }, 2),
    }, nil
  end
  if command.target_battler == 3 then
    return {
      hold_step({ "Right" }, 2),
      hold_step({ "A" }, 2),
    }, nil
  end
  return nil, "unsupported_target_battler"
end

local function determine_phase(state)
  if state == nil then
    return "no_battle"
  end
  if state.command == CONTROLLER_COMMAND_SELECTION_SCREEN_INPUT then
    return "fight_menu"
  end
  if state.command == CONTROLLER_COMMAND_FIGHT_INPUT or state.command == CONTROLLER_COMMAND_23 then
    return "commit_window"
  end
  if state.command >= CONTROLLER_COMMAND_RUN_SCRIPT and state.command <= CONTROLLER_COMMAND_39 then
    return "resolving"
  end
  return "unknown"
end

local function encode_state_snapshot(state, phase)
  if state == nil then
    return {
      schema_version = CONFIG.schema_version,
      frame = tracker.frame,
      session_id = nil,
      in_battle = false,
      ctx = nil,
      phase = "no_battle",
      raw = nil,
      battle_status = nil,
      battle_status2 = nil,
      damage = nil,
      hit_damage = nil,
      battlers_on_field = nil,
      battlers = {},
      player = nil,
      enemy = nil,
      player_partner = nil,
      enemy_partner = nil,
      capabilities = {
        joypad = joypad_set ~= nil,
        savestate_slot = savestate_save ~= nil,
        memory_write_u32 = raw_write_u32 ~= nil,
      },
      command_stage = tracker.current_command and tracker.current_command.stage or nil,
      last_command_id = tracker.last_command_id,
      last_command_status = tracker.last_command_status,
      last_command_error = tracker.last_command_error,
    }
  end

  local battlers = {}
  for i, mon in ipairs(state.battlers) do
    local battler = normalize_battler(mon)
    if battler ~= nil then
      battler.battler_id = i - 1
      battler.role = BATTLE_ROLE_NAMES[i] or ("battler_" .. tostring(i - 1))
    end
    battlers[i] = battler
  end

  return {
    schema_version = CONFIG.schema_version,
    frame = tracker.frame,
    session_id = tracker.session_id,
    in_battle = true,
    ctx = state.ctx,
    phase = phase,
    raw = {
      command = state.command,
      command_next = state.command_next,
      move_no_temp = state.move_no_temp,
      move_no_cur = state.move_no_cur,
      battlers_on_field = state.battlers_on_field_raw,
    },
    battle_status = state.battle_status,
    battle_status2 = state.battle_status2,
    damage = state.damage,
    hit_damage = state.hit_damage,
    battlers_on_field = state.battlers_on_field,
    battlers = battlers,
    player = battlers[1],
    enemy = battlers[2],
    player_partner = battlers[3],
    enemy_partner = battlers[4],
    capabilities = {
      joypad = joypad_set ~= nil,
      savestate_slot = savestate_save ~= nil,
      memory_write_u32 = raw_write_u32 ~= nil,
    },
    command_stage = tracker.current_command and tracker.current_command.stage or nil,
    last_command_id = tracker.last_command_id,
    last_command_status = tracker.last_command_status,
    last_command_error = tracker.last_command_error,
  }
end

local function write_state_snapshot(state, phase)
  local payload = encode_state_snapshot(state, phase)
  local ok, err = write_text_atomic(CONFIG.state_path, CONFIG.state_tmp_path, json_encode(payload) .. "\n")
  if not ok then
    set_last_command_status(tracker.last_command_id, "state_write_failed", err)
  end
end

local function load_command_file()
  local content = read_text(CONFIG.command_path)
  if content == nil then
    tracker.last_command_file = nil
    tracker.last_invalid_command_file = nil
    return nil
  end
  tracker.last_command_file = content
  local ok, data = pcall(json_decode, content)
  if not ok then
    if tracker.last_invalid_command_file ~= content then
      tracker.last_invalid_command_file = content
      set_last_command_status(tracker.last_command_id, "invalid_command_json", tostring(data))
    end
    return nil
  end
  tracker.last_invalid_command_file = nil
  return data
end

local function validate_command_shape(command)
  if type(command) ~= "table" then
    return false, "command_root_must_be_object"
  end
  if command.schema_version ~= CONFIG.schema_version then
    return false, "unsupported_schema_version"
  end
  if type(command.command_id) ~= "string" or command.command_id == "" then
    return false, "command_id_required"
  end
  if type(command.action) ~= "string" or command.action == "" then
    return false, "action_required"
  end
  if type(command.for_session_id) ~= "string" or command.for_session_id == "" then
    return false, "for_session_id_required"
  end
  if command.expected_phase ~= nil and type(command.expected_phase) ~= "string" then
    return false, "expected_phase_must_be_string"
  end
  if command.action == "select_move" then
    if type(command.move_id) ~= "number" or command.move_id < 1 or command.move_id > MAX_MOVES then
      return false, "move_id_out_of_range"
    end
    if command.target_battler ~= nil and type(command.target_battler) ~= "number" then
      return false, "target_battler_must_be_number"
    end
    return true, nil
  end
  if command.action == "press_buttons" then
    if type(command.buttons) ~= "table" or #command.buttons == 0 then
      return false, "buttons_required"
    end
    for _, button in ipairs(command.buttons) do
      if type(button) ~= "string" then
        return false, "button_names_must_be_strings"
      end
      if not VALID_BUTTONS[button] then
        return false, "unsupported_button_name"
      end
    end
    if command.hold_frames ~= nil and (type(command.hold_frames) ~= "number" or command.hold_frames < 1) then
      return false, "hold_frames_out_of_range"
    end
    return true, nil
  end
  if command.action == "save_state" then
    if type(command.slot) ~= "number" or command.slot < 0 then
      return false, "slot_out_of_range"
    end
    return true, nil
  end
  return false, "unsupported_action"
end

local function pick_placeholder_slot(state)
  for idx, move in ipairs(state.player.moves) do
    if move ~= 0 and state.player.pp[idx] > 0 then
      return idx
    end
  end
  for idx, move in ipairs(state.player.moves) do
    if move ~= 0 then
      return idx
    end
  end
  return nil
end

local function maybe_start_command(command, state, phase)
  local ok, err = validate_command_shape(command)
  if not ok then
    set_last_command_status(command.command_id, "invalid_command", err)
    tracker.completed_command_ids[command.command_id] = "invalid_command"
    return
  end
  if tracker.completed_command_ids[command.command_id] ~= nil then
    return
  end
  if state == nil or tracker.session_id == nil then
    return
  end
  if command.for_session_id ~= tracker.session_id then
    tracker.completed_command_ids[command.command_id] = "stale_session"
    set_last_command_status(command.command_id, "stale_session", nil)
    return
  end
  if tracker.current_command ~= nil then
    return
  end

  tracker.current_command = {
    command_id = command.command_id,
    action = command.action,
    expected_phase = command.expected_phase,
    for_session_id = command.for_session_id,
    move_id = command.move_id,
    target_battler = command.target_battler,
    buttons = command.buttons,
    hold_frames = command.hold_frames,
    slot = command.slot,
    placeholder_slot = nil,
    stage = "pending",
  }

  if command.action == "select_move" then
    tracker.current_command.stage = "awaiting_slot"
  elseif command.action == "press_buttons" then
    tracker.current_command.stage = "awaiting_input"
  elseif command.action == "save_state" then
    tracker.current_command.stage = "awaiting_save"
  end

  set_last_command_status(command.command_id, "accepted", nil)

  if command.expected_phase ~= nil and command.expected_phase ~= phase then
    return
  end
end

local function apply_press_buttons(command)
  local steps = {
    hold_step(command.buttons, command.hold_frames or 1),
  }
  local ok, err = begin_input_queue(steps)
  if not ok then
    finalize_command(command.command_id, "failed", err)
    return
  end
  command.stage = "input_running"
end

local function apply_save_state(command)
  if savestate_save == nil then
    finalize_command(command.command_id, "failed", "savestate_slot_unavailable")
    return
  end
  local ok, err = pcall(savestate_save, command.slot)
  if not ok then
    finalize_command(command.command_id, "failed", tostring(err))
    return
  end
  finalize_command(command.command_id, "applied", nil)
end

local function run_select_move_command(command, state, phase)
  if command.stage == "awaiting_slot" then
    if command.expected_phase ~= nil and command.expected_phase ~= phase then
      return
    end
    if phase ~= "fight_menu" then
      return
    end
    local slot = pick_placeholder_slot(state)
    if slot == nil then
      finalize_command(command.command_id, "failed", "no_placeholder_slot")
      return
    end
    command.placeholder_slot = slot
    local ok, err = begin_input_queue(move_slot_input_steps(slot))
    if not ok then
      finalize_command(command.command_id, "failed", err)
      return
    end
    if command.target_battler ~= nil then
      command.stage = "awaiting_target"
    else
      command.stage = "awaiting_commit"
    end
    return
  end

  if command.stage == "awaiting_target" then
    if tracker.input_queue ~= nil then
      return
    end
    if phase ~= "target_select" and phase ~= "fight_menu" then
      command.stage = "awaiting_commit"
      return
    end
    local steps, err = target_input_steps(command, state)
    if steps == nil then
      finalize_command(command.command_id, "failed", err)
      return
    end
    local ok, queue_err = begin_input_queue(steps)
    if not ok then
      finalize_command(command.command_id, "failed", queue_err)
      return
    end
    command.stage = "awaiting_commit"
    return
  end

  if command.stage == "awaiting_commit" then
    if tracker.input_queue ~= nil then
      return
    end
    if phase ~= "commit_window" then
      return
    end
    local slot = command.placeholder_slot
    if slot == nil or slot < 1 or slot > 4 then
      finalize_command(command.command_id, "failed", "missing_placeholder_slot")
      return
    end
    local slot_index = slot - 1
    local slot_move_addr = state.player.base + OFF_MOVES + slot_index * 2
    local slot_pp_cur_addr = state.player.base + OFF_MOVE_PP_CUR + slot_index
    local slot_pp_max_addr = state.player.base + OFF_MOVE_PP_MAX + slot_index
    local ok0, err0 = write_u16(slot_move_addr, command.move_id)
    if not ok0 then
      finalize_command(command.command_id, "failed", err0)
      return
    end
    local okpp1, errpp1 = write_u8(slot_pp_cur_addr, MAX_PP)
    if not okpp1 then
      finalize_command(command.command_id, "failed", errpp1)
      return
    end
    local okpp2, errpp2 = write_u8(slot_pp_max_addr, MAX_PP)
    if not okpp2 then
      finalize_command(command.command_id, "failed", errpp2)
      return
    end
    local ok1, err1 = write_u32(state.ctx + OFFSET_MOVE_NO_TEMP, command.move_id)
    if not ok1 then
      finalize_command(command.command_id, "failed", err1)
      return
    end
    local ok2, err2 = write_u32(state.ctx + OFFSET_MOVE_NO_CUR, command.move_id)
    if not ok2 then
      finalize_command(command.command_id, "failed", err2)
      return
    end
    command.stage = "awaiting_resolution"
    finalize_command(command.command_id, "applied", nil)
  end
end

local function maybe_apply_current_command(state, phase)
  local command = tracker.current_command
  if command == nil then
    return
  end
  if state == nil or tracker.session_id == nil then
    finalize_command(command.command_id, "failed", "battle_ended")
    return
  end
  if command.for_session_id ~= tracker.session_id then
    finalize_command(command.command_id, "stale_session", nil)
    return
  end

  if command.action == "select_move" then
    run_select_move_command(command, state, phase)
    return
  end
  if command.action == "press_buttons" then
    if command.expected_phase ~= nil and command.expected_phase ~= phase then
      return
    end
    if command.stage == "awaiting_input" then
      apply_press_buttons(command)
      return
    end
    if command.stage == "input_running" and tracker.input_queue == nil then
      finalize_command(command.command_id, "applied", nil)
    end
    return
  end
  if command.action == "save_state" then
    if command.expected_phase ~= nil and command.expected_phase ~= phase then
      return
    end
    if command.stage == "awaiting_save" then
      apply_save_state(command)
    end
  end
end

local function drive_input_queue()
  if tracker.input_queue == nil then
    return
  end
  local step = tracker.input_queue.steps[tracker.input_queue.step_index]
  if step == nil then
    tracker.input_queue = nil
    return
  end
  local ok, err = pcall(joypad_set, step.buttons)
  if not ok then
    local command_id = tracker.current_command and tracker.current_command.command_id or tracker.last_command_id
    tracker.input_queue = nil
    if command_id ~= nil then
      finalize_command(command_id, "failed", tostring(err))
    end
    return
  end
  tracker.input_queue.frames_left = tracker.input_queue.frames_left - 1
  if tracker.input_queue.frames_left > 0 then
    return
  end
  tracker.input_queue.step_index = tracker.input_queue.step_index + 1
  local next_step = tracker.input_queue.steps[tracker.input_queue.step_index]
  if next_step == nil then
    tracker.input_queue = nil
    return
  end
  tracker.input_queue.frames_left = next_step.hold_frames
end

local function draw_lines(lines)
  if gui_text == nil then
    return
  end
  for i, line in ipairs(lines) do
    gui_text(8, 8 + (i - 1) * 10, line)
  end
end

local function tick()
  tracker.frame = tracker.frame + 1
  local state = refresh_state()
  update_session(state)

  local phase = determine_phase(state)
  local command_file = load_command_file()
  if command_file ~= nil then
    maybe_start_command(command_file, state, phase)
  end
  maybe_apply_current_command(state, phase)
  drive_input_queue()

  phase = determine_phase(state)
  write_state_snapshot(state, phase)

  local summary = build_summary(state, phase)
  if summary ~= tracker.last_summary then
    print(summary)
    tracker.last_summary = summary
  end

  if state == nil then
    draw_lines({
      "Battle: no",
      "phase: no_battle",
      "command: " .. tostring(tracker.last_command_status or "idle"),
    })
    return
  end

  draw_lines({
    "Battle: yes",
    "session: " .. (tracker.session_id or "none"),
    "phase: " .. phase,
    "ctx: " .. hex8(state.ctx),
    string.format("cmd: %d next: %d", state.command, state.command_next),
    string.format("move: %d/%d", state.move_no_temp, state.move_no_cur),
    string.format("player: %d lv%d hp %d/%d", state.player.species, state.player.level, state.player.hp, state.player.max_hp),
    string.format("enemy: %d lv%d hp %d/%d", state.enemy.species, state.enemy.level, state.enemy.hp, state.enemy.max_hp),
    "last cmd: " .. tostring(tracker.last_command_status or "idle"),
  })
end

while true do
  tick()
  if frame_advance == nil then
    error("No supported frame advance API found for this Lua environment")
  end
  frame_advance()
end
