-- Version: 1.0.0
-- TurtleMiner GPS maths (docs/CLUSTER_GPS_PLAN.md section 3): pure functions, no I/O.
-- Distances are measured between computer blocks: a CC:Tweaked wireless modem reports the
-- position of the block it is attached to (see tm_gps.lua), so every position here is the
-- integer block position of the computer. D[key(i,j)] = measured distance between PC i and j.
-- Loaded by tm_gps.lua into T.gpssolve; also usable stand-alone (dofile returns the table).
local T = ...
local M = {}
local sqrt, abs, floor = math.sqrt, math.abs, math.floor

M.TOL = 0.6          -- blocks: measured vs computed distance agreement
M.MIN_SEP = 6        -- blocks between any two hosts
M.MIN_HEIGHT = 1.5   -- blocks out of the plane: below this the constellation is flat

function M.key(i, j) if i > j then i, j = j, i end return i .. "," .. j end
function M.d(D, i, j) return D[M.key(i, j)] end

function M.dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return sqrt(dx * dx + dy * dy + dz * dz)
end

-- Shape of the constellation from distances alone (up to position, rotation, mirror).
-- Returns coords {[id]={x,y,z}} or nil, reason.
function M.layout(ids, D)
    local n = #ids
    if n < 4 then return nil, "need 4 PCs" end
    for i = 1, n do
        for j = i + 1, n do
            local v = M.d(D, ids[i], ids[j])
            if not v then return nil, "missing distance #" .. ids[i] .. "-#" .. ids[j] end
            if v < M.MIN_SEP then return nil, string.format("#%d and #%d only %.1f blocks apart", ids[i], ids[j], v) end
        end
    end
    local a = ids[1]
    local b, best = nil, -1
    for i = 2, n do local v = M.d(D, a, ids[i]); if v > best then best, b = v, ids[i] end end
    local dab = best
    local c, cx, cy = nil, 0, 0
    for i = 2, n do
        local p = ids[i]
        if p ~= b then
            local dac, dbc = M.d(D, a, p), M.d(D, b, p)
            local x = (dab * dab + dac * dac - dbc * dbc) / (2 * dab)
            local y2 = dac * dac - x * x
            local y = y2 > 0 and sqrt(y2) or 0
            if y > cy then c, cx, cy = p, x, y end
        end
    end
    if not c or cy < M.MIN_HEIGHT then return nil, "all in one line" end
    local P = { [a] = { x = 0, y = 0, z = 0 }, [b] = { x = dab, y = 0, z = 0 }, [c] = { x = cx, y = cy, z = 0 } }
    local firstOff
    for i = 2, n do
        local p = ids[i]
        if p ~= b and p ~= c then
            local dap, dbp, dcp = M.d(D, a, p), M.d(D, b, p), M.d(D, c, p)
            local x = (dap * dap - dbp * dbp + dab * dab) / (2 * dab)
            local y = (dap * dap - dcp * dcp + cx * cx + cy * cy - 2 * cx * x) / (2 * cy)
            local z2 = dap * dap - x * x - y * y
            local z = z2 > 0 and sqrt(z2) or 0
            if firstOff and z > 0.01 then
                local q = P[firstOff]
                local dq = M.d(D, p, firstOff)
                local e1 = abs(sqrt((x - q.x) ^ 2 + (y - q.y) ^ 2 + (z - q.z) ^ 2) - dq)
                local e2 = abs(sqrt((x - q.x) ^ 2 + (y - q.y) ^ 2 + (-z - q.z) ^ 2) - dq)
                if e2 < e1 then z = -z end
            elseif not firstOff and z >= M.MIN_HEIGHT then firstOff = p end
            P[p] = { x = x, y = y, z = z }
        end
    end
    if not firstOff then return nil, "all in one plane" end
    for i = 1, n do
        for j = i + 1, n do
            local e = abs(M.dist(P[ids[i]], P[ids[j]]) - M.d(D, ids[i], ids[j]))
            if e > M.TOL then return nil, string.format("distances do not fit (#%d-#%d off by %.1f)", ids[i], ids[j], e) end
        end
    end
    return P
end

local function det3(m)
    return m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2])
        - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1])
        + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
