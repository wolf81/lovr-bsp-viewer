local ffi = require 'ffi'

local Pak = {}

-- Define C-style structures for reading binary data efficiently
ffi.cdef[[
    typedef struct {
        char name[56];   // File path (null-terminated if shorter)
        int32_t offset;  // Offset of file data
        int32_t length;  // Length of file data
    } entry_t;

    typedef struct {
        char signature[4]; // "PACK"
        int32_t dir_offset; // Offset to directory
        int32_t dir_length; // Length of directory (in bytes)
    } header_t;
]]

local thread = lovr.thread.newThread('map_loader.lua')
local channel = lovr.thread.newChannel()

local function filter(list, predicate)
    local result = {}
    for _, v in ipairs(list) do
        if predicate(v) then
            table.insert(result, v)
        end
    end
    return result
end

local function map(list, transform)
    local result = {}
    for i, v in ipairs(list) do
        result[i] = transform(v)
    end
    return result
end

local function hasPrefix(str, prefix)
    return string.find(str, "^" .. prefix) ~= nil
end

local function loadEntry(pak_path, entry)
    local file = io.open(pak_path, 'rb')
    file:seek('set', entry.offset)
    local data = file:read(entry.length)
    local blob = lovr.data.newBlob(data, entry.name)
    file:close()

    return blob
end

Pak.new = function(path)
    local dir_path = lovr.filesystem.getSource()
    local pak_path = dir_path .. '/' .. path

    local file = io.open(pak_path, 'rb')
    if not file then error('Failed to open PAK file: ' .. path) end

    -- Read header
    local header = ffi.new('header_t')
    file:read(ffi.sizeof(header))
    file:seek('set', 0)  -- Reset position for direct read
    ffi.copy(header, file:read(ffi.sizeof(header)), ffi.sizeof(header))

    -- Verify signature
    if ffi.string(header.signature, 4) ~= 'PACK' then
        error('Invalid PAK file: Bad signature')
    end

    -- Read directory entries
    local num_entries = header.dir_length / ffi.sizeof('entry_t')
    file:seek('set', header.dir_offset)
    
    local entries = {}
    for i = 1, num_entries do
        local entry = ffi.new('entry_t')
        ffi.copy(entry, file:read(ffi.sizeof(entry)), ffi.sizeof(entry))
        entries[i] = {
            name = ffi.string(entry.name, 56):match('[^%z]+'), -- Remove null bytes
            offset = entry.offset,
            length = entry.length
        }
    end

    file:close()

    for _, entry in ipairs(entries) do
        print(string.format("File: %s, Offset: %d, Size: %d", entry.name, entry.offset, entry.length))
    end

    local contents = {
        maps = filter(entries, function(e) return hasPrefix(e.name, 'maps/') end),
        palette = nil,
    }

    local mapNames = function(self)
        -- return map names, removing 'maps/' prefix
        return map(contents.maps, function(m) return string.sub(m.name, 6) end)
    end    

    local loadMap = function(self, ...)
        if thread:isRunning() then 
            error(thread:getError() or 'Wait for map loading to complete.') 
        end

        local args = {...}

        if #args == 0 then
            error('Cannot load map, missing arguments.')
        end

        -- the last argument should be a callback function
        if type(args[#args]) ~= 'function' then
            error('The last argument should be a callback function.')
        end 

        local fn = args[#args]

        -- by default load the first map, named 'start.bsp'
        local map_name = 'maps/start.bsp'

        -- however, if the first argument is a string, use this value as map name to load
        if #args == 2 then
            if type(args[1]) == 'string' then
                map_name = string.format('maps/%s', args[1])
            else
                error('The first argument should be a map name.')
            end
        end        

        local map_info = filter(contents.maps, function(e) return e.name == map_name end)
        if #map_info == 0 then
            error(string.format('Map not found: %s', map_name))
        end

        print(string.format('load: %s', map_name))
        local map_data = loadEntry(pak_path, map_info[1])

        -- load palette if needed, so we can draw textures with proper colors
        local palette_name = 'gfx/palette.lmp'
        print(string.format('load: %s', palette_name))
        local palette_info = filter(entries, function(o) return o.name == palette_name end)
        if #palette_info == 0 then
            error(string.format('Palette not found: %s', palette_name))
        end
        local palette_data = loadEntry(pak_path, palette_info[1])

        thread:start(channel, map_data, palette_data)
        thread:wait()

        local data = channel:pop()
        fn(data)
    end

    return setmetatable({
        mapNames    = mapNames,
        loadMap     = loadMap,
    }, Pak)
end

return setmetatable(Pak, {
    __call = function(_, ...) return Pak.new(...) end,
})
