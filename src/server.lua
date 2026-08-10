local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local script_dir = script_path:match('^(.*[/\\])') or './'
package.path = script_dir .. '?.lua;' .. package.path

local auth_module = require('auth')
local authorization = auth_module.new(os.getenv('API_BEARER_TOKEN'))
local persistence = require('persistence')
local persistence_settings = persistence.load()
persistence.prepare(persistence_settings)
if not authorization.enabled then
    print('WARNING: HTTP bearer authentication is disabled; set API_BEARER_TOKEN in production')
end

box.cfg({
    checkpoint_count = persistence_settings.checkpoint_count,
    checkpoint_interval = persistence_settings.checkpoint_interval,
    listen = os.getenv('TARANTOOL_LISTEN') or '127.0.0.1:3301',
    memtx_dir = persistence_settings.data_dir,
    vinyl_dir = persistence_settings.data_dir,
    wal_dir = persistence_settings.data_dir,
    wal_mode = persistence_settings.wal_mode,
})

local digest = require('digest')
local httpd = require('http.server')
local json = require('json')
local jobs_module = require('jobs')
local metadata = require('metadata')

local jobs_manager = jobs_module.new('jobs_space')
local server = httpd.new(
    os.getenv('HTTP_HOST') or '127.0.0.1',
    tonumber(os.getenv('HTTP_PORT')) or 3000
)

local function json_response(status, body, additional_headers)
    local headers = { ['content-type'] = 'application/json; charset=utf-8' }
    for name, value in pairs(additional_headers or {}) do
        headers[name] = value
    end
    return {
        status = status,
        headers = headers,
        body = json.encode(body),
    }
end

local function error_response(status, code, message, additional_headers)
    return json_response(status, {
        error = {
            code = code,
            message = message,
        },
    }, additional_headers)
end

local function protected(handler)
    return function(req)
        if not authorization.is_authorized(req.headers.authorization) then
            return error_response(
                401,
                'unauthorized',
                'A valid bearer token is required',
                { ['www-authenticate'] = 'Bearer realm="tarantool-jobs-queue"' }
            )
        end
        return handler(req)
    end
end

local function protected_route(options, handler)
    server:route(options, protected(handler))
end

local function is_json_object(value)
    local metatable = type(value) == 'table' and getmetatable(value) or nil
    return metatable ~= nil and metatable.__serialize == 'map'
end

local function parse_json_object(req)
    local ok, payload = pcall(function()
        return req:json()
    end)
    if not ok or not is_json_object(payload) then
        return nil, 'Request body must be a JSON object'
    end
    return payload
end

local function parse_number_query(req, name, default, minimum, maximum, integer)
    local raw_value = req:query_param(name)
    local value = raw_value == nil and default or tonumber(raw_value)
    if value == nil
        or value < minimum
        or value > maximum
        or (integer and value ~= math.floor(value)) then
        local number_kind = integer and 'integer' or 'number'
        return nil, string.format(
            '%s must be a %s between %s and %s',
            name,
            number_kind,
            minimum,
            maximum
        )
    end
    return value
end

local function encode_cursor(cursor)
    if cursor == nil then
        return nil
    end
    local encoded = digest.base64_encode(json.encode(cursor)):gsub('%s', '')
    return encoded:gsub('%+', '-'):gsub('/', '_'):gsub('=+$', '')
end

local function decode_cursor(encoded, status)
    if encoded == nil then
        return nil
    end
    if #encoded == 0 or #encoded > 512 or encoded:match('[^%w_-]') ~= nil then
        return nil, 'cursor is malformed'
    end

    local padded = encoded:gsub('-', '+'):gsub('_', '/')
    local remainder = #padded % 4
    if remainder > 0 then
        padded = padded .. string.rep('=', 4 - remainder)
    end

    local decoded_ok, raw_cursor = pcall(digest.base64_decode, padded)
    local json_ok, cursor = false, nil
    if decoded_ok and raw_cursor ~= nil then
        json_ok, cursor = pcall(json.decode, raw_cursor)
    end
    local expected_status = status or ''
    if not json_ok
        or not is_json_object(cursor)
        or type(cursor.job_id) ~= 'string'
        or cursor.status ~= expected_status then
        return nil, 'cursor does not match this listing'
    end
    return cursor
