lovr.mouse = require 'lovr-mouse'

local Pak = require 'pak'

local meshes = {}
local textures = {}

local camera = {
    transform = lovr.math.newMat4(),
    position = lovr.math.newVec3(),
    movespeed = 200,
    pitch = 0,
    yaw = 0,
}    

function lovr.load()
    local pak = Pak('pak0.pak')

    -- TODO: add error handling
    pak:loadMap(function(bsp)
        print('generate textures')

        for _, tex_info in ipairs(bsp.textures) do
            table.insert(textures, lovr.graphics.newTexture(tex_info.image, {
                type = '2d',
                usage = { 'sample' },
                label = tex_info.name,
            }))
        end

        print('generate meshes') 

        for _, geometry in ipairs(bsp.geometry) do
            local vertices = {}            

            -- emulate GL_TRIANGLE_FAN
            for i = 2, #geometry.vertices - 1 do
                vertex1 = geometry.vertices[1]
                vertex2 = geometry.vertices[i]
                vertex3 = geometry.vertices[i + 1]

                for _, vertex in ipairs({vertex1, vertex2, vertex3}) do
                    local px, py, pz = vertex.position:unpack()
                    local nx, ny, nz = vertex.normal:unpack()
                    local ux, uy = vertex.uv:unpack()
                    table.insert(vertices, {
                        px, py, pz, nx, ny, nz, ux, uy
                    })
                end
            end
                
            local vertex1 = geometry.vertices[1]
            local vertex2 = geometry.vertices[#geometry.vertices]
            local vertex3 = geometry.vertices[2]

            for _, vertex in ipairs({vertex1, vertex2, vertex3}) do
                local px, py, pz = vertex.position:unpack()
                local nx, ny, nz = vertex.normal:unpack()
                local ux, uy = vertex.uv:unpack()
                table.insert(vertices, {
                    px, py, pz, nx, ny, nz, ux, uy
                })
            end

            local texture = textures[geometry.texture_id]
            local mesh = lovr.graphics.newMesh(vertices)
            mesh:setMaterial(texture)

            table.insert(meshes, mesh)
        end

        for _, entity in ipairs(bsp.entities) do
            if entity.classname == 'info_player_start' then
                local x, y, z = entity.origin:match("(%-?%d+) (%-?%d+) (%-?%d+)")
                local angle = tonumber(entity.angle)

                -- TODO: set camera origin
            end
        end
    end)

    lovr.mouse.setRelativeMode(true)
end

function lovr.update(dt)
    local velocity = vec4()

    if lovr.system.isKeyDown('w', 'up') then
        velocity.z = -1
    elseif lovr.system.isKeyDown('s', 'down') then
        velocity.z = 1
    end

    if lovr.system.isKeyDown('a', 'left') then
        velocity.x = -1
    elseif lovr.system.isKeyDown('d', 'right') then
        velocity.x = 1
    end

    if #velocity > 0 then
        velocity:normalize()
        velocity:mul(camera.movespeed * dt)
        camera.position:add(camera.transform:mul(velocity).xyz)
    end

    camera.transform:identity()
    camera.transform:translate(0, 1.7, 0)
    camera.transform:translate(camera.position)
    camera.transform:rotate(camera.yaw, 0, 1, 0)
    camera.transform:rotate(camera.pitch, 1, 0, 0)
end

function lovr.draw(pass)
    pass:push()
    pass:setViewPose(1, camera.transform)
    pass:setColor(0xffffff)
    for i, mesh in ipairs(meshes) do
        pass:draw(mesh)
    end
    pass:pop()    
end

function lovr.mousemoved(x, y, dx, dy)
    camera.pitch = camera.pitch - dy * .004
    camera.yaw = camera.yaw - dx * .004
end


function lovr.keypressed(key)
    if key == 'escape' then
        lovr.event.quit()
    end
end
