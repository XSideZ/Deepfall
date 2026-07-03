extends Node3D
class_name VoxelWorld
## Owns the voxel data and spawns the chunks that render it. The world is a bounded
## WORLD_SIZE^3 grid split into CHUNK_SIZE^3 chunks (so editing one voxel only re-meshes
## the affected chunk). DeepFall is underground: the volume is solid rock up to a thin
## surface crust near the top, and the player starts inside a carved-out cavern. You dig
## down/sideways through stone, and digging up eventually reaches the (dead) surface.

const WORLD_SIZE := 96
const CHUNK_SIZE := 16
const CHUNKS_PER_AXIS := WORLD_SIZE / CHUNK_SIZE  # 6

# Solid rock fills y < SURFACE_Y. The block at SURFACE_Y is the dead surface crust; air above.
const SURFACE_Y := 84

# Starting cavern: a carved air room the player spawns inside, well below the surface.
const SPAWN_CX := 48        # search centre for the player's spawn cave
const SPAWN_CZ := 48

# Carver-cave tunnels (Minecraft-style worms): each is an independent winding tube.
const CAVE_SEED := 1337
const TUNNEL_COUNT := 26         # number of independent worm tunnels (= discrete cave systems)
const TUNNEL_MIN_LEN := 90
const TUNNEL_MAX_LEN := 240
const TUNNEL_MIN_RADIUS := 2.0
const TUNNEL_MAX_RADIUS := 3.6
const BEDROCK_Y := 2             # solid floor kept at the very bottom

const ChunkScene := preload("res://scripts/Chunk.gd")

var _voxels := PackedByteArray()
var _chunks := {}  # Vector3i -> Chunk
var spawn_position := Vector3.ZERO  # found by _choose_spawn(), read by the Player


func _ready() -> void:
	add_to_group("voxel_world")
	_voxels.resize(WORLD_SIZE * WORLD_SIZE * WORLD_SIZE)
	generate_world()
	_choose_spawn()
	_spawn_chunks()


# --- Voxel data API -------------------------------------------------------

func _index(x: int, y: int, z: int) -> int:
	return x + y * WORLD_SIZE + z * WORLD_SIZE * WORLD_SIZE


func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and y >= 0 and z >= 0 \
		and x < WORLD_SIZE and y < WORLD_SIZE and z < WORLD_SIZE


func get_voxel(x: int, y: int, z: int) -> int:
	if not in_bounds(x, y, z):
		return Blocks.AIR
	return _voxels[_index(x, y, z)]


func is_solid(x: int, y: int, z: int) -> bool:
	return get_voxel(x, y, z) != Blocks.AIR


func set_voxel(x: int, y: int, z: int, id: int) -> void:
	if not in_bounds(x, y, z):
		return
	_voxels[_index(x, y, z)] = id
	_rebuild_around(x, y, z)


# --- World generation -----------------------------------------------------

## Solid underground: stone below the surface, a dirt band + grass crust at the top, air
## above. Then a starting cavern is carved out. Deliberately one swappable function so
## 3D-noise caves/biomes can replace it later without touching meshing, collision or the
## player.
func generate_world() -> void:
	# Solid rock below a thin dirt + grass surface crust; air above.
	for z in WORLD_SIZE:
		for y in WORLD_SIZE:
			for x in WORLD_SIZE:
				var id: int = Blocks.AIR
				if y == SURFACE_Y:
					id = Blocks.GRASS                 # the dead surface crust
				elif y >= SURFACE_Y - 3 and y < SURFACE_Y:
					id = Blocks.DIRT                  # soil just under the crust
				elif y < SURFACE_Y:
					id = Blocks.STONE
				_voxels[_index(x, y, z)] = id
	_carve_tunnels()
	_remove_floaters()


## Minecraft-style "carver" caves: each worm starts somewhere in the rock and tunnels a
## winding tube through it, carving a sphere each step. Kept mostly-horizontal so tunnels
## are walkable, and independent so we get DISCRETE cave systems instead of one big sponge.
func _carve_tunnels() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = CAVE_SEED
	for w in TUNNEL_COUNT:
		var pos: Vector3
		if w == 0:
			# Guarantee a tunnel through the spawn search centre so the player starts in one.
			pos = Vector3(SPAWN_CX, float(SURFACE_Y) * 0.65, SPAWN_CZ)
		else:
			pos = Vector3(
				rng.randf_range(8.0, WORLD_SIZE - 8.0),
				rng.randf_range(BEDROCK_Y + 6.0, SURFACE_Y - 8.0),
				rng.randf_range(8.0, WORLD_SIZE - 8.0))
		var yaw := rng.randf_range(0.0, TAU)
		var pitch := rng.randf_range(-0.2, 0.2)
		var length := rng.randi_range(TUNNEL_MIN_LEN, TUNNEL_MAX_LEN)
		var radius := rng.randf_range(TUNNEL_MIN_RADIUS, TUNNEL_MAX_RADIUS)
		for i in length:
			var dir := Vector3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch))
			pos += dir
			yaw += rng.randf_range(-0.35, 0.35)
			pitch = clampf(pitch + rng.randf_range(-0.1, 0.1), -0.35, 0.35)
			radius = clampf(radius + rng.randf_range(-0.2, 0.2), TUNNEL_MIN_RADIUS, TUNNEL_MAX_RADIUS)
			_carve_sphere(pos, radius)
			if pos.x < 4.0 or pos.x > WORLD_SIZE - 4.0 or pos.z < 4.0 or pos.z > WORLD_SIZE - 4.0 \
					or pos.y < BEDROCK_Y + 2.0 or pos.y > SURFACE_Y - 4.0:
				break