end
local function solve3(A, b)
    local d = det3(A)
    local tr = A[1][1] + A[2][2] + A[3][3]
    if tr <= 0 or abs(d) < 1e-5 * tr * tr * tr / 27 then return nil end
    local r = {}
    for k = 1, 3 do
        local m = { { A[1][1], A[1][2], A[1][3] }, { A[2][1], A[2][2], A[2][3] }, { A[3][1], A[3][2], A[3][3] } }
        for i = 1, 3 do m[i][k] = b[i] end
        r[k] = det3(m) / d
    end
    return { x = r[1], y = r[2], z = r[3] }
end

-- Position from >= 4 spheres {x,y,z,d} whose centres are not coplanar (least squares).
-- Returns pos, worst residual (blocks), or nil when degenerate.
function M.trilat(S)
    if #S < 4 then return nil end
    local s0 = S[1]
    local A = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local b = { 0, 0, 0 }
    for i = 2, #S do
        local s = S[i]
        local row = { 2 * (s.x - s0.x), 2 * (s.y - s0.y), 2 * (s.z - s0.z) }
        local rhs = (s.x * s.x + s.y * s.y + s.z * s.z) - (s0.x * s0.x + s0.y * s0.y + s0.z * s0.z) - s.d * s.d + s0.d * s0.d
        for r = 1, 3 do
            for c = 1, 3 do A[r][c] = A[r][c] + row[r] * row[c] end
            b[r] = b[r] + row[r] * rhs
        end
    end
    local p = solve3(A, b)
    if not p then return nil end
    local worst = 0
    for _, s in ipairs(S) do worst = math.max(worst, abs(M.dist(p, s) - s.d)) end
    return p, worst
end

-- Three spheres (non-collinear centres): the two mirror solutions, or nil.
function M.twoSol(S)
    local a, b, c = S[1], S[2], S[3]
    local ex = { x = b.x - a.x, y = b.y - a.y, z = b.z - a.z }
    local L = sqrt(ex.x ^ 2 + ex.y ^ 2 + ex.z ^ 2)
    if L < 1e-6 then return nil end
    ex = { x = ex.x / L, y = ex.y / L, z = ex.z / L }
    local ac = { x = c.x - a.x, y = c.y - a.y, z = c.z - a.z }
    local i = ex.x * ac.x + ex.y * ac.y + ex.z * ac.z
    local ey = { x = ac.x - i * ex.x, y = ac.y - i * ex.y, z = ac.z - i * ex.z }
    local jl = sqrt(ey.x ^ 2 + ey.y ^ 2 + ey.z ^ 2)
    if jl < 1 then return nil end
    ey = { x = ey.x / jl, y = ey.y / jl, z = ey.z / jl }
    local ez = { x = ex.y * ey.z - ex.z * ey.y, y = ex.z * ey.x - ex.x * ey.z, z = ex.x * ey.y - ex.y * ey.x }
    local j = ey.x * ac.x + ey.y * ac.y + ey.z * ac.z
    local x = (a.d ^ 2 - b.d ^ 2 + L * L) / (2 * L)
    local y = (a.d ^ 2 - c.d ^ 2 + i * i + j * j) / (2 * j) - (i / j) * x
    local z2 = a.d ^ 2 - x * x - y * y
    if z2 < -1 then return nil end
    local z = z2 > 0 and sqrt(z2) or 0
    local function at(s)
        return { x = a.x + x * ex.x + y * ey.x + s * z * ez.x, y = a.y + x * ex.y + y * ey.y + s * z * ez.y,
            z = a.z + x * ex.z + y * ey.z + s * z * ez.z }
    end
    return at(1), at(-1)
end

local function round(p) return { x = floor(p.x + 0.5), y = floor(p.y + 0.5), z = floor(p.z + 0.5) } end
M.round = round

