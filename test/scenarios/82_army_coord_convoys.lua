-- Version: 1.0.0
-- Scenario 82 (army coordinator): shaft convoys (same direction shares, opposite waits, flips when
-- empty), the station queue and non-overlapping timed slots for turtles out of contact.
local BASIC = { { side = "back", kind = "basic" } }

return {
    title = "army coordinator: convoys share, opposite waits then flips, slots never overlap",
    needs = { "net" },
    run = function(sim, H)
        local srv = H.serverComputer({ id = 1, modems = BASIC })
        sim.run({ maxTime = 25 })
        local A = srv.T.army
        local sent = {}
        A.out = function(kind, to, body) sent[#sent + 1] = { kind = kind, to = to, body = body } end
        local function ask(id, now, kind, body)
            sent = {}
            body = body or {}
            body.kind, body.from, body.name = kind, id, "g"
            A.handle(body, now)
            return sent[1] and sent[1].body
        end
        local now = 9000000
        local army = assert(A.new("g", { x = 0, y = 64, z = 0, f = 0 }, { "diamond" }, nil, now))
        for id = 1, 6 do A.handle({ kind = "army_join", from = id, name = "g", at = { x = 0, y = 64, z = 0 } }, now) end
        local segs = { "s1:0", "s1:1" }
        H.check(ask(1, now, "seg_req", { segs = segs, dir = "down" }).segs, "first down not granted")
        H.check(ask(2, now + 10, "seg_req", { segs = segs, dir = "down" }).segs, "same direction does not share")
        local w = ask(3, now + 20, "seg_req", { segs = segs, dir = "up" })
        H.check(w.wait and not w.segs, "opposite direction was granted")
        H.check(ask(4, now + 30, "seg_req", { segs = { "s1:1", "s1:2" }, dir = "up" }).wait, "partial grant")
        H.check(not army.segs["s1:2"], "failed request left a lock behind")
        ask(1, now + 40, "seg_release", { segs = segs })
        H.check(ask(3, now + 50, "seg_req", { segs = segs, dir = "up" }).wait, "flipped while a holder remained")
        ask(2, now + 60, "seg_release", { segs = segs })
        H.check(ask(3, now + 70, "seg_req", { segs = segs, dir = "up" }).segs, "no flip when empty")
        H.check(army.segs["s1:0"].dir == "up", "direction not flipped")
        H.check(ask(4, now + 80, "seg_req", { segs = segs, dir = "up" }).segs, "up convoy does not share")
        ask(3, now + 90, "seg_release", { segs = segs })
        ask(4, now + 90, "seg_release", { segs = segs })
        H.check(next(army.segs) == nil, "locks left over")
        -- station queue
        local q1 = ask(1, now, "seg_req", { segs = { "station" } })
        local q2 = ask(2, now, "seg_req", { segs = { "station" } })
        H.check(q1.pos == 1 and q1.go and q2.pos == 2 and not q2.go, "station queue order")
        sent = {}
        ask(1, now + 5, "seg_release", { segs = { "station" } })
        H.check(sent[1] and sent[1].to == 2 and sent[1].body.go, "next in queue not told to go")
        -- slots
        local slots = {}
        local eta = { 0, 5000, 5000, 20000, 0, 60000 }
        for id = 1, 6 do
            local s = ask(id, now, "slot_req", { shaft = 1, dir = "up", eta = eta[id] })
            H.check(s.at and s.len > 0, "no slot for %d", id)
            H.check(s.at >= now + eta[id], "slot %d starts before its eta", id)
            slots[#slots + 1] = s
        end
        table.sort(slots, function(a, b) return a.at < b.at end)
        for i = 2, #slots do
            H.check(slots[i].at >= slots[i - 1].at + slots[i - 1].len, "slots %d and %d overlap", i - 1, i)
        end
        return "convoy/flip/queue/slots ok (slot len " .. slots[1].len .. " ms)"
    end,
}
