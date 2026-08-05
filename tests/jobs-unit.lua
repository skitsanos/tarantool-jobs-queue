local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local repository_root = script_path:match('^(.*[/\\])tests[/\\]') or './'
package.path = repository_root .. 'src/?.lua;' .. package.path

box.cfg({
    listen = nil,
    wal_mode = 'none',
})

local fiber = require('fiber')
local jobs = require('jobs')

local SPACE_NAME = 'jobs_unit_test'
local VERSION_KEY = 'jobs_queue_schema_version:' .. SPACE_NAME

local function reset_space()
    if box.space[SPACE_NAME] ~= nil then
        box.space[SPACE_NAME]:drop()
    end
    box.space._schema:delete({ VERSION_KEY })
end

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format(
            '%s: expected %s, received %s',
            message,
            tostring(expected),
            tostring(actual)
        ))
    end
end

local function assert_null(value, message)
    if value ~= nil and value ~= box.NULL then
        error(message .. ': expected null, received ' .. tostring(value))
    end
end

local function run()
    reset_space()
    local manager = jobs.new(SPACE_NAME, { default_max_attempts = 2 })

    local first, created = manager.create_job({ kind = 'first' }, {
        idempotency_key = 'unit-idempotency-key',
        max_attempts = 2,
    })
    assert_equal(created, true, 'first idempotent request should create a job')
    assert_equal(first.status, 'pending', 'new job status')
    assert_equal(first.attempts, 0, 'new job attempts')
    assert_equal(first.max_attempts, 2, 'new job attempt cap')
    assert_null(first.lease_token, 'new job lease token')

    local replayed, replay_created = manager.create_job({ kind = 'ignored' }, {
        idempotency_key = 'unit-idempotency-key',
        max_attempts = 9,
    })
    assert_equal(replay_created, false, 'replayed request should not create a job')
    assert_equal(replayed.job_id, first.job_id, 'replayed job identity')
    assert_equal(manager.space:count(), 1, 'idempotency must keep one tuple')

    local count_before_readiness = manager.space:count()
    local readiness = manager.readiness()
    assert_equal(readiness.ready, true, 'queue readiness')
    assert_equal(readiness.schema_ready, true, 'readiness schema check')
    assert_equal(readiness.schema_version, 3, 'readiness schema version')
    assert_equal(readiness.writable, true, 'readiness writable check')
    assert_equal(readiness.write_probe, true, 'readiness write probe')
    assert_equal(
        manager.space:count(),
        count_before_readiness,
        'readiness probe must roll back its tuple'
    )

    box.cfg({ read_only = true })
    local read_only_readiness = manager.readiness()
    box.cfg({ read_only = false })
    assert_equal(read_only_readiness.ready, false, 'read-only queue readiness')
    assert_equal(read_only_readiness.writable, false, 'read-only writable check')
    assert_equal(read_only_readiness.write_probe, false, 'read-only write probe')

    local delayed = manager.create_job({ kind = 'delayed' }, {
        delay = 0.2,
        max_attempts = 2,
    })

    local first_claim = manager.fetch_job(1)
    assert_equal(first_claim.job_id, first.job_id, 'FIFO claim order')
    assert_equal(first_claim.status, 'in-progress', 'claimed job status')
    assert_equal(first_claim.attempts, 1, 'claim increments attempts')

    local invalid_ack, invalid_ack_error = manager.ack_job(first.job_id, 'wrong-token')
    assert_null(invalid_ack, 'invalid lease acknowledgement result')
    assert_equal(invalid_ack_error, 'invalid_lease', 'invalid lease acknowledgement error')

    local acknowledged = manager.ack_job(first.job_id, first_claim.lease_token)
    assert_equal(acknowledged.status, 'done', 'acknowledged job status')
    assert_null(acknowledged.lease_until, 'acknowledged job lease')
    assert_null(acknowledged.lease_token, 'acknowledged job token')

    assert_null(manager.fetch_job(1), 'delayed job must not be claimable early')
    fiber.sleep(0.3)

    local delayed_claim = manager.fetch_job(1)
    assert_equal(delayed_claim.job_id, delayed.job_id, 'delayed job claim')
    local retryable = manager.fail_job(delayed.job_id, delayed_claim.lease_token, {
        error = 'temporary failure',
        retry = true,
        retry_delay = 0,
    })
    assert_equal(retryable.status, 'pending', 'retryable failure status')
    assert_equal(retryable.attempts, 1, 'retryable failure preserves attempts')
    assert_equal(retryable.last_error, 'temporary failure', 'retryable failure message')

    local second_attempt = manager.fetch_job(1)
    assert_equal(second_attempt.job_id, delayed.job_id, 'retry claim identity')
    assert_equal(second_attempt.attempts, 2, 'retry claim attempts')
    local released = manager.release_job(delayed.job_id, second_attempt.lease_token)
    assert_equal(released.status, 'failed', 'release at attempt cap')

    local manually_retried = manager.retry_job(delayed.job_id)
    assert_equal(manually_retried.status, 'pending', 'manual retry status')
    assert_equal(manually_retried.attempts, 0, 'manual retry resets attempts')
    assert_null(manually_retried.last_error, 'manual retry clears last error')

    local terminal_claim = manager.fetch_job(1)
    local terminal = manager.fail_job(delayed.job_id, terminal_claim.lease_token, {
        error = 'permanent failure',
        retry = false,
        retry_delay = 0,
    })
    assert_equal(terminal.status, 'failed', 'non-retryable failure status')
    assert_equal(terminal.last_error, 'permanent failure', 'terminal failure message')

    local expiring = manager.create_job({ kind = 'expiring' }, { max_attempts = 2 })
    local expiring_first = manager.fetch_job(0.1)
    fiber.sleep(0.2)
    local expiring_second = manager.fetch_job(1)
    assert_equal(expiring_second.job_id, expiring.job_id, 'expired lease recovery identity')
    assert_equal(expiring_second.attempts, 2, 'expired lease recovery attempts')
    if expiring_second.lease_token == expiring_first.lease_token then
        error('expired lease recovery must issue a new fencing token')
    end
    local stale_ack, stale_error = manager.ack_job(expiring.job_id, expiring_first.lease_token)
    assert_null(stale_ack, 'stale lease acknowledgement result')
    assert_equal(stale_error, 'invalid_lease', 'stale lease acknowledgement error')
    manager.ack_job(expiring.job_id, expiring_second.lease_token)

    local page_jobs = {}
    for index = 1, 3 do
        page_jobs[index] = manager.create_job({ sequence = index })
    end
    local total, first_page, cursor = manager.list_all_jobs(2, 'pending')
    assert_equal(total, 3, 'pending pagination total')
    assert_equal(#first_page, 2, 'first page size')
    if cursor == nil then
        error('first page should return a cursor')
    end
    local second_total, second_page, next_cursor = manager.list_all_jobs(
        2,
        'pending',
        cursor
    )
    assert_equal(second_total, 3, 'second page total')
    assert_equal(#second_page, 1, 'second page size')
    assert_null(next_cursor, 'last page cursor')
    if first_page[1].job_id == second_page[1].job_id
        or first_page[2].job_id == second_page[1].job_id then
        error('cursor pagination returned a duplicate job')
    end

    local deleted = manager.delete_job_by_id(page_jobs[1].job_id)
    assert_equal(deleted.job_id, page_jobs[1].job_id, 'deleted job identity')
    assert_null(manager.get_job_by_id(page_jobs[1].job_id), 'deleted job lookup')
end

local ok, test_error = xpcall(run, debug.traceback)
reset_space()
if not ok then
    error(test_error)
end

print('Jobs unit tests passed: storage, leases, retries, fencing, and pagination.')
os.exit(0)
