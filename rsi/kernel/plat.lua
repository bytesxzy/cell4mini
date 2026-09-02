-- Portable versions of the five OS operations this project needs.
--
-- Everything here used to be a POSIX shell-out (`mkdir -p`, `rm -rf`, `ls`, `sleep`), which is fine
-- on Linux and macOS and silently broken on native Windows, where os.execute runs cmd.exe and none
-- of those exist. That mattered: the generation lock, the state directories and the ARC file listing
-- all went through them, so on Windows the loop would appear to run and write nothing.
--
-- The Windows branch is not emulation; it is the cmd.exe equivalent of each operation, including the
-- one property the lock depends on: `mkdir` fails when the directory already exists, on both.
local M = {}

M.windows = package.config:sub(1, 1) == "\\"

-- cmd.exe tolerates forward slashes in most places and not in others (notably rmdir), so normalise.
local function native(p)
  if M.windows then return (p:gsub("/", "\\")) end
  return p
end

local function q(p)
  if M.windows then return '"' .. native(p) .. '"' end
  return "'" .. p .. "'"
end
M.quote = q

local function ok(v) return v == true or v == 0 end

-- Create a directory and any missing parents. True if it exists afterwards.
function M.mkdirp(path)
  if M.windows then
    -- cmd's mkdir creates intermediate directories already, and errors if the path exists.
    return ok(os.execute("mkdir " .. q(path) .. " 2>nul")) or M.isdir(path)
  end
  return ok(os.execute("mkdir -p " .. q(path))) or M.isdir(path)
end

-- Create exactly one directory, failing if it already exists. This is the atomic operation the
-- generation lock is built on; both shells give it to us.
function M.mkdir_exclusive(path)
  if M.windows then return ok(os.execute("mkdir " .. q(path) .. " 2>nul")) end
  return ok(os.execute("mkdir " .. q(path) .. " 2>/dev/null"))
end

-- Remove a directory tree, or a single file. Never errors if it is not there.
function M.rmrf(path)
  if M.windows then
    os.execute("rmdir /s /q " .. q(path) .. " 2>nul")
    os.execute("del /q " .. q(path) .. " 2>nul")
    return true
  end
  return ok(os.execute("rm -rf " .. q(path)))
end

function M.isdir(path)
  if M.windows then
    return ok(os.execute("if exist " .. q(path .. "\\*") .. " (exit 0) else (exit 1)"))
  end
  return ok(os.execute("test -d " .. q(path)))
end

-- Entry names in a directory, sorted, excluding . and .. -- empty list if the directory is absent.
function M.ls(dir)
  local cmd = M.windows and ("dir /b " .. q(dir) .. " 2>nul") or ("ls -1 " .. q(dir) .. " 2>/dev/null")
  local p = io.popen(cmd)
  if not p then return {} end
  local out = {}
  for line in p:lines() do
    line = line:gsub("%s+$", "")
    if line ~= "" and line ~= "." and line ~= ".." then out[#out + 1] = line end
  end
  p:close()
  table.sort(out)
  return out
end

-- Block for `seconds` (fractional allowed on POSIX; Windows rounds up to whole seconds).
-- `ping -n` is used rather than `timeout /t`, which fails when stdin is redirected -- exactly the
-- case when the loop runs as a scheduled task or a service.
function M.sleep(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then return end
  if M.windows then
    os.execute(string.format("ping -n %d 127.0.0.1 >nul", math.floor(seconds + 1.999)))
  else
    os.execute("sleep " .. tostring(seconds))
  end
end

return M
