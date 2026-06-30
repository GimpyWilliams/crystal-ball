local json = require('json')
local world = df.global.world

local report = { errors = {}, announcements = {}, total = 0, shown = 0 }
report.fort_loaded = (world.map.block_index ~= nil)
if not report.fort_loaded then
    print(json.encode(report))
    return
end

local limit = tonumber((...)) or 50

local ok, err = pcall(function()
    local reps = world.status.reports
    local total = #reps
    report.total = total
    local results = {}
    for i = total - 1, 0, -1 do
        local r = reps[i]
        if r.flags.announcement then
            local type_name = (df.report_type and df.report_type[r.type])
                           or (df.announcement_type and df.announcement_type[r.type])
                           or tostring(r.type)
            local entry = {
                year = r.year,
                time = r.time,
                type = type_name,
                text = r.text,
            }
            if r.pos and r.pos.x ~= -30000 then
                entry.pos = { x = r.pos.x, y = r.pos.y, z = r.pos.z }
            end
            results[#results + 1] = entry
            if #results >= limit then break end
        end
    end
    local ordered = {}
    for i = #results, 1, -1 do ordered[#ordered + 1] = results[i] end
    report.announcements = ordered
    report.shown = #ordered
end)

if not ok then
    report.errors[#report.errors + 1] = "announcements: " .. tostring(err)
end

print(json.encode(report))
