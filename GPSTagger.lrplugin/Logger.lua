-- Diagnostic log: <Documents>/LrClassicLogs/GPSTagger.log
local LrLogger = import "LrLogger"

local logger = LrLogger("GPSTagger")
logger:enable("logfile")

local Logger = {}
function Logger.info(msg) logger:info(msg) end
function Logger.warn(msg) logger:warn(msg) end
function Logger.error(msg) logger:error(msg) end

return Logger
