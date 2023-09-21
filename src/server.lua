package.path = '/app/?.lua;' .. package.path

box.cfg({
    listen = '0.0.0.0:3301',
    --replication = { '0.0.0.0:3302', '0.0.0.0:3303' },
})

local jobs_module = require('jobs')
local jobs_manager = jobs_module.new('jobs_space')

local httpd = require('http.server')
local json = require('json')
local server = httpd.new('0.0.0.0', 3000)

server:route({ path = '/version', method = 'GET' }, function()
    return { status = 200, body = json.encode({
        version = '1.0.0beta'
    }) }
end)

server:route({ path = '/jobs', method = 'POST' }, function(req)
    local payload = req:json()
    local job_id = jobs_manager.create_job(payload)
    return { status = 201, body = json.encode({ job_id = job_id }) }
end)

server:route({ path = '/jobs', method = 'GET' }, function(req)
    local limit = tonumber(req:query_param('limit')) or 50
    local offset = tonumber(req:query_param('offset')) or 0
    local status = req:query_param('status') -- This will be nil if not provided
    local total, jobs_data = jobs_manager.list_all_jobs(limit, offset, status)
    local response = {
        total = total,
        limit = limit,
        offset = offset,
        data = jobs_data
    }
    return { status = 200, body = json.encode(response) }
end)

server:route({ path = '/jobs/:id', method = 'GET' }, function(req)
    local job_id = req:stash('id')
    local job = jobs_manager.get_job_by_id(job_id)
    return { status = 200, body = json.encode(job) }
end)

server:route({ path = '/jobs/:id', method = 'DELETE' }, function(req)
    local job_id = req:stash('id')
    jobs_manager.delete_job_by_id(job_id)
    return { status = 204 }
end)

server:start()
