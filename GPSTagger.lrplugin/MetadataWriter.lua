-- Writes matched GPS to the catalog in a single write-access transaction (one Undo step).
local LrTasks = import "LrTasks"
local LrProgressScope = import "LrProgressScope"

local Logger = require "Logger"
local Matcher = require "Matcher"

local MetadataWriter = {}

local ACTION_NAME = "Apply GPS from GPX"

-- Returns { applied=, errors=, cancelled=, failed = { {name=, message=} } }.
-- Must run inside an async task / function context.
function MetadataWriter.apply(catalog, items, functionContext)
    local todo = {}
    for _, item in ipairs(items) do
        if item.status == Matcher.MATCH then todo[#todo + 1] = item end
    end

    local result = { applied = 0, errors = 0, cancelled = false, failed = {} }
    if #todo == 0 then return result end

    local progress = LrProgressScope({
        title = "Applying GPS...",
        functionContext = functionContext,
    })
    progress:setCancelable(true)

    local writeResult = catalog:withWriteAccessDo(ACTION_NAME, function()
        for i, item in ipairs(todo) do
            if progress:isCanceled() then
                result.cancelled = true
                break
            end

            local ok, err = pcall(function()
                item.photo.ref:setRawMetadata("gps",
                    { latitude = item.latitude, longitude = item.longitude })
                if item.altitude then
                    item.photo.ref:setRawMetadata("gpsAltitude", item.altitude)
                end
            end)

            if ok then
                result.applied = result.applied + 1
            else
                result.errors = result.errors + 1
                result.failed[#result.failed + 1] = { name = item.photo.name, message = tostring(err) }
                Logger.error(string.format("%s: unable to write GPS (%s)", item.photo.name, tostring(err)))
            end

            progress:setPortionComplete(i, #todo)
            progress:setCaption(string.format("%d / %d photos", i, #todo))
            if i % 25 == 0 then LrTasks.yield() end
        end
    end, { timeout = 30 })

    progress:done()

    if writeResult ~= "executed" then
        Logger.error("Catalog write access was not granted: " .. tostring(writeResult))
        result.errors = result.errors + (#todo - result.applied)
        result.failed[#result.failed + 1] = {
            name = "(all)", message = "Could not get write access to the catalog: " .. tostring(writeResult) }
    end
    return result
end

return MetadataWriter
