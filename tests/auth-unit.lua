local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local script_dir = script_path:match('^(.*[/\\])') or './'
package.path = script_dir .. '../src/?.lua;' .. package.path

local auth = require('auth')

local function expect_error(token, expected_message)
    local ok, error_message = pcall(auth.new, token)
    assert(not ok, 'invalid authentication configuration must be rejected')
    assert(
        tostring(error_message):find(expected_message, 1, true) ~= nil,
        'unexpected authentication configuration error: ' .. tostring(error_message)
    )
end

local disabled = auth.new(nil)
assert(not disabled.enabled, 'authentication must be disabled when no token is configured')
assert(disabled.is_authorized(nil), 'disabled authentication must preserve local compatibility')

local token = string.rep('a', auth.MIN_TOKEN_LENGTH)
local enabled = auth.new(token)
assert(enabled.enabled, 'authentication must be enabled when a token is configured')
assert(enabled.is_authorized('Bearer ' .. token), 'the configured bearer token must pass')
assert(enabled.is_authorized('bearer ' .. token), 'the bearer scheme must be case-insensitive')
assert(not enabled.is_authorized(nil), 'a missing Authorization header must fail')
assert(not enabled.is_authorized('Basic ' .. token), 'another authentication scheme must fail')
assert(not enabled.is_authorized('Bearer wrong-token'), 'an incorrect bearer token must fail')
assert(not enabled.is_authorized('Bearer ' .. token .. ' trailing'), 'extra credentials must fail')

expect_error('', 'between 32 and 512 characters')
expect_error('too-short', 'between 32 and 512 characters')
expect_error(string.rep('a', auth.MAX_TOKEN_LENGTH + 1), 'between 32 and 512 characters')
expect_error(string.rep('a', auth.MIN_TOKEN_LENGTH) .. ' ', 'whitespace or control')

print('Authentication unit tests passed: configuration and bearer validation.')
