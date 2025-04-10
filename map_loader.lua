local args = {...}

local lovr = { 
    math = require 'lovr.math',
    data = require 'lovr.data',
    thread = require 'lovr.thread',
    filesystem = require 'lovr.filesystem',
}

local ffi = require 'ffi'

if #args == 0 then
    error('Missing arguments: channel, map data blob & palette data blob.')
end

-- callback channel
local channel = args[1]
-- map data blob
local map_data = args[2]
-- palette blob
local palette_data = args[3]

-- keep track of read location
local base_ptr = ffi.cast('char*', map_data:getPointer())
local cursor = 0

-- Define C-style structures for reading binary data efficiently
ffi.cdef[[
    typedef struct { 
        int32_t offset;
        int32_t length; 
    } lump_t;

    typedef struct {
        int32_t version;
        lump_t lumps[15];
    } header_t;

    typedef struct {
        float x, y, z;
    } vec3_t;

    typedef struct {
        vec3_t min;
        vec3_t max;
    } boundbox_t;

    typedef struct { 
        vec3_t position;
        vec3_t tex_coord;
        vec3_t normal;
    } vertex_t;

    typedef struct {
        uint16_t vertex0;
        uint16_t vertex1;
    } edge_t;

    typedef struct {
        vec3_t normal;
        float distance;
        int32_t type;
    } plane_t;

    typedef struct {
        int16_t plane_id;

        int16_t side;
        int32_t ledge_id;
        int16_t ledge_num;

        int16_t texinfo_id;
        uint8_t typelight;
        uint8_t baselight;
        uint8_t lights[2];
        int32_t lightmap;
    } face_t;

    typedef struct {
        boundbox_t bound;
        vec3_t origin;
        uint32_t node_id0;
        uint32_t node_id1;
        uint32_t node_id2;
        uint32_t node_id3;
        uint32_t num_leafs;
        uint32_t face_id;
        uint32_t face_num;
    } model_t;

    typedef struct {
        char name[16];
        uint32_t width;
        uint32_t height;
        uint32_t offset1;
        uint32_t offset2;
        uint32_t offset4;
        uint32_t offset8;
    } miptex_t;

    typedef struct {
        vec3_t vectorS;
        float distS;
        vec3_t vectorT;
        float distT;
        uint32_t texture_id;
        uint32_t animated;         
    } surface_t;

    typedef struct {
        uint32_t plane_id;
        uint16_t front;
        uint16_t back;
    } node_t;

    typedef struct { 
        uint16_t vertex0;
        uint16_t vertex1;
    } edge_t;
]]

local function readBytes(size)
    if cursor + size > map_data:getSize() then
        error('Attempt to read beyond Blob size.')
    end
    local ptr = base_ptr + cursor  -- Get current read position
    cursor = cursor + size  -- Advance cursor
    return ffi.string(ptr, size)  -- Read and return data
end

local function readInt32()
    local data = readBytes(4)
    return ffi.cast('int32_t*', data)[0]
end

local function readHeader()
    cursor = 0
    local data = readBytes(ffi.sizeof('header_t'))
    if not data then return nil end

    local raw = ffi.cast('header_t*', data)[0]

    local header = {
        version = tonumber(raw.version),
        lumps = {},
    }

    for i = 0, 14 do
        table.insert(header.lumps, { 
            offset = tonumber(raw.lumps[i].offset),
            length = tonumber(raw.lumps[i].length),
        })
    end

    return header
end