end

local function transition_response(job, transition_error, expected_state)
    if transition_error == 'not_found' then
        return error_response(404, 'job_not_found', 'Job was not found')
    end
    if transition_error == 'invalid_state' then
        return error_response(409, 'invalid_job_state', 'Job must be ' .. expected_state)
    end
    if transition_error == 'invalid_lease' then
        return error_response(409, 'invalid_lease', 'Lease-Token does not own this attempt')
    end
    if transition_error == 'lease_expired' then
        return error_response(409, 'lease_expired', 'The processing lease has expired')
    end
    return json_response(200, job)
end

local function get_lease_token(req)
    local lease_token = req.headers['lease-token']
    if lease_token == nil or #lease_token == 0 or #lease_token > 100 then
        return nil, error_response(
            400,
            'invalid_lease_token',
            'Lease-Token must contain between 1 and 100 characters'
        )
    end
    return lease_token
end

protected_route({ path = '/version', method = 'GET' }, function()
    return json_response(200, {
        version = metadata.api_version,
        schema_version = jobs_manager.schema_version,
    })
end)

server:route({ path = '/health/live', method = 'GET' }, function()
    return json_response(200, {
        status = 'ok',
    })
end)

protected_route({ path = '/health/ready', method = 'GET' }, function()
    local readiness = jobs_manager.readiness()
    return json_response(readiness.ready and 200 or 503, {
        status = readiness.ready and 'ok' or 'not_ready',
        checks = {
            schema = {
                ready = readiness.schema_ready,
                version = readiness.schema_version,
                expected_version = readiness.expected_schema_version,
            },
            storage = {
                writable = readiness.writable,
                write_probe = readiness.write_probe,
            },
        },
    })
end)

