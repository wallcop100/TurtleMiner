-- Version: 1.0.0
-- Mobile GPS host (AR-G): a turtle that knows its world position answers GPS pings like
-- `gps host`, between moves only. Called from net.lua's raw modem_message dispatch.
-- Answers only when: st.gps (world coordinates) or an army frame, not lost, facing known, no
-- journaled move in flight, MOBILE_GPS not false, and a modem.
local M = {}

local CH = 65534
local lastHeard = nil   -- os.clock() of the last reply (status: gpsHost)

local function view()
    local ok, nav = pcall(require, "nav")
    if not ok or type(nav) ~= "table" or not nav.view then return nil end
    local st, cfg = nav.view()
    return st, cfg, nav
end

-- Open the GPS channel on every wireless modem (call after modems are opened).
function M.open()
    if not (peripheral and peripheral.getNames) then return end
    local _, cfg = view()
    if cfg and cfg.MOBILE_GPS == false then return end
    for _, n in ipairs(peripheral.getNames()) do
        local okT, t = pcall(peripheral.getType, n)
        if okT and t == "modem" then
            local okW, w = pcall(peripheral.call, n, "isWireless")
            if okW and w then pcall(peripheral.call, n, "open", CH) end
        end
    end
end

-- Position we may announce, or nil.
function M.position()
    local st, cfg, nav = view()
    if type(st) ~= "table" or type(st.pos) ~= "table" then return nil end
    if cfg and cfg.MOBILE_GPS == false then return nil end
    if not (st.gps or st.army ~= nil) then return nil end
    if st.lost or st.facingUnknown then return nil end
    if nav.moving and nav.moving() then return nil end
    local p = st.pos
    if type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then return nil end
    return p
end

-- ev: the raw modem_message event.
function M.onMessage(ev)
    if ev[3] ~= CH or ev[5] ~= "PING" or type(ev[6]) ~= "number" then return end
    local reply = ev[4]
    if type(reply) ~= "number" then return end
    local p = M.position()
    if not p then return end
    local ok = pcall(peripheral.call, ev[2], "transmit", reply, CH, { p.x, p.y, p.z })
    if ok then lastHeard = os.clock() end
end

-- True if this turtle answered a ping recently (for the status table).
function M.active()
    return lastHeard ~= nil and os.clock() - lastHeard < 120
end

return M
