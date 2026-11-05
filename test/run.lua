-- Version: 1.0.0
-- Test runner for the TurtleMiner simulator.
--
--   lua5.4 test/run.lua              run the sim self-test and every scenario
--   lua5.4 test/run.lua 3            run scenarios whose name matches "3" (prefix/substring)
--   lua5.4 test/run.lua selftest     run only the simulator self-test
--   SIM_VERBOSE=1 lua5.4 test/run.lua 1    echo program output / sim log to stderr
--   SIM_MINER_DIR=/path/to/miner lua5.4 test/run.lua   load miner files from elsewhere
--
-- Each scenario runs in its own lua5.4 process (with a host timeout) so one
-- hang or crash can't take the others down. Prints PASS/FAIL/SKIP per
-- scenario; exits non-zero if anything FAILed.

local script = arg and arg[0] or "test/run.lua"
local testDir = script:match("^(.*)/[^/]*$") or "."
local root = testDir:match("^(.*)/[^/]*$") or "."
if testDir == "." then root = ".." end

package.path = testDir .. "/sim/?.lua;" .. testDir .. "/lib/?.lua;" .. testDir .. "/?.lua;" .. package.path

local HOST_TIMEOUT = tonumber(os.getenv("SIM_HOST_TIMEOUT") or "") or 300

local function listScenarios()
    local names = { "selftest" }
    local p = io.popen('ls "' .. testDir .. '/scenarios" 2>/dev/null')
    if p then
        for f in p:lines() do
            local n = f:match("^(.+)%.lua$")
            if n then names[#names + 1] = n end
        end
        p:close()
    end
    table.sort(names, function(a, b)
        if a == "selftest" then return b ~= "selftest" end
        if b == "selftest" then return false end
        return a < b
    end)
    return names
end

local function matches(name, pat)
    if pat == nil then return true end
    if name == pat then return true end
    local num = tonumber(pat)
    if num then
        local n = tonumber(name:match("^(%d+)"))
        return n == num
    end
    return name:find(pat, 1, true) ~= nil
end

-- Run one scenario in-process. Prints one result line last.
local function runOne(name)
    local sim = require("sim")
    sim.REPO = root
    local H = require("harness")
    H.init(sim, root)
    local scen
    if name == "selftest" then
        scen = dofile(testDir .. "/sim_selftest.lua")
    else
        scen = dofile(testDir .. "/scenarios/" .. name .. ".lua")
    end
    local status, msg = H.runScenario(name, scen)
    if msg then
        msg = msg:gsub("\n%s*", " | ")
        if #msg > 2000 then msg = msg:sub(1, 2000) .. "..." end
    end
    print(string.format("%s %s%s", status, name, msg and msg ~= "" and (": " .. msg) or ""))
    return status
end

if arg[1] == "--one" then
    local status = runOne(arg[2])
    os.exit(status == "FAIL" and 1 or 0)
end

local pattern = arg[1]
local names = listScenarios()
local counts = { PASS = 0, FAIL = 0, SKIP = 0 }
local failed = {}
local any = false
local lua = os.getenv("SIM_LUA") or "lua5.4"
local hasTimeout = os.execute("command -v timeout >/dev/null 2>&1")

for _, name in ipairs(names) do
    if matches(name, pattern) then
        any = true
        local cmd = string.format('%s%s "%s" --one "%s" 2>&1',
            hasTimeout and ("timeout " .. HOST_TIMEOUT .. " ") or "", lua, script, name)
        local p = io.popen(cmd)
        local lines = {}
        for l in p:lines() do lines[#lines + 1] = l end
        local ok, _, code = p:close()
        local last = lines[#lines] or ""
        local status = last:match("^(%u+) ")
        if code == 124 then
            status = "FAIL"
            lines[#lines + 1] = "FAIL " .. name .. ": host timeout after " .. HOST_TIMEOUT .. "s (pure-Lua infinite loop?)"
        elseif status ~= "PASS" and status ~= "FAIL" and status ~= "SKIP" then
            status = "FAIL"
            lines[#lines + 1] = "FAIL " .. name .. ": runner crashed (exit " .. tostring(code) .. ")"
        end
        for _, l in ipairs(lines) do print(l) end
        counts[status] = counts[status] + 1
        if status == "FAIL" then failed[#failed + 1] = name end
    end
end

if not any then
    print("no scenario matches '" .. tostring(pattern) .. "'")
    os.exit(2)
end
print(string.format("\n%d passed, %d failed, %d skipped%s", counts.PASS, counts.FAIL, counts.SKIP,
    #failed > 0 and (" (failed: " .. table.concat(failed, ", ") .. ")") or ""))
os.exit(counts.FAIL > 0 and 1 or 0)
