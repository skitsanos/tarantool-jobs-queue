local http_client = require('http.client')

local port = tonumber(os.getenv('HTTP_PORT')) or 3000
local token = os.getenv('API_BEARER_TOKEN')
local headers = {}
if token ~= nil then
    headers.authorization = 'Bearer ' .. token
end

local ok, response = pcall(http_client.get, string.format(
    'http://127.0.0.1:%d/health/ready',
    port
), {
    headers = headers,
    timeout = 2,
})

if not ok or response == nil or response.status ~= 200 then
    os.exit(1)
end

os.exit(0)
