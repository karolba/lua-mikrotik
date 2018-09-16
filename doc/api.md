### `Mikrotik:create(<ip>, [port], [timeout])`

Connects to the given `ip` address and `port`. The optional `timeout` parameter tells
`luasocket` how long to wait on reads in seconds.  Creates a `mt` object, returns `nil` on connection failures.

If `port` is unspecified, the default value of `8728` is used.

### `mt:login(<username>, <password>)`

Authenticates with the endpoint. This has to be the first method called on the `mt` object. Returns
`true` on a successfull login and `nil` on failure.

### `mt:sendSentence(<sentence>, [callback])`

Sends the `sentence` to the remote endpoint. Sentence should always be a table, as per the 
[RouterOS API](https://wiki.mikrotik.com/wiki/Manual:API). Returns number of bytes written,
or `nil` on failure.

If the optional `callback` parameter is provided, the sentence will be assigned a unique tag,
and every received response with the same tag will be passed to the callback, instead of being
returned from `mt:readSentence()`. Note that for this to work `mt:readSentence()` or `mt:wait()`
has to be called, as this library is not asynchronous.

Example usage:

```lua
local packages = 0

mt:sendSentence({ '/system/package/print' }, function(res)
    if res.type == '!re' then
        print("RouterOS package: " .. res['=name'] .. " version " .. res['=version'])
        packages = packages + 1
    elseif res.type == '!done' then
        print("Number of packages: " .. packages)
    end
end)

mt:wait()
```

### `mt:readSentence()`

Reads the next sentence from the remote endpoint, synchronously. Depending on the value of `timeout`
given in the constructor, either blocks indefinitely or `timeout` seconds. Returns `nil` on failure,
throws an `error` on timeout. Does not return sentences with registered callback.

The returned `sentence` table is mapped from the response. The first line of the received sentence,
(typically one of `!re`, `!data`, `!trap`, or `!fatal`) becomes the `sentence.type` field.

For example, this raw sentence received from RouterOS

    {
        '!re',
        '=disabled=no',
        '=name=routeros-x86',
        ''
    }

would be translated to and returned from `readSentence()` as

    {
        type = '!re',
        '=disabled' = 'no',
        '=name' = 'routeros-x86'
    }

### `mt:wait()`

Waits for all tagged sentences with callbacks to complete. Returns `true` when a non-handled sentence is
ready to be read by `mt:readSentence()` and `nil` on failure.

### `mt.debug = <true/false>`

Whether to display all communication with the endpoint on stdout