-- Mismatches between positions and measured distances: list of {a, b, want, got}.
function M.mismatches(pos, D, ids, tol)
    local out = {}
    for i = 1, #ids do
        for j = i + 1, #ids do
            local a, b = ids[i], ids[j]
            local want = M.d(D, a, b)
            if pos[a] and pos[b] and want then
                local got = M.dist(pos[a], pos[b])
                if abs(got - want) > (tol or M.TOL) then out[#out + 1] = { a = a, b = b, want = want, got = got } end
            end
        end
    end
    return out
end

-- An entry typed for PC `id` against the already known ones: nil when fine, else a message.
function M.checkEntry(id, p, known, D)
    for j, q in pairs(known) do
        if j ~= id then
            local want = M.d(D, id, j)
            if want then
                local got = M.dist(p, q)
                if abs(got - want) > M.TOL then
                    return string.format("doesn't match: distance to PC #%d should be %.1f, these coordinates give %.1f", j, want, got)
                end
            end
        end
    end
    return nil
end

-- Unknown PC from known ones. Returns pos | nil, "ambiguous", cand1, cand2 | nil, why.
local function place(u, known, ids, D)
    local S = {}
    for _, k in ipairs(ids) do
        local d = known[k] and M.d(D, u, k)
        if d then S[#S + 1] = { x = known[k].x, y = known[k].y, z = known[k].z, d = d, id = k } end
    end
    if #S >= 4 then
        local p = M.trilat(S)
        if p then
            local r = round(p)
            for _, s in ipairs(S) do if abs(M.dist(r, s) - s.d) > M.TOL then return nil, "inconsistent" end end
            return r
        end
    end
    if #S >= 3 then
        for i = 1, #S do for j = i + 1, #S do for k = j + 1, #S do
            local p1, p2 = M.twoSol({ S[i], S[j], S[k] })
            if p1 then
                local r1, r2 = round(p1), round(p2)
                if M.dist(r1, r2) < 1.5 then          -- in the plane of the three: no mirror image
                    local ok = true
                    for _, s in ipairs(S) do if abs(M.dist(r1, s) - s.d) > M.TOL then ok = false end end
                    if ok then return r1 end
                    return nil, "inconsistent"
                end
                return nil, "ambiguous", r1, r2
            end
        end end end
    end
    return nil, "need more"
end
M.place = place

-- known: {[id]=pos} (typed or fixed). Grows it by trilateration. Returns
--   {pos=full map} when everything is placed and consistent, or
--   {need="xyz", ids={...}} PCs to ask for full coordinates, or
--   {need="axis", id=, axis="x|y|z", cands={c1,c2}} one PC to ask one number, or {fail=why}.
function M.resolve(known, D, ids)
    local pos = {}
    for k, v in pairs(known) do pos[k] = v end
    local progress = true
    while progress do
        progress = false
        for _, u in ipairs(ids) do
            if not pos[u] then
                local p = place(u, pos, ids, D)
                if p then pos[u] = p; progress = true end
            end
        end
    end
    local unknown = {}
    for _, u in ipairs(ids) do if not pos[u] then unknown[#unknown + 1] = u end end
    if #unknown == 0 then
        local bad = M.mismatches(pos, D, ids)
        if #bad > 0 then
            return { fail = string.format("distance #%d-#%d: measured %.1f, positions give %.1f", bad[1].a, bad[1].b, bad[1].want, bad[1].got) }
        end
        return { pos = pos }
    end
    local nk = 0
    for _ in pairs(pos) do nk = nk + 1 end
    if nk >= 3 then
        for _, u in ipairs(unknown) do
            local _, why, c1, c2 = place(u, pos, ids, D)
            if why == "ambiguous" then
                local dx, dy, dz = abs(c1.x - c2.x), abs(c1.y - c2.y), abs(c1.z - c2.z)
                local axis, dm = "y", dy
                if dx > dm then axis, dm = "x", dx end
                if dz > dm then axis, dm = "z", dz end
                if dm < 2 then return { fail = "mirror image cannot be told apart" } end
                return { need = "axis", id = u, axis = axis, cands = { c1, c2 } }
            end
        end
        return { fail = "cannot place the remaining PCs" }
    end
    -- fewer than 3 known: ask for full coordinates of the PCs that settle the layout best
    local chosen = {}
    for k in pairs(pos) do chosen[#chosen + 1] = k end
    table.sort(chosen)
    local function area(a, b, c)
        local ab, ac, bc = M.d(D, a, b), M.d(D, a, c), M.d(D, b, c)
        local s = (ab + ac + bc) / 2
        local v = s * (s - ab) * (s - ac) * (s - bc)
        return v > 0 and sqrt(v) or 0
    end
    local ask = {}
    while #chosen < 3 do
        local best, bv = nil, -1
        for _, u in ipairs(unknown) do
            local taken = false
            for _, c in ipairs(chosen) do if c == u then taken = true end end
            if not taken then
                local v
                if #chosen == 0 then v = 1000 - u
                elseif #chosen == 1 then v = M.d(D, u, chosen[1])
                else v = area(chosen[1], chosen[2], u) end
                if v > bv then bv, best = v, u end
            end
        end
        if not best then return { fail = "not enough PCs" } end
        chosen[#chosen + 1] = best
        ask[#ask + 1] = best
    end
    return { need = "xyz", ids = ask }
end

if T then T.gpssolve = M end
return M
