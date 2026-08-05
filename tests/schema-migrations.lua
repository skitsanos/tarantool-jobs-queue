local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local repository_root = script_path:match('^(.*[/\\])tests[/\\]') or './'
package.path = repository_root .. 'src/?.lua;' .. package.path

box.cfg({
    listen = nil,
    wal_mode = 'none',
})

if box.space.migration_test_jobs ~= nil then
    box.space.migration_test_jobs:drop()
end
box.space._schema:delete({ 'jobs_queue_schema_version:migration_test_jobs' })

local legacy = box.schema.space.create('migration_test_jobs')
legacy:format({
    { name = 'job_id', type = 'string' },
    { name = 'status', type = 'string' },
    { name = 'payload', type = 'map' },
    { name = 'created_at', type = 'number', is_nullable = true },
    { name = 'updated_at', type = 'number', is_nullable = true },
})
legacy:create_index('primary', { type = 'hash', parts = { 'job_id' } })
legacy:create_index('status', {
    type = 'tree',
    parts = { 'status', 'created_at', 'job_id' },
})
legacy:create_index('created_at', {
    type = 'tree',
    parts = { 'created_at', 'job_id' },
})
legacy:insert({ 'legacy-pending', 'pending', { kind = 'pending' }, 1, 1 })
legacy:insert({ 'legacy-running', 'in-progress', { kind = 'running' }, 2, 2 })

local migrations = require('migrations')
assert(migrations.get_version('migration_test_jobs') == 1)

local migrated, version = migrations.apply('migration_test_jobs', {
    default_max_attempts = 3,
})
assert(version == migrations.CURRENT_VERSION)
assert(migrations.get_version('migration_test_jobs') == migrations.CURRENT_VERSION)
assert(migrated.index.ready ~= nil)
assert(migrated.index.lease ~= nil)
assert(migrated.index.idempotency ~= nil)

local pending = migrated:get({ 'legacy-pending' })
assert(#pending == 12)
assert(pending.available_at == 1)
assert(pending.attempts == 0)
assert(pending.max_attempts == 3)

local running = migrated:get({ 'legacy-running' })
assert(running.lease_until ~= nil and running.lease_until ~= box.NULL)
assert(running.lease_token == nil or running.lease_token == box.NULL)

local reapplied, reapplied_version = migrations.apply('migration_test_jobs', {
    default_max_attempts = 3,
})
assert(reapplied == migrated)
assert(reapplied_version == migrations.CURRENT_VERSION)
assert(reapplied:count() == 2)

print('Migration test passed: legacy schema upgraded to version ' .. version)
os.exit(0)
