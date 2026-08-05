local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local script_dir = script_path:match('^(.*[/\\])') or './'
package.path = script_dir .. '../src/?.lua;' .. package.path

local fio = require('fio')
local persistence = require('persistence')

local function load(values)
    return persistence.load(function(name)
        return values[name]
    end)
end

local function expect_error(values, expected_message)
    local ok, error_message = pcall(load, values)
    assert(not ok, 'invalid persistence configuration must be rejected')
    assert(
        tostring(error_message):find(expected_message, 1, true) ~= nil,
        'unexpected persistence configuration error: ' .. tostring(error_message)
    )
end

local defaults = load({})
assert(defaults.wal_mode == 'fsync', 'fsync must be the default WAL durability mode')
assert(defaults.checkpoint_interval == 3600, 'the default checkpoint interval must be one hour')
assert(defaults.checkpoint_count == 2, 'two checkpoints must be retained by default')

local configured = load({
    TARANTOOL_DATA_DIR = './custom-data',
    TARANTOOL_WAL_MODE = 'write',
    TARANTOOL_CHECKPOINT_INTERVAL = '120',
    TARANTOOL_CHECKPOINT_COUNT = '3',
})
assert(
    configured.data_dir:match('custom%-data$') ~= nil,
    'the configured data path must be resolved'
)
assert(configured.wal_mode == 'write', 'write WAL mode must be supported explicitly')
assert(configured.checkpoint_interval == 120, 'the checkpoint interval must be configurable')
assert(configured.checkpoint_count == 3, 'the retained checkpoint count must be configurable')

expect_error({ TARANTOOL_DATA_DIR = '' }, 'non-empty filesystem path')
expect_error({ TARANTOOL_WAL_MODE = 'none' }, 'none is not allowed')
expect_error({ TARANTOOL_WAL_MODE = 'invalid' }, 'must be write or fsync')
expect_error({ TARANTOOL_CHECKPOINT_INTERVAL = '0' }, 'integer between 1 and 86400')
expect_error({ TARANTOOL_CHECKPOINT_INTERVAL = '1.5' }, 'integer between 1 and 86400')
expect_error({ TARANTOOL_CHECKPOINT_COUNT = '1' }, 'integer between 2 and 100')

local temporary_root = fio.tempdir()
local prepared = load({ TARANTOOL_DATA_DIR = fio.pathjoin(temporary_root, 'nested', 'data') })
persistence.prepare(prepared)
assert(fio.path.is_dir(prepared.data_dir), 'the configured data directory must be created')
fio.rmtree(temporary_root)

print('Persistence unit tests passed: durability defaults, validation, and directory setup.')