local function readPalette()
    local palette_ptr = ffi.cast("char*", palette_data:getPointer())

    -- 256 * 3 (rgb)
    if palette_data:getSize() ~= 768 then
        error('Invalid palette file size. Expected 768 bytes, got ' .. #data)
    end

    -- 256-color palette
    local palette = ffi.new('uint8_t[256][3]')
    ffi.copy(palette, palette_ptr, palette_data:getSize())

    return palette
end

local function readTextures(lump)
    local palette = readPalette()

    cursor = lump.offset
    local count = readInt32()

    local offsets = {}
    for i = 1, count do
        table.insert(offsets, readInt32())
    end

    local textures = {}
    for i, offset in ipairs(offsets) do
        local miptex_offset = lump.offset + offset
        cursor = lump.offset + offset

        local data = readBytes(ffi.sizeof('miptex_t'))
        if not data then return nil end

        local tex_info = ffi.cast('miptex_t*', data)
        local tex_name = ffi.string(data)
        local tex_size = tex_info.width * tex_info.height
        local tex_offset = miptex_offset + tex_info.offset1

        cursor = tex_offset
        -- image data contains only indexed colors from a palette
        local img_data = readBytes(tex_size)
        local img_buffer = ffi.cast('uint8_t*', img_data)
        -- output image will convert color index to rgba
        local out_size = tex_size * 4
        local out_buffer = ffi.new('uint8_t[?]', out_size)

        -- replace indexed colors with colors from palette
        for j = 0, tex_size - 1 do
            local color_idx = img_buffer[j]
            out_buffer[j * 4 + 0] = palette[color_idx][0]
            out_buffer[j * 4 + 1] = palette[color_idx][1]
            out_buffer[j * 4 + 2] = palette[color_idx][2]
            out_buffer[j * 4 + 3] = 255
        end

        -- now generate an image
        local blob = lovr.data.newBlob(ffi.string(out_buffer, out_size), tex_name)
        local image = lovr.data.newImage(tex_info.width, tex_info.height, 'rgba8', blob)

        table.insert(textures, {
            image = image,
            name = tex_name,
            width = tex_info.width,
            height = tex_info.height,
        })
    end

    return textures
end

local function readVertices(lump)
    cursor = lump.offset
    local count = math.floor(lump.length / ffi.sizeof('vec3_t'))

    -- Read entire lump at once
    local data = readBytes(lump.length)
    if not data then return {} end

    -- Cast the entire buffer into an array of the structure type
    local array = ffi.cast('vec3_t*', data)

    -- Convert to Lua table
    local vertices = {}
    for i = 1, count do
        local v = array[i - 1]
        table.insert(vertices, lovr.math.newVec3(v.x, v.y, v.z))
    end
    
    array = nil

    return vertices
end

local function readSurfaces(lump)
    cursor = lump.offset
    local count = math.floor(lump.length / ffi.sizeof('surface_t'))

    -- Read entire lump at once
    local data = readBytes(lump.length)
    if not data then return {} end

    -- Cast the entire buffer into an array of the structure type
    local array = ffi.cast('surface_t*', data)

    -- Convert to Lua table
    local surfaces = {}
    for i = 1, count do
        local v = array[i - 1] -- Adjust 0-based index
        table.insert(surfaces, {
            vector_s = lovr.math.newVec3(v.vectorS.x, v.vectorS.y, v.vectorS.z),
            dist_s = tonumber(v.distS),
            vector_t = lovr.math.newVec3(v.vectorT.x, v.vectorT.y, v.vectorT.z),
            dist_t = tonumber(v.distT),
            texture_id = tonumber(v.texture_id + 1),
            animated = tonumber(v.animated),
        })
    end

    array = nil

    return surfaces
end

local function readPlanes(lump)
    cursor = lump.offset
    local count = math.floor(lump.length / ffi.sizeof('plane_t'))

    -- Read entire lump at once
    local data = readBytes(lump.length)
    if not data then return {} end

    -- Cast the entire buffer into an array of the structure type
    local array = ffi.cast('plane_t*', data)

    -- Convert to Lua table
    local planes = {}
    for i = 1, count do
        local v = array[i - 1] -- Adjust 0-based index
        table.insert(planes, {
            normal = lovr.math.newVec3(v.normal.x, v.normal.y, v.normal.z),
            distance = tonumber(v.distance),
            type = tonumber(type),
        })
    end

    array = nil

    return planes
end

local function readFaces(lump)
    cursor = lump.offset
    local count = math.floor(lump.length / ffi.sizeof('face_t'))

    -- Read entire lump at once
    local data = readBytes(lump.length)
    if not data then return {} end

    -- Cast the entire buffer into an array of the structure type
    local array = ffi.cast('face_t*', data)      

    -- Convert to Lua table
    local faces = {}
    for i = 1, count do
        local v = array[i - 1] -- Adjust 0-based index
        table.insert(faces, {
            plane_id = tonumber(v.plane_id + 1),
            side = tonumber(v.side),
            edge_id = tonumber(v.ledge_id + 1),
            num_edges = tonumber(v.ledge_num),
            surface_id = tonumber(v.texinfo_id + 1),
            type_light = tonumber(v.typelight),
            base_light = tonumber(v.baselight),
            light_map = tonumber(v.lightmap),
            lights = {},
        })

        for j = 0, 1 do
            table.insert(faces[i].lights, tonumber(v.lights[j]))
        end
    end

    array = nil

    return faces
end

local function readEdges(lump)
    cursor = lump.offset
    local count = math.floor(lump.length / ffi.sizeof('edge_t'))

    -- Read entire lump at once
    local data = readBytes(lump.length)
    if not data then return {} end

    -- Cast the entire buffer into an array of the structure type
    local array = ffi.cast('edge_t*', data)

    -- Convert to Lua table
    local edges = {}
    for i = 1, count do
        local v = array[i] -- Adjust 0-based index
        table.insert(edges, {
            vertex1 = tonumber(v.vertex0 + 1),
            vertex2 = tonumber(v.vertex1 + 1),
        })
    end

    array = nil

    return edges
end

local function readEdgeList(lump)
    cursor = lump.offset
    local count = math.floor(lump.length / ffi.sizeof('int32_t'))

    -- Read entire lump at once
    local data = readBytes(lump.length)
    if not data then return {} end

    -- Cast the entire buffer into an array of the structure type
    local array = ffi.cast('int32_t*', data)

    -- Convert to Lua table
    local edge_list = {}
    for i = 1, count do
        local v = array[i - 1] -- Adjust 0-based index
        table.insert(edge_list, tonumber(v))
    end

    array = nil

    return edge_list
end

local function readEntities(lump)
    cursor = lump.offset

    local data = ffi.string(readBytes(lump.length))

    -- Parse entities from raw text
    local entities = {}

    for entity in data:gmatch('{(.-)}') do
        local parsed_entity = {}
        for key, value in entity:gmatch('"(.-)"%s+"(.-)"') do
            parsed_entity[key] = value
        end
        table.insert(entities, parsed_entity)
    end

    return entities
end

local function readGeometry(bsp, faces, edges, edge_list)
    local results = {}

    for _, face in ipairs(faces) do
        local num_edges = face.num_edges

        local surface = bsp.surfaces[face.surface_id]
        local texture = bsp.textures[surface.texture_id]

        if (string.find(texture.name, 'clip') or 
            string.find(texture.name, 'trigger')) then
            goto continue
        end

        local vertices = {}

        for edge = 0, num_edges - 1 do
            local edge_id = edge_list[edge + face.edge_id]
            local vertex_id = 0

            if edge_id < 0 then
                vertex_id = edges[math.abs(edge_id)].vertex2
            else
                vertex_id = edges[edge_id].vertex1
            end

            local vertex = bsp.vertices[vertex_id]

            local normal = bsp.planes[face.plane_id].normal

            local position = lovr.math.newVec3(vertex.x, vertex.z, -vertex.y)

            local u = (vertex:dot(surface.vector_s) + surface.dist_s) / texture.width
            local v = (vertex:dot(surface.vector_t) + surface.dist_t) / texture.height
            local uv = lovr.math.newVec2(u, v)

            table.insert(vertices, {
                normal      = normal,
                position    = position,
                uv          = uv,
            })
        end

        table.insert(results, {
            texture_id = surface.texture_id,
            vertices = vertices,
        })

        ::continue::
    end

    return results
end

local bsp = {
    entities    = {},
    textures    = {},
    vertices    = {},
    planes      = {},
    surfaces    = {},
    geometry    = {},
}

local header = readHeader()
print(string.format('\nversion: %d\n', header.version))

bsp.entities = readEntities(header.lumps[1])
bsp.textures = readTextures(header.lumps[3])
bsp.vertices = readVertices(header.lumps[4])
bsp.planes = readPlanes(header.lumps[2])
bsp.surfaces = readSurfaces(header.lumps[7])

local faces = readFaces(header.lumps[8])
local edges = readEdges(header.lumps[13])
local edge_list = readEdgeList(header.lumps[14])

bsp.geometry = readGeometry(bsp, faces, edges, edge_list)

channel:push(bsp)