func _carve_sphere(center: Vector3, radius: float) -> void:
	var r := int(ceil(radius))
	var cx := int(round(center.x))
	var cy := int(round(center.y))
	var cz := int(round(center.z))
	var r2 := radius * radius
	for dz in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if float(dx * dx + dy * dy + dz * dz) > r2:
					continue
				var x := cx + dx
				var y := cy + dy
				var z := cz + dz
				if in_bounds(x, y, z) and y > BEDROCK_Y and y < SURFACE_Y:
					_voxels[_index(x, y, z)] = Blocks.AIR


## Clean up fully-isolated single blocks (all six neighbours air) so caves don't have
## ugly floating cubes hanging in them.
func _remove_floaters() -> void:
	var to_clear: Array[int] = []
	for z in range(1, WORLD_SIZE - 1):
		for y in range(1, WORLD_SIZE - 1):
			for x in range(1, WORLD_SIZE - 1):
				if not is_solid(x, y, z):
					continue
				if not is_solid(x + 1, y, z) and not is_solid(x - 1, y, z) \
						and not is_solid(x, y + 1, z) and not is_solid(x, y - 1, z) \
						and not is_solid(x, y, z + 1) and not is_solid(x, y, z - 1):
					to_clear.append(_index(x, y, z))
	for i in to_clear:
		_voxels[i] = Blocks.AIR


## Find a real cave floor with headroom near the search centre (spiralling outward so
## the spawn stays near the middle), give it a little standing clearance, and record it
## as the player's spawn. So the player starts *inside* the cave network, not in a box.
func _choose_spawn() -> void:
	for r in range(0, 30):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue  # only the new perimeter ring at this radius
				var x := SPAWN_CX + dx
				var z := SPAWN_CZ + dz
				if not in_bounds(x, 0, z):
					continue
				for y in range(SURFACE_Y - 8, BEDROCK_Y, -1):
					if is_solid(x, y, z) and not is_solid(x, y + 1, z) \
							and not is_solid(x, y + 2, z) and not is_solid(x, y + 3, z):
						_make_spawn_clearance(x, y, z)
						spawn_position = Vector3(x + 0.5, float(y) + 1.1, z + 0.5)
						return
	spawn_position = Vector3(SPAWN_CX + 0.5, SURFACE_Y + 2.0, SPAWN_CZ + 0.5)


## Guarantee a small standable pocket at the spawn (solid 3x3 floor + air above) that
## opens into the surrounding cave.
func _make_spawn_clearance(fx: int, fy: int, fz: int) -> void:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x := fx + dx
			var z := fz + dz
			if in_bounds(x, fy, z):
				_voxels[_index(x, fy, z)] = Blocks.STONE
			for dy in range(1, 5):
				if in_bounds(x, fy + dy, z):
					_voxels[_index(x, fy + dy, z)] = Blocks.AIR


# --- Chunks ---------------------------------------------------------------

func _spawn_chunks() -> void:
	for cz in CHUNKS_PER_AXIS:
		for cy in CHUNKS_PER_AXIS:
			for cx in CHUNKS_PER_AXIS:
				var coord := Vector3i(cx, cy, cz)
				var chunk := ChunkScene.new()
				chunk.setup(self, coord)
				add_child(chunk)
				_chunks[coord] = chunk
				chunk.build_mesh()


func _chunk_coord(x: int, y: int, z: int) -> Vector3i:
	return Vector3i(x / CHUNK_SIZE, y / CHUNK_SIZE, z / CHUNK_SIZE)


## Rebuild the chunk owning (x,y,z) plus any face-neighbour chunk, so that a voxel
## edited on a chunk border updates the seam on both sides.
func _rebuild_around(x: int, y: int, z: int) -> void:
	var coords := {}
	var offsets: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
			Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	for o in offsets:
		var nx: int = x + o.x
		var ny: int = y + o.y
		var nz: int = z + o.z
		if in_bounds(nx, ny, nz):
			coords[_chunk_coord(nx, ny, nz)] = true
	for c in coords:
		if _chunks.has(c):
			_chunks[c].build_mesh()
