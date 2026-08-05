local bit = require('bit')

local M = {}

local MIN_TOKEN_LENGTH = 32
local MAX_TOKEN_LENGTH = 512

local function constant_time_equals(left, right)
    left = left or ''
    right = right or ''

    local difference = bit.bxor(#left, #right)
    for index = 1, MAX_TOKEN_LENGTH do
        difference = bit.bor(
            difference,
            bit.bxor(left:byte(index) or 0, right:byte(index) or 0)
        )
    end
    return difference == 0
end

local function validate_token(token)
    if token == nil then
        return
    end
    if #token < MIN_TOKEN_LENGTH or #token > MAX_TOKEN_LENGTH then
        error(string.format(
            'API_BEARER_TOKEN must contain between %d and %d characters',
            MIN_TOKEN_LENGTH,
            MAX_TOKEN_LENGTH
        ))
    end
    if token:find('%s') ~= nil or token:find('%c') ~= nil then
        error('API_BEARER_TOKEN must not contain whitespace or control characters')
    end
end

function M.new(token)
    validate_token(token)

    local authenticator = {
        enabled = token ~= nil,
    }

    function authenticator.is_authorized(authorization_header)
        if not authenticator.enabled then
            return true
        end
        if type(authorization_header) ~= 'string' then
            return false
        end

        local scheme, credentials = authorization_header:match('^(%S+)%s+(%S+)$')
        if scheme == nil or scheme:lower() ~= 'bearer' then
            return false
        end
        return constant_time_equals(credentials, token)
    end

    return authenticator
end

M.MIN_TOKEN_LENGTH = MIN_TOKEN_LENGTH
M.MAX_TOKEN_LENGTH = MAX_TOKEN_LENGTH

return M
