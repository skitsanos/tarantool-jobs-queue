local clock = require('clock')
local migrations = require('migrations')
local uuid = require('uuid')

local jobs = {
    DEFAULT_LEASE_SECONDS = 60,
    DEFAULT_MAX_ATTEMPTS = 3,
    MAX_ATTEMPTS = 100,
}

local FIELD = {
    job_id = 1,
    status = 2,
    payload = 3,
    created_at = 4,
    updated_at = 5,
    available_at = 6,
    lease_until = 7,
    attempts = 8,
    max_attempts = 9,
    last_error = 10,
    idempotency_key = 11,
    lease_token = 12,
}

local STATUS = {
    pending = 'pending',
    in_progress = 'in-progress',
    done = 'done',
    failed = 'failed',
}

local VALID_STATUS = {
    [STATUS.pending] = true,
    [STATUS.in_progress] = true,
    [STATUS.done] = true,
    [STATUS.failed] = true,
}

local function nullable(value)
    if value == nil then
        return box.NULL
    end
    return value
end

local function job_to_table(job)
    if job == nil then
        return nil
    end

    return {
        job_id = job[FIELD.job_id],
        status = job[FIELD.status],
        payload = job[FIELD.payload],
        created_at = job[FIELD.created_at],
        updated_at = job[FIELD.updated_at],
        available_at = job[FIELD.available_at],
        lease_until = job[FIELD.lease_until],
        attempts = job[FIELD.attempts],
        max_attempts = job[FIELD.max_attempts],
        last_error = job[FIELD.last_error],
        idempotency_key = job[FIELD.idempotency_key],
        lease_token = job[FIELD.lease_token],
    }
end

local function is_due(job, now)
    return job ~= nil and job[FIELD.available_at] <= now
end

function jobs.is_valid_status(status)
    return VALID_STATUS[status] == true
end

