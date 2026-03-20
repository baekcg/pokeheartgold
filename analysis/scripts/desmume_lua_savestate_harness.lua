local script_path = assert(arg[1], "missing script path")
local raw_state_path = assert(arg[2], "missing raw state path")
local arm9_anchor = assert(tonumber(arg[3]), "missing arm9 anchor")
local max_frames = tonumber(arg[4]) or 1
local schedule_path = arg[5]

local ARM9_RAM_BASE = 0x02000000
local STOP_SENTINEL = "__HARNESS_STOP__"

local function load_binary(path)
  local handle = assert(io.open(path, "rb"))
  local content = assert(handle:read("*a"))
  handle:close()
  return content
end

local raw_state = load_binary(raw_state_path)
local raw_len = #raw_state
local overlay = {}
local joypad_calls = 0
local joypad_last_buttons = {}
local savestate_slots = {}
local write_log = {}
local current_frame = 0
local scheduled_writes = {}

local function load_schedule(path)
  if path == nil or path == "" or path == "-" then
    return
  end
  local handle = assert(io.open(path, "r"))
  for line in handle:lines() do
    local frame_s, addr_s, value_s = string.match(line, "^(%d+)%s+(0x[%x]+)%s+(0x[%x]+)$")
    if frame_s ~= nil then
      local frame = tonumber(frame_s)
      local addr = tonumber(addr_s)
      local value = tonumber(value_s)
      if scheduled_writes[frame] == nil then
        scheduled_writes[frame] = {}
      end
      scheduled_writes[frame][#scheduled_writes[frame] + 1] = {
        addr = addr,
        value = value,
      }
    end
  end
  handle:close()
end

local function map_addr(addr)
  local offset = arm9_anchor + (addr - ARM9_RAM_BASE)
  if offset < 0 or offset >= raw_len then
    error(string.format("address 0x%08X is outside the mapped savestate range", addr))
  end
  return offset
end

local function read_byte(addr)
  local offset = map_addr(addr)
  local patched = overlay[offset]
  if patched ~= nil then
    return patched
  end
  return string.byte(raw_state, offset + 1)
end

local function write_byte(addr, value)
  local offset = map_addr(addr)
  overlay[offset] = value % 0x100
end

local function apply_scheduled_writes(frame)
  local entries = scheduled_writes[frame]
  if entries == nil then
    return
  end
  for _, entry in ipairs(entries) do
    for i = 0, 3 do
      write_byte(entry.addr + i, math.floor(entry.value / (0x100 ^ i)))
    end
  end
end

local function write_u32(addr, value)
  write_log[#write_log + 1] = string.format("0x%08X=0x%08X", addr, value)
  for i = 0, 3 do
    write_byte(addr + i, math.floor(value / (0x100 ^ i)))
  end
end

local function write_u16(addr, value)
  write_log[#write_log + 1] = string.format("0x%08X=0x%04X", addr, value % 0x10000)
  for i = 0, 1 do
    write_byte(addr + i, math.floor(value / (0x100 ^ i)))
  end
end

local function write_u8(addr, value)
  write_log[#write_log + 1] = string.format("0x%08X=0x%02X", addr, value % 0x100)
  write_byte(addr, value)
end

local function read_u16(addr)
  return read_byte(addr) + read_byte(addr + 1) * 0x100
end

local function read_u32(addr)
  return read_byte(addr)
    + read_byte(addr + 1) * 0x100
    + read_byte(addr + 2) * 0x10000
    + read_byte(addr + 3) * 0x1000000
end

load_schedule(schedule_path)
apply_scheduled_writes(0)

memory = {
  readbyteunsigned = function(addr)
    return read_byte(addr)
  end,
  readwordunsigned = function(addr)
    return read_u16(addr)
  end,
  readdwordunsigned = function(addr)
    return read_u32(addr)
  end,
  writedword = function(addr, value)
    write_u32(addr, value)
  end,
  writeword = function(addr, value)
    write_u16(addr, value)
  end,
  writebyte = function(addr, value)
    write_u8(addr, value)
  end,
}

mainmemory = {
  read_u8 = memory.readbyteunsigned,
  read_u16_le = memory.readwordunsigned,
  read_u32_le = memory.readdwordunsigned,
  write_u8 = memory.writebyte,
  write_u16_le = memory.writeword,
  write_u32_le = memory.writedword,
}

joypad = {
  set = function(buttons)
    joypad_calls = joypad_calls + 1
    joypad_last_buttons = {}
    for name, pressed in pairs(buttons) do
      if pressed then
        joypad_last_buttons[#joypad_last_buttons + 1] = name
      end
    end
    table.sort(joypad_last_buttons)
  end,
}

savestate = {
  save = function(slot)
    savestate_slots[#savestate_slots + 1] = slot
  end,
}

gui = {
  text = function(_, _, _)
  end,
}

emu = {
  frameadvance = function()
    current_frame = current_frame + 1
    apply_scheduled_writes(current_frame)
    if current_frame >= max_frames then
      error(STOP_SENTINEL)
    end
  end,
}

local ok, err = pcall(dofile, script_path)
if not ok and not string.find(tostring(err), STOP_SENTINEL, 1, true) then
  io.stderr:write(tostring(err), "\n")
  os.exit(1)
end

print("HARNESS_FRAMES=" .. tostring(current_frame))
print("HARNESS_JOYPAD_CALLS=" .. tostring(joypad_calls))
print("HARNESS_LAST_BUTTONS=" .. table.concat(joypad_last_buttons, ","))
print("HARNESS_SAVESTATE_SLOTS=" .. table.concat(savestate_slots, ","))
for _, entry in ipairs(write_log) do
  print("HARNESS_WRITE=" .. entry)
end
