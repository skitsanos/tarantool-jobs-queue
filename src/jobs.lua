local uuid = require('uuid')
local jobs = {}

function jobs.new(space_name)
    local self = {
        space = box.space[space_name]
    }

    if not self.space then
        -- Create the space if it doesn't exist
        self.space = box.schema.space.create(space_name,
                {
                    if_not_exists = true,
                    format = {
                        { name = 'job_id', type = 'string' },
                        { name = 'status', type = 'string' },
                        { name = 'payload', type = 'map' }
                    }
                })

        --self.space:create_index('primary', { if_not_exists = true, sequence = true })
        self.space:create_index('primary', {
            type = 'hash',
            parts = { 'job_id' },
            if_not_exists = true
        })
    end

    -- Internal function to generate a unique job ID
    local function generate_job_id()
        return uuid.str()
    end

    function self.create_job(payload)
        local job_id = generate_job_id()
        self.space:insert { job_id, 'pending', payload }
        return job_id
    end

    function self.list_all_jobs(limit, offset, status)
        limit = limit or 50  -- Default limit is 50
        offset = offset or 0 -- Default offset is 0

        local result_set
        local total

        if status then
            result_set = self.space.index.primary:select(status, { limit = limit, offset = offset })
            total = #self.space.index.primary:select(status)
        else
            result_set = self.space:select(nil, { limit = limit, offset = offset })
            total = self.space:count()
        end

        return total, result_set
    end

    function self.fetch_job()
        local job = self.space.index.primary:select('pending')[1]
        if job then
            self.space:update(job[1], { { '=', 2, 'in-progress' } })
        end
        return job
    end

    function self.get_job_by_id(job_id)
        return self.space:get(job_id)
    end

    function self.delete_job_by_id(job_id)
        self.space:delete(job_id)
    end

    return self
end

return jobs