protected_route({ path = '/jobs', method = 'POST' }, function(req)
    local payload, payload_error = parse_json_object(req)
    if payload_error ~= nil then
        return error_response(400, 'invalid_payload', payload_error)
    end

    local max_attempts, max_attempts_error = parse_number_query(
        req,
        'max_attempts',
        jobs_module.DEFAULT_MAX_ATTEMPTS,
        1,
        jobs_module.MAX_ATTEMPTS,
        true
    )
    if max_attempts_error ~= nil then
        return error_response(400, 'invalid_max_attempts', max_attempts_error)
    end
    local delay, delay_error = parse_number_query(req, 'delay', 0, 0, 86400, false)
    if delay_error ~= nil then
        return error_response(400, 'invalid_delay', delay_error)
    end

    local idempotency_key = req.headers['idempotency-key']
    if idempotency_key ~= nil and (#idempotency_key == 0 or #idempotency_key > 200) then
        return error_response(
            400,
            'invalid_idempotency_key',
            'Idempotency-Key must contain between 1 and 200 characters'
        )
    end

    local job, created = jobs_manager.create_job(payload, {
        delay = delay,
        idempotency_key = idempotency_key,
        max_attempts = max_attempts,
    })
    return json_response(created and 201 or 200, job, {
        ['idempotency-replayed'] = created and 'false' or 'true',
    })
end)

protected_route({ path = '/jobs', method = 'GET' }, function(req)
    if req:query_param('offset') ~= nil then
        return error_response(
            400,
            'invalid_pagination',
            'offset pagination is no longer supported; use cursor'
        )
    end

    local limit, limit_error = parse_number_query(req, 'limit', 50, 1, 100, true)
    if limit_error ~= nil then
        return error_response(400, 'invalid_pagination', limit_error)
    end
    local status = req:query_param('status')
    if status ~= nil and not jobs_module.is_valid_status(status) then
        return error_response(400, 'invalid_status', 'Unknown job status')
    end
    local cursor, cursor_error = decode_cursor(req:query_param('cursor'), status)
    if cursor_error ~= nil then
        return error_response(400, 'invalid_cursor', cursor_error)
    end

    local total, jobs_data, next_cursor, listing_error = jobs_manager.list_all_jobs(
        limit,
        status,
        cursor
    )
    if listing_error ~= nil then
        return error_response(400, 'invalid_cursor', listing_error)
    end
    return json_response(200, {
        total = total,
        limit = limit,
        next_cursor = encode_cursor(next_cursor),
        data = jobs_data,
    })
end)

protected_route({ path = '/jobs/claim', method = 'POST' }, function(req)
    local lease, lease_error = parse_number_query(
        req,
        'lease',
        jobs_module.DEFAULT_LEASE_SECONDS,
        0.1,
        3600,
        false
    )
    if lease_error ~= nil then
        return error_response(400, 'invalid_lease', lease_error)
    end

    local job = jobs_manager.fetch_job(lease)
    if job == nil then
        return { status = 204 }
    end
    return json_response(200, job)
end)

protected_route({ path = '/jobs/:id/ack', method = 'POST' }, function(req)
    local lease_token, token_error = get_lease_token(req)
    if token_error ~= nil then
        return token_error
    end
    local job, transition_error = jobs_manager.ack_job(req:stash('id'), lease_token)
    return transition_response(job, transition_error, 'in-progress')
end)

protected_route({ path = '/jobs/:id/release', method = 'POST' }, function(req)
    local lease_token, token_error = get_lease_token(req)
    if token_error ~= nil then
        return token_error
    end
    local job, transition_error = jobs_manager.release_job(req:stash('id'), lease_token)
    return transition_response(job, transition_error, 'in-progress')
end)

protected_route({ path = '/jobs/:id/fail', method = 'POST' }, function(req)
    local lease_token, token_error = get_lease_token(req)
    if token_error ~= nil then
        return token_error
    end
    local failure, failure_error = parse_json_object(req)
    if failure_error ~= nil then
        return error_response(400, 'invalid_failure', failure_error)
    end
    if type(failure.error) ~= 'string' or #failure.error == 0 or #failure.error > 1000 then
        return error_response(
            400,
            'invalid_failure',
            'error must contain between 1 and 1000 characters'
        )
    end
    if failure.retry ~= nil and type(failure.retry) ~= 'boolean' then
        return error_response(400, 'invalid_failure', 'retry must be a boolean')
    end
    local retry_delay = failure.retry_delay == nil and 0 or tonumber(failure.retry_delay)
    if retry_delay == nil or retry_delay < 0 or retry_delay > 86400 then
        return error_response(
            400,
            'invalid_failure',
            'retry_delay must be a number between 0 and 86400'
        )
    end

    local job, transition_error = jobs_manager.fail_job(
        req:stash('id'),
        lease_token,
        {
            error = failure.error,
            retry = failure.retry ~= false,
            retry_delay = retry_delay,
        }
    )
    return transition_response(job, transition_error, 'in-progress')
end)

protected_route({ path = '/jobs/:id/retry', method = 'POST' }, function(req)
    local job, transition_error = jobs_manager.retry_job(req:stash('id'))
    return transition_response(job, transition_error, 'failed')
end)

protected_route({ path = '/jobs/:id', method = 'GET' }, function(req)
    local job = jobs_manager.get_job_by_id(req:stash('id'))
    if job == nil then
        return error_response(404, 'job_not_found', 'Job was not found')
    end
    return json_response(200, job)
end)

protected_route({ path = '/jobs/:id', method = 'DELETE' }, function(req)
    jobs_manager.delete_job_by_id(req:stash('id'))
    return { status = 204 }
end)

server:start()
