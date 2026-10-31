-- Version: 1.0.0
-- Self-test of the simulator with tiny stub programs, so the harness is proven
-- before (and independently of) the real miner modules.
-- Run: lua5.4 test/run.lua selftest

return {
    title = "simulator self-test",
    needs = {},
    run = function(sim, H)
        local checks = 0
        local function ok(cond, msg, ...)
            checks = checks + 1
            H.check(cond, msg, ...)
        end

        -- 1. moves, digs, fuel, files ------------------------------------------------
        local w = sim.world()
        local t = sim.turtle(w, { id = 1, pos = { x = 0, y = 0, z = 0 }, facing = 0, fuel = 100, install = false })
        t.fs:write("prog.lua", [[
            local log = {}
            for i = 1, 3 do
                if turtle.detect() then assert(turtle.dig()) end
                assert(turtle.forward())
            end
            turtle.digUp(); assert(turtle.up())
            assert(turtle.turnRight())
            local okb, why = turtle.dig()
            local h = fs.open("out.txt", "w"); h.writeLine("hello"); h.write("world"); h.close()
            h = fs.open("out.txt", "a"); h.writeLine("!"); h.close()
            h = fs.open("out.txt", "r"); local l1 = h.readLine(); local rest = h.readAll(); h.close()
            sleep(5)
            return l1, rest, turtle.getFuelLevel(), os.getComputerID(), textutils.serialize({a=1,{2}})
        ]])
        local r = sim.boot(t, { "prog" })
        ok(r.status == "exit", "stub program should exit, got %s %s", r.status, tostring(r.err))
        ok(H.samePos(t.pos, { x = 0, y = 1, z = -3 }), "position after moves wrong: %s", H.fmtPos(t.pos))
        ok(t.facing == 1, "facing should be 1, got %d", t.facing)
        ok(t.fuel == 96, "fuel should be 96, got %s", tostring(t.fuel))
        ok(r.ret[1] == "hello" and r.ret[2] == "world!\n", "file round trip failed: %s / %s", tostring(r.ret[1]), tostring(r.ret[2]))
        ok(r.ret[3] == 96 and r.ret[4] == 1, "fuel/id from program wrong")
        ok(sim.textutils.unserialize(r.ret[5]).a == 1, "serialize round trip failed")
        ok(w:isAir(0, 0, -1) and w:isAir(0, 0, -3) and w:isAir(0, 1, -3), "dug cells not air")
        ok(w:get(1, 1, -3) == "minecraft:air", "dig after turn should have dug east cell")
        ok(t.inv[1] and t.inv[1].name == "minecraft:cobblestone" and t.inv[1].count == 5,
            "inventory should hold 5 cobblestone, got %s", t.inv[1] and (t.inv[1].name .. " x" .. t.inv[1].count) or "nil")
        ok(sim.now >= 5, "sleep should advance the sim clock")

        -- 2. bedrock, gravel column, mobs, out of fuel ----------------------------
        sim.reset()
        w = sim.world()
        t = sim.turtle(w, { id = 2, pos = { x = 0, y = -59, z = 0 }, facing = 0, fuel = 50, install = false })
        w:gravelColumn(0, -59, -1, 20)
        w:mob(0, -59, -3, 3)
        t.fs:write("p.lua", [[
            local a, b = turtle.digDown()
            local digs = 0
            while not turtle.forward() do
                if turtle.detect() then turtle.dig(); digs = digs + 1 else turtle.attack() end
                if digs > 50 then break end
            end
            turtle.dig() -- next cell is plain stone
            local fwd = turtle.forward()
            local hits = 0
            while not turtle.forward() do turtle.attack(); hits = hits + 1; if hits > 10 then break end end
            return a, b, digs, fwd, hits
        ]])
        r = sim.boot(t, { "p" })
        ok(r.status == "exit", "p should exit: %s %s", r.status, tostring(r.err))
        ok(r.ret[1] == false and r.ret[2] == "Unbreakable block", "bedrock should be unbreakable, got %s %s", tostring(r.ret[1]), tostring(r.ret[2]))
        ok(r.ret[3] == 20, "20-high gravel column should need 20 digs, got %s", tostring(r.ret[3]))
        ok(r.ret[5] == 3, "mob should need 3 attacks, got %s", tostring(r.ret[5]))
        ok(t.pos.z == -3, "turtle should end at z=-3, got %s", H.fmtPos(t.pos))
        sim.reset()
        w = sim.world()
        t = sim.turtle(w, { id = 3, pos = { x = 0, y = 0, z = 0 }, fuel = 0, install = false })
        w:set(0, 0, -1, "air")
        t.fs:write("p.lua", "return turtle.forward()")
        r = sim.boot(t, { "p" })
        ok(r.ret[1] == false and r.ret[2] == "Out of fuel", "no fuel move should fail with 'Out of fuel'")

        -- 3. chests: drop, suck, peripheral, refuel ----------------------------------
        sim.reset()
        w = sim.world()
        w:chest(0, 0, 1, { { name = "minecraft:coal", count = 10 } }, { size = 2 })
        t = sim.turtle(w, { id = 4, pos = { x = 0, y = 0, z = 0 }, facing = 2, fuel = 10, install = false,
            inventory = { [1] = { name = "minecraft:raw_iron", count = 64 }, [2] = { name = "minecraft:raw_iron", count = 64 },
                          [3] = { name = "minecraft:dirt", count = 5 } } })
        t.fs:write("p.lua", [[
            local chest = peripheral.wrap("front")
            local types = { peripheral.getType("front") }
            local sz = chest.size()
            turtle.select(1); local d1 = turtle.drop()
            turtle.select(2); local d2, e2 = turtle.drop()
            turtle.select(4); local s1 = turtle.suck()
            local c = turtle.getItemDetail(4)
            local rf = turtle.refuel(2)
            local found = peripheral.find("inventory")
            local modem = peripheral.find("modem")
            return types[1], types[2], sz, d1, d2, e2, s1, c and c.name, turtle.getFuelLevel(),
                   found ~= nil, modem ~= nil, peripheral.getName(modem), chest.list()[2].name
        ]])
        r = sim.boot(t, { "p" })
        ok(r.status == "exit", "chest program: %s %s", r.status, tostring(r.err))
        local R = r.ret
        ok(R[1] == "minecraft:chest" and R[2] == "inventory", "chest peripheral types wrong")
        ok(R[3] == 2 and R[4] == true and R[5] == false and R[6] == "No space for items",
            "drop into full 2-slot chest should fail: %s %s %s", tostring(R[4]), tostring(R[5]), tostring(R[6]))
        ok(R[7] == true and R[8] == "minecraft:coal", "suck should take coal")
        ok(R[9] == 170, "refuel 2 coal should give 170 fuel, got %s", tostring(R[9]))
        ok(R[10] and R[11] and R[12] == "left", "peripheral.find inventory/modem failed")
        ok(R[13] == "minecraft:raw_iron", "chest list wrong")

        -- 4. crash between journal write and move; mid-file-write truncation ----------
        sim.reset()
        w = sim.world()
        t = sim.turtle(w, { id = 5, pos = { x = 0, y = 0, z = 0 }, facing = 0, fuel = 100, install = false })
        t.fs:write("walk.lua", [[
            for i = 1, 10 do
                local h = fs.open("journal", "a"); h.writeLine("I f " .. turtle.getFuelLevel()); h.close()
                turtle.dig()
                local ok = turtle.forward()
                h = fs.open("journal", "a"); h.writeLine("D " .. i); h.close()
            end
        ]])
        local crash = H.crashOn(H.isTurtleOp("forward", "before"), 3)
        r = sim.boot(t, { "walk" }, { crashAt = crash })
        ok(r.status == "crashed", "should crash, got %s", r.status)
        ok(t.pos.z == -2, "crash before 3rd forward: turtle should be at z=-2, got %s", H.fmtPos(t.pos))
        local j = t.fs:read("journal")
        ok(j == "I f 100\nD 1\nI f 99\nD 2\nI f 98\n", "journal after crash wrong: %q", j)
        -- crash after the move (before the done record)
        t.fs:write("journal", "")
        crash = H.crashOn(H.isTurtleOp("forward", "after"), 1)
        r = sim.boot(t, { "walk" }, { crashAt = crash })
        ok(r.status == "crashed" and t.pos.z == -3 and t.fs:read("journal") == "I f 98\n",
            "crash after move: pos %s journal %q", H.fmtPos(t.pos), t.fs:read("journal"))
        -- mid-write: the done record is half written
        t.fs:write("journal", "")
        crash = H.crashOn(H.isJournalWrite("D", nil, "^journal$"), 1)
        r = sim.boot(t, { "walk" }, { crashAt = crash })
        ok(r.status == "crashed", "mid-write crash status %s", r.status)
        local jj = t.fs:read("journal")
        ok(jj:match("^I f 97\n") and #jj < #"I f 97\nD 1\n" and #jj > #"I f 97\n", "truncated write expected, got %q", jj)
        -- crash on fs.move (atomic save window)
        t.fs:write("save.lua", [[
            local h = fs.open("st.tmp", "w"); h.write("NEW"); h.close()
            fs.delete("st")
            fs.move("st.tmp", "st")
        ]])
        t.fs:write("st", "OLD")
        r = sim.boot(t, { "save" }, { crashAt = H.crashOn(H.isMove("^st$")) })
        ok(r.status == "crashed" and t.fs:read("st") == nil and t.fs:read("st.tmp") == "NEW",
            "crash at move should leave only st.tmp")

        -- 5. rollback restores world + turtle, keeps fs ------------------------------
        sim.reset()
        w = sim.world()
        t = sim.turtle(w, { id = 6, pos = { x = 0, y = 0, z = 0 }, facing = 0, fuel = 100, install = false })
        t.fs:write("walk.lua", [[
            for i = 1, 6 do turtle.dig(); turtle.forward()
              local h = fs.open("n", "w"); h.write(tostring(i)); h.close() end
        ]])
        local snap
        sim.observe(function(e)
            if e.kind == "turtle" and e.op == "forward" and e.when == "after" and e.turtle == t and e.pos.z == -2 and not snap then
                snap = sim.snapshot(t)
            end
        end)
        r = sim.boot(t, { "walk" })
        ok(r.status == "exit" and t.pos.z == -6 and t.fuel == 94, "walk 6")
        sim.rollback(t, snap)
        ok(t.pos.z == -2 and t.fuel == 98, "rollback should restore pos/fuel, got %s %s", H.fmtPos(t.pos), tostring(t.fuel))
        ok(w:get(0, 0, -4) == "minecraft:stone", "rollback should restore dug blocks")
        ok(t.fs:read("n") == "6", "rollback must not touch the fs")

        -- 6. parallel + rednet + timers + gps + settings + reboot ---------------------
        sim.reset()
        w = sim.world()
        local a = sim.turtle(w, { id = 7, pos = { x = 5, y = 1, z = 5 }, gps = true, install = false })
        local b = sim.computer({ id = 8, modem = "top" })
        b.fs:write("srv.lua", [[
            rednet.open("top")
            while true do
                local id, msg = rednet.receive("P")
                if msg == "ping" then rednet.send(id, {pong=os.epoch("utc")}, "P") end
            end
        ]])
        a.fs:write("cli.lua", [[
            peripheral.find("modem", rednet.open)
            local got, ticks = nil, 0
            parallel.waitForAny(function()
                rednet.broadcast("ping", "P")
                local id, msg = rednet.receive("P", 5)
                got = msg
            end, function()
                while true do sleep(1); ticks = ticks + 1 end
            end)
            local x, y, z = gps.locate(2)
            settings.set("k", 42); settings.save()
            local boots = settings.get("boots", 0) + 1
            settings.set("boots", boots); settings.save()
            if boots < 2 then os.reboot() end
            return got and got.pong, x, y, z, boots, rednet.receive(0.5)
        ]])
        sim.boot(b, { "srv" }, { background = true })
        r = sim.boot(a, { "cli" }, { maxTime = 60 })
        ok(r.status == "exit", "client: %s %s", r.status, tostring(r.err))
        ok(type(r.ret[1]) == "number", "rednet ping/pong failed")
        ok(r.ret[2] == 5 and r.ret[3] == 1 and r.ret[4] == 5, "gps.locate should return true position")
        ok(r.ret[5] == 2 and a.computer.boots == 2, "reboot should re-run the program with settings persisted (boots=%s)", tostring(r.ret[5]))
        ok(r.ret[6] == nil, "receive timeout should return nil")
        ok(a.fs:read(".settings"):find("42"), "settings not persisted to fs")

        -- 7. read() is detected, hangs are caught, strict term reports overflow --------
        sim.reset()
        w = sim.world()
        t = sim.turtle(w, { id = 9, install = false })
        t.fs:write("ask.lua", "print('Chest side?') local s = read() return s")
        r = sim.boot(t, { "ask" }, { maxTime = 30 })
        ok(#t.computer.readCalls == 1 and r.status == "idle", "read() should be recorded and block (status %s)", r.status)
        t.fs:write("spin.lua", "local x = 0 while true do x = x + 1 end")
        r = sim.boot(t, { "spin" }, { maxTime = 30 })
        ok(r.status == "hung" or r.status == "error", "infinite loop should be killed, got %s", r.status)
        local p = sim.computer({ id = 10, pocket = true, strictTerm = true })
        p.fs:write("ui.lua", [[
            local w, h = term.getSize()
            term.setCursorPos(1, 1); term.write("fits")
            term.setCursorPos(w - 2, 2); term.write("too long")
            print(string.rep("x", 60)) -- print wraps, fine
            return w, h, pocket ~= nil
        ]])
        r = sim.boot(p, { "ui" })
        ok(r.ret[1] == 26 and r.ret[2] == 20 and r.ret[3] == true, "pocket term should be 26x20")
        ok(#p.term._violations == 1, "strict term should report exactly 1 overflow, got %d", #p.term._violations)
        ok(p.term._lines()[1]:sub(1, 4) == "fits", "screen capture wrong")

        -- 8. budget guard: a program that sleeps forever stops at maxTime -------------
        t.fs:write("idle.lua", "while true do sleep(10) end")
        r = sim.boot(t, { "idle" }, { maxTime = 100 })
        ok(r.status == "budget", "sleeping program should hit the time budget, got %s", r.status)

        -- 9. require() of modules from the computer fs, shell.run ----------------------
        sim.reset()
        w = sim.world()
        t = sim.turtle(w, { id = 11, install = false })
        t.fs:write("mod.lua", "local M = {} function M.f() return 'mod' end return M")
        t.fs:write("main.lua", "local m = require('mod'); _G.ran = (_G.ran or 0) + 1; return m.f()")
        t.fs:write("startup.lua", "shell.run('main'); return shell.run('main'), _G.ran")
        r = sim.boot(t, { "startup" })
        ok(r.status == "exit" and r.ret[1] == true and r.ret[2] == 2, "shell.run/require failed: %s %s", r.status, tostring(r.err))

        -- 10. real repo files are installed into turtle fs -----------------------------
        sim.reset()
        w = sim.world()
        t = sim.turtle(w, { id = 12 })
        ok(t.fs:read("config.lua") ~= nil, "miner/config.lua should be copied into the turtle fs")
        t.fs:write("cfgtest.lua", "local c = require('config'); return c.load().TARGET_Y")
        H.writeSettings(t, { TARGET_Y = -12 })
        r = sim.boot(t, { "cfgtest" })
        ok(r.status == "exit" and r.ret[1] == -12, "config.load via settings failed: %s %s", r.status, tostring(r.err or r.ret[1]))

        return checks .. " checks"
    end,
}
