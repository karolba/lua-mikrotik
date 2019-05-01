# lua-mikrotik

A lightweight lua library for talking to the [Mikrotik RouterOS API](https://wiki.mikrotik.com/wiki/Manual:API).

## Requirements: 

* Either:
	* [luasocket](https://github.com/diegonehab/luasocket)
	* Either the [kikito's md5 library](https://github.com/kikito/md5.lua) or the [keplerproject's md5 library](https://github.com/keplerproject/md5)
	* On older Lua versions with no `bit32` (`<= 5.1`), either [BitOp](http://luaforge.net/projects/bit/), or [BitLib](https://github.com/LuaDist/bitlib)
* or [OpenResty](https://openresty.org/en/), which contains all these dependencies.

## Documentation:

For documentation see [doc/api.md](https://github.com/karolba/lua-mikrotik/blob/master/doc/api.md).

## Examples:

Starting a RouterOS script from `/system/script` by name synchronously:

```lua
local Mikrotik = require 'Mikrotik'

local function runScript(mt, scriptname)
    assert(mt:sendSentence({ '/system/script/print', '?name=' .. scriptname, '=.proplist=.id' }))

    local message = assert(mt:readSentence())
    assert(message.type == '!re')
    assert(mt:readSentence().type == '!done')

    assert(mt:sendSentence({ '/system/script/run', '=number=' .. message['=.id']}))
    assert(mt:readSentence().type == '!done')

    print('OK!')
end

local mt = assert(Mikrotik:create('192.168.88.1'))
assert(mt:login('login', 'password'), 'Failed login')

runScript(mt, 'example-routeros-script-name')
```

The same result can be accomplished by using "tagged sentences" and callbacks:

```lua
local Mikrotik = require 'Mikrotik'

local function runScript(mt, scriptname)
    assert(mt:sendSentence({ '/system/script/print', '?name=' .. scriptname, '=.proplist=.id' }, function(res)
        if res.type == '!re' then
            assert(mt:sendSentence({ '/system/script/run', '=number=' .. res['=.id'] }, function(res)
                if res.type == '!done' then
                    print('OK!')
                end
            end))
        end
    end))
end

local mt = assert(Mikrotik:create('192.168.88.1'))
assert(mt:login('login', 'password'), 'Failed login')

runScript(mt, 'example-routeros-script-name')

assert(mt:wait())
```
