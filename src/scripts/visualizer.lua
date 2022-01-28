local area = require("__flib__.area")
local direction = require("__flib__.direction")

local vivid = require("lib.vivid")

local constants = require("constants")

local visualizer = {}

--- @param player LuaPlayer
--- @param player_table PlayerTable
function visualizer.create(player, player_table)
  player_table.enabled = true
  -- TODO: Failsafe to make sure that nothing is there?
  player_table.rectangle = rendering.draw_rectangle({
    left_top = { x = 0, y = 0 },
    right_bottom = { x = 0, y = 0 },
    filled = true,
    color = { a = 0.6 },
    surface = player.surface,
    players = { player.index },
  })
  player_table.pipe_connectable_lut = {}
  player_table.network_id_to_network_mapping = {}

  visualizer.update(player, player_table)
end

--- @param player LuaPlayer
--- @param player_table PlayerTable
function visualizer.update(player, player_table)
  local player_surface = player.surface
  local player_position = {
    x = math.floor(player.position.x),
    y = math.floor(player.position.y),
  }

  local overlay_area = area.from_dimensions(
    { height = constants.max_viewable_radius * 2, width = constants.max_viewable_radius * 2 },
    player_position
  )

  -- Update overlay
  rendering.set_left_top(player_table.rectangle, overlay_area.left_top)
  rendering.set_right_bottom(player_table.rectangle, overlay_area.right_bottom)

  local areas = {}
  if player_table.last_position then
    local last_position = player_table.last_position
    --- @type Position
    local delta = {
      x = player_position.x - last_position.x,
      y = player_position.y - last_position.y,
    }

    if delta.x < 0 then
      table.insert(areas, {
        left_top = {
          x = player_position.x - constants.max_viewable_radius,
          y = player_position.y - constants.max_viewable_radius,
        },
        right_bottom = {
          x = last_position.x - constants.max_viewable_radius,
          y = player_position.y + constants.max_viewable_radius,
        },
      })
    elseif delta.x > 0 then
      table.insert(areas, {
        left_top = {
          x = last_position.x + constants.max_viewable_radius,
          y = player_position.y - constants.max_viewable_radius,
        },
        right_bottom = {
          x = player_position.x + constants.max_viewable_radius,
          y = player_position.y + constants.max_viewable_radius,
        },
      })
    end

    if delta.y < 0 then
      table.insert(areas, {
        left_top = {
          x = player_position.x - constants.max_viewable_radius,
          y = player_position.y - constants.max_viewable_radius,
        },
        right_bottom = {
          x = player_position.x + constants.max_viewable_radius,
          y = last_position.y - constants.max_viewable_radius,
        },
      })
    elseif delta.y > 0 then
      table.insert(areas, {
        left_top = {
          x = player_position.x - constants.max_viewable_radius,
          y = last_position.y + constants.max_viewable_radius,
        },
        right_bottom = {
          x = player_position.x + constants.max_viewable_radius,
          y = player_position.y + constants.max_viewable_radius,
        },
      })
    end
  else
    table.insert(areas, overlay_area)
  end

  player_table.last_position = player_position

  local get_color
  do
    local fluid_prototypes = game.fluid_prototypes
    local color_cache = {}
    local empty_color = { r = 0.3, g = 0.3, b = 0.3 }
    --- @param fluid Fluid
    function get_color(fluid)
      if not fluid then
        return empty_color
      end
      local name = fluid.name
      if color_cache[name] then
        return color_cache[name]
      end
      local base_color = fluid_prototypes[name].base_color
      local h, s, v, a = vivid.RGBtoHSV(base_color)
      v = math.max(v, 0.8)
      local r, g, b, a = vivid.HSVtoRGB(h, s, v, a)
      local color = { r = r, g = g, b = b, a = a }
      color_cache[name] = color
      return color
    end
  end

  local new_connectables = {}
  local pipe_connectable_lut = player_table.pipe_connectable_lut
  for _, tile_area in pairs(areas) do
    local entities = player.surface.find_entities_filtered({ type = constants.search_types, area = tile_area })
    for _, entity in pairs(entities) do
      local unit_number = entity.unit_number
      if pipe_connectable_lut[unit_number] then
        goto continue
      end

      --- @class PipeConnectable
      --- @field unit_number uint
      --- @field position Position
      --- @field entity LuaEntity
      --- @field network_ids uint[]
      --- @field neighbor_unit_number_to_fluid_box_index_lut table<uint, PipeConnectable>
      --- @field visited boolean?
      --- @field fluidbox_count uint
      --- @field fluids Fluid[] @ empty fluid boxes are holes in the array
      --- @field fluidbox LuaFluidBox
      --- @field rendering_ids uint[]

      local fluidbox = entity.fluidbox
      local fluidbox_count = #fluidbox
      if fluidbox_count == 0 then
        goto continue
      end
      local fluids = {}
      for i = 1, fluidbox_count do
        fluids[i] = fluidbox[i]
      end

      local pipe_connectable = {
        unit_number = unit_number,
        position = entity.position,
        entity = entity,
        network_ids = {},
        neighbor_unit_number_to_fluid_box_index_lut = {},
        fluidbox_count = fluidbox_count,
        fluids = fluids,
        fluidbox = fluidbox,
        rendering_ids = {},
      }

      new_connectables[#new_connectables+1] = pipe_connectable
      pipe_connectable_lut[unit_number] = pipe_connectable
      ::continue::
    end
  end

  local network_id_redirect_mapping = player_table.network_id_to_network_mapping

  local function get_network_id(id)
    local result
    repeat
      result = id
      id = network_id_redirect_mapping[id]
    until not id
    return result
  end

  local next_network_id = 0
  for _, pipe_connectable in pairs(new_connectables) do
    pipe_connectable.visited = true
    local unit_number = pipe_connectable.unit_number
    for i, fluidbox_neighbours in pairs(pipe_connectable.entity.neighbours) do
      local current_id
      for _, neighbour in pairs(fluidbox_neighbours) do
        local other_unit_number = neighbour.unit_number
        pipe_connectable.neighbor_unit_number_to_fluid_box_index_lut[other_unit_number] = i
        local other = pipe_connectable_lut[other_unit_number]
        if other and other.visited then
          local other_fluid_box_index = other.neighbor_unit_number_to_fluid_box_index_lut[unit_number]
          assert(other_fluid_box_index)
          local other_network_id = other.network_ids[other_fluid_box_index]
          if other_network_id then
            other_network_id = get_network_id(other_network_id)
            if current_id then
              if other_network_id ~= current_id then
                network_id_redirect_mapping[current_id] = other_network_id
              end
            else
              current_id = other_network_id
              pipe_connectable.network_ids[i] = current_id
            end
          else
            current_id = next_network_id
            next_network_id = next_network_id + 1
            pipe_connectable.network_ids[i] = current_id
            other.network_ids[other_fluid_box_index] = current_id
          end
        end
      end
    end
    ::continue::
  end

  local networks = {}

  for _, pipe_connectable in pairs(pipe_connectable_lut) do
    for i = 1, pipe_connectable.fluidbox_count do
      if pipe_connectable.network_ids[i] then
        local id = get_network_id(pipe_connectable.network_ids[i])
        if not networks[id] then
          networks[id] = {id = id}
        end
        pipe_connectable.network_ids[i] = id
      end
    end
  end

  for _, pipe_connectable in pairs(pipe_connectable_lut) do
    for i = 1, pipe_connectable.fluidbox_count do
      local id = pipe_connectable.network_ids[i]
      if id then
        if pipe_connectable.fluids[i] then
          networks[id].color = get_color(pipe_connectable.fluids[i])
        else
          local filter = pipe_connectable.fluidbox.get_filter(i)
          if filter then
            networks[id].color = get_color(filter)
          end
        end
      end
    end
  end

  for _, pipe_connectable in pairs(pipe_connectable_lut) do
    pipe_connectable.network_rendering_ids = pipe_connectable.network_rendering_ids or {}
    for i = 1, #pipe_connectable.entity.fluidbox do
      if pipe_connectable.network_rendering_ids[i] then
        rendering.destroy(pipe_connectable.network_rendering_ids[i])
      end
      if pipe_connectable.network_ids[i] then
        pipe_connectable.network_rendering_ids[i] = rendering.draw_text({
          text = tostring(pipe_connectable.network_ids[i]),
          color = {1, 1, 1, 1},
          target = pipe_connectable.entity,
          target_offset = {x = 0, y = (i - 1) / 0.5},
          surface = player_surface,
          players = { player.index },
          scale = 2,
        })
      end
    end
  end

  for _, pipe_connectable in pairs(new_connectables) do
    for i = 1, #pipe_connectable.entity.fluidbox do
      local id = pipe_connectable.network_ids[i]
      if id then
        for _, rendering_id in pairs(pipe_connectable.rendering_ids) do
          rendering.destroy(rendering_id)
        end
        local color = networks[id].color or get_color()
        local entity = pipe_connectable.entity
        for _, fluidbox_neighbours in pairs(entity.neighbours) do
          for _, neighbour in pairs(fluidbox_neighbours) do
            local neighbour_position = neighbour.position
            local is_pipe_entity = constants.search_types_lookup[neighbour.type]
            local is_underground_connection = entity.type == "pipe-to-ground"
              and neighbour.type == "pipe-to-ground"
              and entity.direction == direction.opposite(neighbour.direction)
              and entity.direction
                == direction.opposite(direction.from_positions(entity.position, neighbour.position, true))
            local is_southeast = neighbour_position.x > (entity.position.x + 0.99)
              or neighbour_position.y > (entity.position.y + 0.99)

            if
              is_underground_connection
              and not area.contains_position(overlay_area, neighbour_position)
              and not is_southeast
            then
              -- table.insert(entities, neighbour)
            elseif is_southeast or not is_pipe_entity then
              local offset = { 0, 0 }
              if is_underground_connection then
                if entity.direction == defines.direction.north or entity.direction == defines.direction.south then
                  offset = { 0, -0.25 }
                else
                  offset = { -0.25, 0 }
                end
              end
              table.insert(
                pipe_connectable.rendering_ids,
                rendering.draw_line({
                  color = color,
                  width = 5,
                  gap_length = is_underground_connection and 0.5 or 0,
                  dash_length = is_underground_connection and 0.5 or 0,
                  from = entity,
                  from_offset = offset,
                  to = neighbour,
                  surface = neighbour.surface,
                  players = { player.index },
                })
              )
            end
            if not is_pipe_entity then
              table.insert(
                pipe_connectable.rendering_ids,
                rendering.draw_rectangle({
                  left_top = neighbour,
                  left_top_offset = { -0.2, -0.2 },
                  right_bottom = neighbour,
                  right_bottom_offset = { 0.2, 0.2 },
                  color = color,
                  filled = true,
                  target = neighbour,
                  surface = player_surface,
                  players = { player.index },
                })
              )
            end
          end
        end

        table.insert(
          pipe_connectable.rendering_ids,
          rendering.draw_circle({
            color = color,
            radius = 0.2,
            filled = true,
            target = entity,
            surface = player_surface,
            players = { player.index },
          })
        )
      end
    end
  end

  -- game.print(next_network_id)
end

--- @param player_table PlayerTable
function visualizer.destroy(player_table)
  player_table.enabled = false
  rendering.destroy(player_table.rectangle)
  for _, pipe_connectable in pairs(player_table.pipe_connectable_lut) do
    for _, id in pairs(pipe_connectable.rendering_ids) do
      rendering.destroy(id)
    end
  end
  player_table.entity_objects = {}
  player_table.last_position = nil
  player_table.pipe_connectable_lut = nil
  player_table.network_id_to_network_mapping = nil
end

return visualizer