function jobs.new(space_name, options)
    options = options or {}
    local default_max_attempts = options.default_max_attempts or jobs.DEFAULT_MAX_ATTEMPTS
    local space, schema_version = migrations.apply(space_name, {
        default_max_attempts = default_max_attempts,
    })
    local self = {
        schema_version = schema_version,
        space = space,
    }

    function self.create_job(payload, create_options)
        create_options = create_options or {}
        return box.atomic(function()
            local idempotency_key = create_options.idempotency_key
            if idempotency_key ~= nil then
                local existing = self.space.index.idempotency:get({ idempotency_key })
                if existing ~= nil then
                    return job_to_table(existing), false
                end
            end

            local job_id = uuid.str()
            local now = clock.time()
            local job = self.space:insert({
                job_id,
                STATUS.pending,
                payload,
                now,
                now,
                now + (create_options.delay or 0),
                box.NULL,
                0,
                create_options.max_attempts or default_max_attempts,
                box.NULL,
                nullable(idempotency_key),
                box.NULL,
            })
            return job_to_table(job), true
        end)
    end

    function self.list_all_jobs(limit, status, cursor)
        local tuples = {}
        local iterator
        local key
        local cursor_job

        if cursor ~= nil then
            cursor_job = self.space:get(cursor.job_id)
            if cursor_job == nil
                or (status ~= nil and cursor_job[FIELD.status] ~= status) then
                return nil, nil, nil, 'cursor job no longer exists in this listing'
            end
        end

        if status ~= nil then
            iterator = cursor == nil and 'EQ' or 'GT'
            key = cursor == nil and { status } or {
                status,
                cursor_job[FIELD.created_at],
                cursor_job[FIELD.job_id],
            }
            for _, job in self.space.index.status:pairs(key, { iterator = iterator }) do
                if job[FIELD.status] ~= status then
                    break
                end
                table.insert(tuples, job)
                if #tuples == limit + 1 then
                    break
                end
            end
        else
            if cursor == nil then
                iterator = 'GE'
                key = nil
            else
                iterator = 'GT'
                key = {
                    cursor_job[FIELD.created_at],
                    cursor_job[FIELD.job_id],
                }
            end
            for _, job in self.space.index.created_at:pairs(key, { iterator = iterator }) do
                table.insert(tuples, job)
                if #tuples == limit + 1 then
                    break
                end
            end
        end

        local next_cursor
        if #tuples > limit then
            table.remove(tuples)
            local last_job = tuples[#tuples]
            next_cursor = {
                job_id = last_job[FIELD.job_id],
                status = status or '',
            }
        end

        local result = {}
        for _, job in ipairs(tuples) do
            table.insert(result, job_to_table(job))
        end

        local total = status == nil
            and self.space:count()
            or self.space.index.status:count({ status }, { iterator = 'EQ' })
        return total, result, next_cursor, nil
    end

    local function recover_expired_leases(now)
        local recovered = 0
        while true do
            local job = self.space.index.lease:select({ STATUS.in_progress }, {
                iterator = 'EQ',
                limit = 1,
            })[1]
            if job == nil or job[FIELD.lease_until] > now then
                break
            end

            local attempts = job[FIELD.attempts]
            local max_attempts = job[FIELD.max_attempts]
            if attempts >= max_attempts then
                self.space:update(job[FIELD.job_id], {
                    { '=', FIELD.status, STATUS.failed },
                    { '=', FIELD.updated_at, now },
                    { '=', FIELD.lease_until, box.NULL },
                    { '=', FIELD.lease_token, box.NULL },
                    { '=', FIELD.last_error, 'processing lease expired after maximum attempts' },
                })
            else
                self.space:update(job[FIELD.job_id], {
                    { '=', FIELD.status, STATUS.pending },
                    { '=', FIELD.updated_at, now },
                    { '=', FIELD.available_at, now },
                    { '=', FIELD.lease_until, box.NULL },
                    { '=', FIELD.lease_token, box.NULL },
                    { '=', FIELD.last_error, 'processing lease expired' },
                })
            end
            recovered = recovered + 1
        end
        return recovered
    end

    function self.fetch_job(lease_seconds)
        lease_seconds = lease_seconds or jobs.DEFAULT_LEASE_SECONDS
        return box.atomic(function()
            local now = clock.time()
            recover_expired_leases(now)

            while true do
                local job = self.space.index.ready:select({ STATUS.pending }, {
                    iterator = 'EQ',
                    limit = 1,
                })[1]
                if not is_due(job, now) then
                    return nil
                end

                if job[FIELD.attempts] >= job[FIELD.max_attempts] then
                    self.space:update(job[FIELD.job_id], {
                        { '=', FIELD.status, STATUS.failed },
                        { '=', FIELD.updated_at, now },
                        { '=', FIELD.last_error, 'maximum attempts reached before claim' },
                    })
                else
                    local updated_job = self.space:update(job[FIELD.job_id], {
                        { '=', FIELD.status, STATUS.in_progress },
                        { '=', FIELD.updated_at, now },
                        { '=', FIELD.lease_until, now + lease_seconds },
                        { '=', FIELD.lease_token, uuid.str() },
                        { '+', FIELD.attempts, 1 },
                    })
                    return job_to_table(updated_job)
                end
            end
        end)
    end

    local function get_in_progress_job(job_id, lease_token)
        local job = self.space:get(job_id)
        if job == nil then
            return nil, 'not_found'
        end
        if job[FIELD.status] ~= STATUS.in_progress then
            return nil, 'invalid_state'
        end
        if job[FIELD.lease_token] ~= lease_token then
            return nil, 'invalid_lease'
        end
        local now = clock.time()
        if job[FIELD.lease_until] <= now then
            recover_expired_leases(now)
            return nil, 'lease_expired'
        end
        return job
    end

    function self.ack_job(job_id, lease_token)
        return box.atomic(function()
            local _, job_error = get_in_progress_job(job_id, lease_token)
            if job_error ~= nil then
                return nil, job_error
            end
            local updated_job = self.space:update(job_id, {
                { '=', FIELD.status, STATUS.done },
                { '=', FIELD.updated_at, clock.time() },
                { '=', FIELD.lease_until, box.NULL },
                { '=', FIELD.lease_token, box.NULL },
            })
            return job_to_table(updated_job)
        end)
    end

    function self.fail_job(job_id, lease_token, failure_options)
        return box.atomic(function()
            local job, job_error = get_in_progress_job(job_id, lease_token)
            if job_error ~= nil then
                return nil, job_error
            end

            local now = clock.time()
            local should_retry = failure_options.retry
                and job[FIELD.attempts] < job[FIELD.max_attempts]
            local new_status = should_retry and STATUS.pending or STATUS.failed
            local available_at = should_retry
                and now + failure_options.retry_delay
                or job[FIELD.available_at]
            local updated_job = self.space:update(job_id, {
                { '=', FIELD.status, new_status },
                { '=', FIELD.updated_at, now },
                { '=', FIELD.available_at, available_at },
                { '=', FIELD.lease_until, box.NULL },
                { '=', FIELD.lease_token, box.NULL },
                { '=', FIELD.last_error, failure_options.error },
            })
            return job_to_table(updated_job)
        end)
    end

    function self.release_job(job_id, lease_token)
        return self.fail_job(job_id, lease_token, {
            error = 'job released by worker',
            retry = true,
            retry_delay = 0,
        })
    end

    function self.retry_job(job_id)
        return box.atomic(function()
            local job = self.space:get(job_id)
            if job == nil then
                return nil, 'not_found'
            end
            if job[FIELD.status] ~= STATUS.failed then
                return nil, 'invalid_state'
            end

            local now = clock.time()
            local updated_job = self.space:update(job_id, {
                { '=', FIELD.status, STATUS.pending },
                { '=', FIELD.updated_at, now },
                { '=', FIELD.available_at, now },
                { '=', FIELD.lease_until, box.NULL },
                { '=', FIELD.lease_token, box.NULL },
                { '=', FIELD.attempts, 0 },
                { '=', FIELD.last_error, box.NULL },
            })
            return job_to_table(updated_job)
        end)
    end

    function self.get_job_by_id(job_id)
        return job_to_table(self.space:get(job_id))
    end

    function self.delete_job_by_id(job_id)
        return job_to_table(self.space:delete(job_id))
    end

    return self
end

return jobs
