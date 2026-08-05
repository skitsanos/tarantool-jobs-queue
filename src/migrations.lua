local clock = require('clock')

local migrations = {
    CURRENT_VERSION = 3,
}

local function version_key(space_name)
    return 'jobs_queue_schema_version:' .. space_name
end

local function nullable(value)
    if value == nil then
        return box.NULL
    end
    return value
end

local function value_or(value, fallback)
    if value == nil or value == box.NULL then
        return fallback
    end
    return value
end

local function create_v1(space_name)
    local space = box.schema.space.create(space_name, { if_not_exists = true })
    space:format({
        { name = 'job_id', type = 'string' },
        { name = 'status', type = 'string' },
        { name = 'payload', type = 'map' },
        { name = 'created_at', type = 'number', is_nullable = true },
        { name = 'updated_at', type = 'number', is_nullable = true },
    })
    space:create_index('primary', {
        type = 'hash',
        parts = { 'job_id' },
        if_not_exists = true,
    })
    space:create_index('status', {
        type = 'tree',
        parts = {
            { field = 'status', type = 'string' },
            { field = 'created_at', type = 'number', is_nullable = true },
            { field = 'job_id', type = 'string' },
        },
        if_not_exists = true,
    })
    space:create_index('created_at', {
        type = 'tree',
        parts = {
            { field = 'created_at', type = 'number', is_nullable = true },
            { field = 'job_id', type = 'string' },
        },
        if_not_exists = true,
    })
end

local function migrate_v2(space_name, default_max_attempts)
    local space = box.space[space_name]

    -- The nullable transition format makes this migration safe to resume after
    -- an interruption while legacy tuples are being expanded.
    space:format({
        { name = 'job_id', type = 'string' },
        { name = 'status', type = 'string' },
        { name = 'payload', type = 'map' },
        { name = 'created_at', type = 'number', is_nullable = true },
        { name = 'updated_at', type = 'number', is_nullable = true },
        { name = 'available_at', type = 'number', is_nullable = true },
        { name = 'lease_until', type = 'number', is_nullable = true },
        { name = 'attempts', type = 'unsigned', is_nullable = true },
        { name = 'max_attempts', type = 'unsigned', is_nullable = true },
        { name = 'last_error', type = 'string', is_nullable = true },
        { name = 'idempotency_key', type = 'string', is_nullable = true },
    })

    local now = clock.time()
    for _, tuple in space.index.primary:pairs() do
        local created_at = value_or(tuple[4], now)
        local updated_at = value_or(tuple[5], created_at)
        local lease_until = tuple[7]
        if (lease_until == nil or lease_until == box.NULL) and tuple[2] == 'in-progress' then
            lease_until = now
        end

        space:replace({
            tuple[1],
            tuple[2],
            tuple[3],
            created_at,
            updated_at,
            value_or(tuple[6], created_at),
            nullable(lease_until == box.NULL and nil or lease_until),
            value_or(tuple[8], 0),
            value_or(tuple[9], default_max_attempts),
            nullable(tuple[10] == box.NULL and nil or tuple[10]),
            nullable(tuple[11] == box.NULL and nil or tuple[11]),
        })
    end

    space:format({
        { name = 'job_id', type = 'string' },
        { name = 'status', type = 'string' },
        { name = 'payload', type = 'map' },
        { name = 'created_at', type = 'number' },
        { name = 'updated_at', type = 'number' },
        { name = 'available_at', type = 'number' },
        { name = 'lease_until', type = 'number', is_nullable = true },
        { name = 'attempts', type = 'unsigned' },
        { name = 'max_attempts', type = 'unsigned' },
        { name = 'last_error', type = 'string', is_nullable = true },
        { name = 'idempotency_key', type = 'string', is_nullable = true },
    })

    space:create_index('ready', {
        type = 'tree',
        parts = {
            { field = 'status', type = 'string' },
            { field = 'available_at', type = 'number' },
            { field = 'created_at', type = 'number' },
            { field = 'job_id', type = 'string' },
        },
        if_not_exists = true,
    })
    space:create_index('lease', {
        type = 'tree',
        parts = {
            { field = 'status', type = 'string' },
            {
                field = 'lease_until',
                type = 'number',
                is_nullable = true,
                exclude_null = true,
            },
            { field = 'created_at', type = 'number' },
            { field = 'job_id', type = 'string' },
        },
        if_not_exists = true,
    })
    space:create_index('idempotency', {
        type = 'tree',
        parts = {
            {
                field = 'idempotency_key',
                type = 'string',
                is_nullable = true,
                exclude_null = true,
            },
        },
        unique = true,
        if_not_exists = true,
    })
end

local function migrate_v3(space_name)
    local space = box.space[space_name]
    space:format({
        { name = 'job_id', type = 'string' },
        { name = 'status', type = 'string' },
        { name = 'payload', type = 'map' },
        { name = 'created_at', type = 'number' },
        { name = 'updated_at', type = 'number' },
        { name = 'available_at', type = 'number' },
        { name = 'lease_until', type = 'number', is_nullable = true },
        { name = 'attempts', type = 'unsigned' },
        { name = 'max_attempts', type = 'unsigned' },
        { name = 'last_error', type = 'string', is_nullable = true },
        { name = 'idempotency_key', type = 'string', is_nullable = true },
        { name = 'lease_token', type = 'string', is_nullable = true },
    })

    local now = clock.time()
    for _, tuple in space.index.primary:pairs() do
        local lease_until = tuple[7]
        if tuple[2] == 'in-progress' then
            lease_until = now
        end
        space:replace({
            tuple[1],
            tuple[2],
            tuple[3],
            tuple[4],
            tuple[5],
            tuple[6],
            nullable(lease_until == box.NULL and nil or lease_until),
            tuple[8],
            tuple[9],
            nullable(tuple[10] == box.NULL and nil or tuple[10]),
            nullable(tuple[11] == box.NULL and nil or tuple[11]),
            box.NULL,
        })
    end
end

local MIGRATIONS = {
    [1] = create_v1,
    [2] = migrate_v2,
    [3] = migrate_v3,
}

function migrations.get_version(space_name)
    local tuple = box.space._schema:get({ version_key(space_name) })
    if tuple ~= nil then
        return tonumber(tuple[2])
    end
    if box.space[space_name] ~= nil then
        return 1
    end
    return 0
end

function migrations.apply(space_name, options)
    local default_max_attempts = options.default_max_attempts
    local current_version = migrations.get_version(space_name)

    if current_version > migrations.CURRENT_VERSION then
        error(string.format(
            'jobs schema version %d is newer than supported version %d',
            current_version,
            migrations.CURRENT_VERSION
        ))
    end

    for target_version = current_version + 1, migrations.CURRENT_VERSION do
        MIGRATIONS[target_version](space_name, default_max_attempts)
        box.space._schema:replace({ version_key(space_name), target_version })
    end

    return box.space[space_name], migrations.CURRENT_VERSION
end

return migrations
