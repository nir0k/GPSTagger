-- Writes matched GPS to the catalog in a single write-access transaction (one Undo step).
local LrTasks = import "LrTasks"
local LrProgressScope = import "LrProgressScope"

local Logger = require "Logger"
local Matcher = require "Matcher"

local MetadataWriter = {}

local ACTION_NAME = "Apply GPS from GPX"

local function restoreOriginalGps(item)
    local photo, ref = item.photo, item.photo.ref
    ref:setRawMetadata("gps", photo.gps)
    if photo.gpsAltitude ~= nil then
        ref:setRawMetadata("gpsAltitude", photo.gpsAltitude)
    end
    if photo.gpsImgDirection ~= nil then
        ref:setRawMetadata("gpsImgDirection", photo.gpsImgDirection)
    end
end

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
                local oldAltitude = item.photo.gpsAltitude
                if item.altitude == nil and oldAltitude ~= nil then
                    item.photo.ref:setRawMetadata("gps", nil)
                    if item.photo.ref:getRawMetadata("gpsAltitude") ~= nil then
                        error("Lightroom did not clear the previous GPS altitude")
                    end
                end
                item.photo.ref:setRawMetadata("gps",
                    { latitude = item.latitude, longitude = item.longitude })
                if item.altitude ~= nil then
                    item.photo.ref:setRawMetadata("gpsAltitude", item.altitude)
                elseif oldAltitude ~= nil and item.photo.gpsImgDirection ~= nil then
                    -- Clearing the complete GPS value may also clear the camera direction.
                    item.photo.ref:setRawMetadata("gpsImgDirection", item.photo.gpsImgDirection)
                end
            end)

            if ok then
                result.applied = result.applied + 1
            else
                local restored, restoreErr = pcall(restoreOriginalGps, item)
                if not restored then
                    err = tostring(err) .. "; could not restore original GPS: " .. tostring(restoreErr)
                end
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
