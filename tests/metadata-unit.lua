local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local script_dir = script_path:match('^(.*[/\\])') or './'
package.path = script_dir .. '../src/?.lua;' .. package.path

local metadata = require('metadata')

assert(metadata.name == 'tarantool-jobs-queue', 'project name must come from metadata')
assert(type(metadata.api_version) == 'string', 'API version must be a string')
assert(
    metadata.api_version:match('^%d+%.%d+%.%d+%-[%w%.%-]+$') ~= nil,
    'API version must use semantic prerelease version syntax'
)

local openapi_file = assert(io.open(script_dir .. '../docs/openapi.yaml', 'r'))
local openapi = openapi_file:read('*a')
openapi_file:close()
local documented_version = openapi:match('\n%s+version:%s*([%w%.%-]+)')
assert(
    documented_version == metadata.api_version,
    'OpenAPI info.version must match project metadata'
)

print('Metadata unit tests passed: project identity, API version, and OpenAPI version.')
