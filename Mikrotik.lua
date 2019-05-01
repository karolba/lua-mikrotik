-- Compatibility with Lua 5.1 with no built-in bitwise operations. 
if not pcall(require, 'bit32') then
    -- The BitOp library required.
    require('bit')
    bit32 = bit
end
local bnot, band, bor = bit32.bnot, bit32.band, bit32.bor
local lrotate, rrotate = bit32.lrotate or bit32.lshift, bit32.rrotate or bit32.rshift

-- openresty?
local has_ngx, ngx = pcall(require, 'ngx')

local socket = (has_ngx and ngx.socket) or require('socket') 
local md5 = (has_ngx and ngx.md5) or require('md5')


local DEFAULT_PORT = 8728

local function table_empty(t)
    return next(t) == nil
end

local function byte(int, byteIdx)
    local shifted = rrotate(int, 8 * byteIdx)
    return band(shifted, 0xff)
end

local function hextostring(str)
    return (str:gsub('..', function(encodedByte)
        return string.char(tonumber(encodedByte, 16))
    end))
end

local function md5sumhex(str)
    if type(md5) == 'function' then
        -- Openresty md5
        return md5(str)
    elseif md5.sumhexa then
        -- MD5
        return md5.sumhexa(str)
    elseif md5.new and md5.tohex then
        -- md5.lua
        local sum = md5.new()
        sum:update(str)
        return md5.tohex(sum:finish())
    else
        error('Unknown md5 library detected')
    end
end

local function parseWord(word)
    local _, equalsPos = string.find(word, '.=')
    if not equalsPos then
        return "type", word
    end

    local tag = word:sub(1, equalsPos - 1)
    local value = word:sub(equalsPos + 1)
    return tag, value
end

local function encodeLength(l)
    local char = string.char

    if l < 0x80 then
        return char(l)
    elseif l < 0x4000 then
        local l = bor(l, 0x8000)
        return
            char(byte(l, 1)) ..
            char(byte(l, 0))
    elseif l < 0x200000 then
        local l = bor(l, 0xC00000)
        return
            char(byte(l, 2)) ..
            char(byte(l, 1)) ..
            char(byte(l, 0))
    elseif l < 0x10000000 then
        local l = bor(l, 0xE0000000)
        return
            char(byte(l, 3)) ..
            char(byte(l, 2)) ..
            char(byte(l, 1)) ..
            char(byte(l, 0))
    else
        return
            '\xF0' .. 
            char(byte(l, 3)) ..
            char(byte(l, 2)) ..
            char(byte(l, 1)) ..
            char(byte(l, 0))
    end
end

local function encodeWord(word)
    return encodeLength(string.len(word)) .. word
end

-- class Mikrotik

local Mikrotik = {}
Mikrotik.__index = Mikrotik

function Mikrotik:create(address, port, timeout)
    local mtk = {}
    setmetatable(mtk, Mikrotik)
    
    local client = socket.tcp()
    if timeout then
        client:settimeout(timeout)
    end
    if not client:connect(address, port or DEFAULT_PORT) then
        return nil
    end

    mtk.client = client
    mtk.nextSentenceTagId = 0
    mtk.tagToCallbackTable = {}
    mtk.debug = false

    return mtk
end

function Mikrotik:readByte()
    return self.client:receive(1):byte(1)
end

function Mikrotik:readLen()
    local l = self:readByte()
    if band(l, 0x80) == 0x00 then
        return l
    elseif band(l, 0xc0) == 0x80 then
        l = band(l, bnot(0xc0))

        return
            lrotate(l, 8) +
            self:readByte()
    elseif band(l, 0xe0) == 0xc0 then
        l = band(l, bnot(0xc0))

        return 
            lrotate(l, 16) +
            lrotate(self:readByte(), 8) +
            self:readByte() 
    elseif band(l, 0xf0) == 0xe0 then
        l = band(l, bnot(0xf0))

        return 
            lrotate(l, 24) + 
            lrotate(self:readByte(), 16) +
            lrotate(self:readByte(), 8) +
            self:readByte()
    elseif band(l, 0xf8) == 0xf0 then
        return
            lrotate(self:readByte(), 24) +
            lrotate(self:readByte(), 16) +
            lrotate(self:readByte(), 8) +
            self:readByte()
    end
end

-- Gets a tag from a message going to be sent
local function getTag(sentence)
    local function starts_with(str, start)
        return str:sub(1, #start) == start
    end

    local TAG_PREFIX = '.tag='

    for i, word in ipairs(sentence) do
        if starts_with(word, TAG_PREFIX) then
            return word:sub(#TAG_PREFIX + 1)
        end
    end

    return nil
end

function Mikrotik:sendSentence(sentence, callback) 
    if self.debug then
        for k, v in ipairs(sentence) do
            print(">>>>>>", v)
        end
    end
    local message = ""
    for i, word in ipairs(sentence) do
        message = message .. encodeWord(word)
    end

    if callback then
        local tag = getTag(sentence)
        if not tag then
            tag = self:nextTag()
            message = message .. encodeWord('.tag=' .. tag)
            if self.debug then
                print(">>>>>> (added by sendSentence) ", '.tag=' .. tag)
            end
        end

        self.tagToCallbackTable[tag] = callback
    end

    if self.debug then
        print(">>>>>>")
    end
    -- The closing empty word - essentialy a null byte
    message = message .. '\0'
    return self:send(message)
end

function Mikrotik:readWord()
    local len = self:readLen()
    if not len or len == 0 then
        return nil
    end
    return self.client:receive(len)
end

function Mikrotik:readSentenceBypassingCallbacks()
    local sentence = {}
    while true do
        local word = self:readWord()
        if not word then
            if self.debug then
                for k, v in pairs(sentence) do
                    print("<<<<<<", k, v)
                end
                print("<<<<<<")
            end
            return sentence
        end

        local tag, value = parseWord(word)
        sentence[tag] = value
    end
end

function Mikrotik:handleCallback(sentence)
    local tag = sentence['.tag']
    if not tag then
        return false
    end

    local callback = self.tagToCallbackTable[tag]
    if not callback then
        return false
    end

    callback(sentence)

    local type = sentence.type
    if type == '!done' or type == '!trap' then
        self.tagToCallbackTable[tag] = nil
    end

    return true
end

function Mikrotik:readSentence()
    if self.queuedSentence then
        self.queuedSentence = nil
        return self.queuedSentence
    end
    local sentence
    repeat 
        sentence = self:readSentenceBypassingCallbacks()
    until not self:handleCallback(sentence) or table_empty(self.tagToCallbackTable)
    return sentence
end

function Mikrotik:send(message)
    return self.client:send(message)
end

function Mikrotik:wait()
    local sentence = self:readSentence()
    self.queuedSentence = sentence
    return sentence
end

function Mikrotik:nextTag()
    self.nextSentenceTagId = self.nextSentenceTagId + 1
    return "lua-mtk-" .. self.nextSentenceTagId
end

function Mikrotik:login(user, pass)
    self:sendSentence({ "/login" })

    local loginResponse = self:readSentence()
    if not loginResponse or loginResponse.type ~= '!done' then
        return nil
    end

    local challange = hextostring(loginResponse['=ret'])

    local sum = md5sumhex('\0' .. pass .. challange)

    self:sendSentence({ "/login", "=name=" .. user, "=response=00" .. sum })
 
    local challangeResponse = self:readSentence()
    if not challangeResponse or challangeResponse.type ~= '!done' then
        -- Bad credentials?
        return nil
    end

    return true
end

return Mikrotik
