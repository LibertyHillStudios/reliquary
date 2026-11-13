-- C_EncodingUtil for the test client: CBOR, raw DEFLATE and Base64 in the real formats, so a
-- message packed here is one the game would read. DEFLATE writes stored blocks only (valid
-- DEFLATE that any inflater reads, just not smaller), and reads only those.
local floor, char, byte, concat = math.floor, string.char, string.byte, table.concat

local function head(major, n, out)
    if n < 24 then out[#out + 1] = char(major * 32 + n)
    elseif n < 256 then out[#out + 1] = char(major * 32 + 24, n)
    elseif n < 65536 then out[#out + 1] = char(major * 32 + 25, floor(n / 256), n % 256)
    elseif n < 4294967296 then out[#out + 1] = char(major * 32 + 26, floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
    else
        local hi, lo = floor(n / 4294967296), n % 4294967296
        out[#out + 1] = char(major * 32 + 27, floor(hi / 16777216) % 256, floor(hi / 65536) % 256, floor(hi / 256) % 256, hi % 256,
            floor(lo / 16777216) % 256, floor(lo / 65536) % 256, floor(lo / 256) % 256, lo % 256)
    end
end

local function double(x)
    local sign = 0
    if x ~= x then return char(127, 248, 0, 0, 0, 0, 0, 0) end
    if x < 0 or (x == 0 and 1 / x < 0) then sign, x = 128, -x end
    if x == math.huge then return char(sign + 127, 240, 0, 0, 0, 0, 0, 0) end
    if x == 0 then return char(sign, 0, 0, 0, 0, 0, 0, 0) end
    local m, e = math.frexp(x) -- x = m * 2^e with 0.5 <= m < 1
    local exp, frac = e + 1022, nil
    if exp <= 0 then frac, exp = math.ldexp(m, 52 + exp - 1 + 1), 0 else frac = (m * 2 - 1) * 2 ^ 52 end
    frac = floor(frac + 0.5)
    local out = { sign + floor(exp / 16), (exp % 16) * 16 + floor(frac / 2 ^ 48) % 16 }
    for i = 5, 0, -1 do out[#out + 1] = floor(frac / 2 ^ (i * 8)) % 256 end
    return char(unpack(out))
end

local function isArray(t)
    local n = #t
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k ~= floor(k) then return false end
        count = count + 1
    end
    return count == n
end

local function encodeValue(v, out, depth)
    assert(depth < 64, "too deep")
    local t = type(v)
    if t == "nil" then out[#out + 1] = char(0xf6)
    elseif t == "boolean" then out[#out + 1] = char(v and 0xf5 or 0xf4)
    elseif t == "number" then
        if v == floor(v) and v > -2 ^ 53 and v < 2 ^ 53 then
            if v >= 0 then head(0, v, out) else head(1, -1 - v, out) end
        else
            out[#out + 1] = char(0xfb) .. double(v)
        end
    elseif t == "string" then
        head(3, #v, out)
        out[#out + 1] = v
    elseif t == "table" then
        if isArray(v) then
            head(4, #v, out)
            for i = 1, #v do encodeValue(v[i], out, depth + 1) end
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            head(5, #keys, out)
            for _, k in ipairs(keys) do
                encodeValue(k, out, depth + 1)
                encodeValue(v[k], out, depth + 1)
            end
        end
    else
        error("cannot serialize a " .. t)
    end
end

local function decoder(s)
    local pos = 1
    local function take(n)
        assert(pos + n - 1 <= #s, "CBOR cut short")
        local piece = s:sub(pos, pos + n - 1)
        pos = pos + n
        return piece
    end
    local function uint(info)
        if info < 24 then return info end
        local size = ({ [24] = 1, [25] = 2, [26] = 4, [27] = 8 })[info]
        assert(size, "bad CBOR length")
        local n = 0
        for i = 1, size do n = n * 256 + byte(take(1)) end
        return n
    end
    local function readDouble()
        local b = { byte(take(8), 1, 8) }
        local sign = b[1] >= 128 and -1 or 1
        local exp = (b[1] % 128) * 16 + floor(b[2] / 16)
        local frac = b[2] % 16
        for i = 3, 8 do frac = frac * 256 + b[i] end
        if exp == 2047 then return frac == 0 and sign * math.huge or 0 / 0 end
        if exp == 0 then return sign * math.ldexp(frac, -1074) end
        return sign * math.ldexp(frac + 2 ^ 52, exp - 1075)
    end
    local value
    function value(depth)
        assert(depth < 64, "too deep")
        local b = byte(take(1))
        local major, info = floor(b / 32), b % 32
        if major == 0 then return uint(info) end
        if major == 1 then return -1 - uint(info) end
        if major == 2 or major == 3 then return take(uint(info)) end
        if major == 4 then
            local t = {}
            for i = 1, uint(info) do t[i] = value(depth + 1) end
            return t
        end
        if major == 5 then
            local t = {}
            for _ = 1, uint(info) do
                local k = value(depth + 1)
                t[k] = value(depth + 1)
            end
            return t
        end
        if b == 0xf4 then return false end
        if b == 0xf5 then return true end
        if b == 0xf6 or b == 0xf7 then return nil end
        if b == 0xfb then return readDouble() end
        error("CBOR item not handled here: " .. b)
    end
    return function()
        local v = value(0)
        assert(pos == #s + 1, "CBOR has trailing bytes")
        return v
    end
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = byte(s, i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local q = { floor(n / 262144) % 64, floor(n / 4096) % 64, floor(n / 64) % 64, n % 64 }
        out[#out + 1] = B64:sub(q[1] + 1, q[1] + 1) .. B64:sub(q[2] + 1, q[2] + 1)
            .. (b and B64:sub(q[3] + 1, q[3] + 1) or "=") .. (c and B64:sub(q[4] + 1, q[4] + 1) or "=")
    end
    return concat(out)
end

local function unbase64(s)
    assert(#s % 4 == 0 and not s:find("[^%w%+/=]"), "not Base64")
    local out = {}
    for i = 1, #s, 4 do
        local n, pad = 0, 0
        for j = i, i + 3 do
            local ch = s:sub(j, j)
            if ch == "=" then pad = pad + 1 n = n * 64 else n = n * 64 + (B64:find(ch, 1, true) - 1) end
        end
        local bytes = { floor(n / 65536) % 256, floor(n / 256) % 256, n % 256 }
        out[#out + 1] = char(unpack(bytes, 1, 3 - pad))
    end
    return concat(out)
end

local function deflateStored(s)
    local out, i = {}, 1
    repeat
        local piece = s:sub(i, i + 65534)
        i = i + #piece
        local final = i > #s and 1 or 0
        local len = #piece
        out[#out + 1] = char(final, len % 256, floor(len / 256), (65535 - len) % 256, floor((65535 - len) / 256)) .. piece
    until i > #s
    return concat(out)
end

local function inflateStored(s)
    local out, pos = {}, 1
    while true do
        local h = byte(s, pos)
        assert(h, "DEFLATE cut short")
        assert(floor(h / 2) % 4 == 0, "only stored DEFLATE blocks are read in the test client")
        local len = byte(s, pos + 1) + byte(s, pos + 2) * 256
        local nlen = byte(s, pos + 3) + byte(s, pos + 4) * 256
        assert(len + nlen == 65535, "bad stored block")
        out[#out + 1] = s:sub(pos + 5, pos + 4 + len)
        assert(#out[#out] == len, "DEFLATE cut short")
        pos = pos + 5 + len
        if h % 2 == 1 then break end
    end
    return concat(out)
end

return {
    SerializeCBOR = function(v) local out = {} encodeValue(v, out, 0) return concat(out) end,
    DeserializeCBOR = function(s) return decoder(s)() end,
    CompressString = function(s, method) assert(method == 0, "Deflate only") return deflateStored(s) end,
    DecompressString = function(s, method) assert(method == 0, "Deflate only") return inflateStored(s) end,
    EncodeBase64 = function(s) return base64(s) end,
    DecodeBase64 = function(s) return unbase64(s) end,
}
