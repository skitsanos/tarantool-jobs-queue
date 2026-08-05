local fio = require('fio')

local M = {}

local DEFAULT_DATA_DIR = './data'
local DEFAULT_WAL_MODE = 'fsync'
local DEFAULT_CHECKPOINT_INTERVAL = 3600
local DEFAULT_CHECKPOINT_COUNT = 2

local function parse_integer(raw_value, name, default, minimum, maximum)
    if raw_value == nil then
        return default
    end
    local value = tonumber(raw_value)
    if value == nil
        or value ~= math.floor(value)
        or value < minimum
        or value > maximum then
        error(string.format('%s must be an integer between %d and %d', name, minimum, maximum))
    end
    return value
end

function M.load(getenv)
    getenv = getenv or os.getenv

    local data_dir = getenv('TARANTOOL_DATA_DIR') or DEFAULT_DATA_DIR
    if data_dir == '' or data_dir:find('%z') ~= nil then
        error('TARANTOOL_DATA_DIR must be a non-empty filesystem path')
    end

    local wal_mode = getenv('TARANTOOL_WAL_MODE') or DEFAULT_WAL_MODE
    if wal_mode ~= 'write' and wal_mode ~= 'fsync' then
        error('TARANTOOL_WAL_MODE must be write or fsync; none is not allowed for this queue')
    end

    return {
        data_dir = fio.abspath(data_dir),
        wal_mode = wal_mode,
        checkpoint_interval = parse_integer(
            getenv('TARANTOOL_CHECKPOINT_INTERVAL'),
            'TARANTOOL_CHECKPOINT_INTERVAL',
            DEFAULT_CHECKPOINT_INTERVAL,
            1,
            86400
        ),
        checkpoint_count = parse_integer(
            getenv('TARANTOOL_CHECKPOINT_COUNT'),
            'TARANTOOL_CHECKPOINT_COUNT',
            DEFAULT_CHECKPOINT_COUNT,
            2,
            100
        ),
    }
end

function M.prepare(settings)
    local created, create_error = fio.mktree(settings.data_dir)
    if not created and not fio.path.is_dir(settings.data_dir) then
        error(string.format(
            'Unable to create TARANTOOL_DATA_DIR %s: %s',
            settings.data_dir,
            tostring(create_error)
        ))
    end
    if not fio.path.is_dir(settings.data_dir) then
        error('TARANTOOL_DATA_DIR is not a directory: ' .. settings.data_dir)
    end
end

M.DEFAULT_DATA_DIR = DEFAULT_DATA_DIR
M.DEFAULT_WAL_MODE = DEFAULT_WAL_MODE
M.DEFAULT_CHECKPOINT_INTERVAL = DEFAULT_CHECKPOINT_INTERVAL
M.DEFAULT_CHECKPOINT_COUNT = DEFAULT_CHECKPOINT_COUNT

return M
