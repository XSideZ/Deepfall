extends Node3D
## The tree's interior, v3: rooms are CARVED out of one solid organic mass with CSG,
## so pods and corridors merge into each other seamlessly (no intersecting shells).
## Expansion happens at the single GROWTH TERMINAL in the entry pod: pick a room,
## a direction (left / straight / right — back is where you came from), and a type:
##   SMALL pod, GRAND pod, or STAIRWELL (climbs +6 m; rooms grown from it connect up top).
## Future room purposes (refiner / crafter / storage) extend `ROOM_DEFS`.

const ROOM_SMALL := 0
const ROOM_LARGE := 1
const ROOM_STAIR := 2
const ROOM_STORAGE := 3
const ROOM_REFINER := 4

const ROOM_DEFS := {
	ROOM_SMALL: { "name": "Small pod", "radius": 4.2 },
	ROOM_LARGE: { "name": "Grand pod", "radius": 6.5 },
	ROOM_STAIR: { "name": "Stairwell", "radius": 3.4 },
	ROOM_STORAGE: { "name": "Storage sac", "radius": 4.4 },
	ROOM_REFINER: { "name": "Refinery gland", "radius": 4.6 },
}
const CORRIDOR_R := 1.5
const CORRIDOR_LEN := 3.0
const STAIR_RISE := 6.0

# rooms[i] = { type, center: Vector3 (floor level), fwd: Vector3, used: [bool,bool,bool], parent: int }
var rooms: Array = []
var corridors: Array = []      # { from: Vector3, to: Vector3 } floor-level endpoints
var build_log: Array = []      # [ {p, d, t}, ... ] replayed by save/load

var combiner: CSGCombiner3D
var decor_root: Node3D
var socket_root: Node3D
var sockets: Array = []        # { room: int, dir: int, pos: Vector3 (local) }
var refiners: Array = []       # local positions of refinery cores
var terminal: Node3D
var portal_marker: Node3D
var _shell_normal: NoiseTexture2D
var wall_mat: StandardMaterial3D
var floor_mat: StandardMaterial3D

func _ready() -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.012
	_shell_normal = NoiseTexture2D.new()
	_shell_normal.width = 256
	_shell_normal.height = 256
	_shell_normal.seamless = true
	_shell_normal.as_normal_map = true
	_shell_normal.bump_strength = 6.0
	_shell_normal.noise = noise

	wall_mat = StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.19, 0.12, 0.26)
	wall_mat.roughness = 0.95
	wall_mat.normal_enabled = true
	wall_mat.normal_texture = _shell_normal
	wall_mat.normal_scale = 1.6
	wall_mat.uv1_scale = Vector3(0.35, 0.35, 0.35)
	wall_mat.uv1_triplanar = true
	floor_mat = StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.24, 0.40, 0.22)
	floor_mat.roughness = 1.0
	floor_mat.normal_enabled = true
	floor_mat.normal_texture = _shell_normal
	floor_mat.uv1_scale = Vector3(0.5, 0.5, 0.5)
	floor_mat.uv1_triplanar = true

	combiner = CSGCombiner3D.new()
	combiner.use_collision = true
	add_child(combiner)
	decor_root = Node3D.new()
	add_child(decor_root)
	socket_root = Node3D.new()
	add_child(socket_root)

	# entry pod
	rooms.append({ "type": ROOM_SMALL, "center": Vector3.ZERO, "fwd": Vector3(0, 0, 1), "used": [false, false, false], "parent": -1 })
	var r0: float = ROOM_DEFS[ROOM_SMALL].radius
	corridors.append({ "from": Vector3(0, 0, -r0 - CORRIDOR_LEN), "to": Vector3.ZERO })
	portal_marker = Node3D.new()
	# centred in the entry tunnel so the portal disc fills the whole opening
	portal_marker.position = Vector3(0, 1.5, -r0 - 1.6)
	portal_marker.rotation.y = PI   # -Z of the marker faces INTO the home
	add_child(portal_marker)
	_rebuild()

# --- public API ----------------------------------------------------------------

func spawn_global() -> Vector3:
	return to_global(Vector3(0, 0.4, -1.5))

func terminal_global() -> Vector3:
	return terminal.global_position if terminal else Vector3.INF

func room_count() -> int:
	return rooms.size()

func storage_count() -> int:
	var n := 0
	for room in rooms:
		if room.type == ROOM_STORAGE:
			n += 1
	return n

func refiner_globals() -> Array:
	var out: Array = []
	for p in refiners:
		out.append(to_global(p))
	return out

func room_name(i: int) -> String:
	return "%s %d" % [ROOM_DEFS[rooms[i].type].name, i + 1]

## Direction vectors for a room: 0 = left, 1 = straight, 2 = right (relative to fwd).
func dir_vector(room_idx: int, dir_idx: int) -> Vector3:
	var fwd: Vector3 = rooms[room_idx].fwd
	match dir_idx:
		0: return fwd.rotated(Vector3.UP, PI * 0.5)
		2: return fwd.rotated(Vector3.UP, -PI * 0.5)
	return fwd

func can_expand(room_idx: int, dir_idx: int, type: int) -> bool:
	if room_idx < 0 or room_idx >= rooms.size():
		return false
	if rooms[room_idx].used[dir_idx]:
		return false
	var c := _new_center(room_idx, dir_idx, type)
	for i in rooms.size():
		var other = rooms[i]
		var min_gap: float = ROOM_DEFS[type].radius + ROOM_DEFS[other.type].radius + 1.2
		var dxz := Vector2(c.x - other.center.x, c.z - other.center.z).length()
		if dxz < min_gap and absf(c.y - other.center.y) < 4.5:
			return false
	return true

## Grow a new room. Returns false if the spot is blocked or the exit is used.
func expand(room_idx: int, dir_idx: int, type: int) -> bool:
	if not can_expand(room_idx, dir_idx, type):
		return false
	var parent = rooms[room_idx]
	var dir := dir_vector(room_idx, dir_idx)
	var center := _new_center(room_idx, dir_idx, type)
	parent.used[dir_idx] = true
	rooms.append({ "type": type, "center": center, "fwd": dir, "used": [false, false, false], "parent": room_idx })
	# corridor runs between the two floor levels (sloped when leaving a stairwell top)
	var from: Vector3 = parent.center + dir * ROOM_DEFS[parent.type].radius * 0.7
	if parent.type == ROOM_STAIR:
		from.y = parent.center.y + STAIR_RISE
	var to: Vector3 = center + (-dir) * ROOM_DEFS[type].radius * 0.7
	to.y = center.y
	corridors.append({ "from": from, "to": to })
	build_log.append({ "p": room_idx, "d": dir_idx, "t": type })
	_rebuild()
	return true

func replay(log: Array) -> void:
	for e in log:
		expand(int(e.p), int(e.d), int(e.t))

# --- seed sockets: glowing wall bulbs marking every spot a seed can be planted ------

func show_sockets(type: int) -> void:
	hide_sockets()
	for i in rooms.size():
		var room = rooms[i]
		var r: float = ROOM_DEFS[room.type].radius
		for d in 3:
			if not can_expand(i, d, type):
				continue
			var dirv := dir_vector(i, d)
			var pos: Vector3 = room.center + dirv * (r - 0.5) + Vector3(0, 1.1, 0)
			if room.type == ROOM_STAIR:
				pos.y += STAIR_RISE   # stairwell exits live on the upper level
			var bulb := _mi(_sphere(0.20), _glow_mat(Color(1.0, 0.85, 0.35), 3.2), pos)
			socket_root.add_child(bulb)
			sockets.append({ "room": i, "dir": d, "pos": pos })

func hide_sockets() -> void:
	sockets.clear()
	for c in socket_root.get_children():
		c.queue_free()

## Nearest plantable socket within reach of a global position ({} if none).
func nearest_socket(gpos: Vector3) -> Dictionary:
	var best := {}
	var bd := 3.0
	for s in sockets:
		var d: float = gpos.distance_to(to_global(s.pos))
		if d < bd:
			bd = d
			best = s
	return best

func _new_center(room_idx: int, dir_idx: int, type: int) -> Vector3:
	var parent = rooms[room_idx]
	var dir := dir_vector(room_idx, dir_idx)
	var dist: float = ROOM_DEFS[parent.type].radius + ROOM_DEFS[type].radius + CORRIDOR_LEN
	var c: Vector3 = parent.center + dir * dist
	if parent.type == ROOM_STAIR:
		c.y = parent.center.y + STAIR_RISE   # rooms grown from a stairwell sit on its upper level
	return c

# --- CSG construction -------------------------------------------------------------

## Rebuild the whole carved interior: one solid mass, rooms + corridors carved out,
## floors added back in. Seamless by construction.
func _rebuild() -> void:
	for c in combiner.get_children():
		c.free()
	# bounding solid sized to the current layout
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	for room in rooms:
		var r: float = ROOM_DEFS[room.type].radius
		lo = lo.min(room.center - Vector3(r, 2, r) * 2.0)
		hi = hi.max(room.center + Vector3(r, r + STAIR_RISE, r) * 2.0)
	var solid := CSGBox3D.new()
	solid.size = (hi - lo) + Vector3(16, 14, 22)
	solid.position = (hi + lo) * 0.5 + Vector3(0, 2.0, 0)
	solid.material = wall_mat
	combiner.add_child(solid)

	for room in rooms:
		var r: float = ROOM_DEFS[room.type].radius
		if room.type == ROOM_STAIR:
			var shaft := CSGCylinder3D.new()
			shaft.operation = CSGShape3D.OPERATION_SUBTRACTION
			shaft.radius = r
			shaft.height = STAIR_RISE + 5.0
			shaft.sides = 24
			shaft.material = wall_mat
			shaft.position = room.center + Vector3(0, (STAIR_RISE + 5.0) * 0.5 - 0.4, 0)
			combiner.add_child(shaft)
		else:
			var pod := CSGSphere3D.new()
			pod.operation = CSGShape3D.OPERATION_SUBTRACTION
			pod.radius = r
			pod.radial_segments = 32
			pod.rings = 16
			pod.material = wall_mat
			pod.position = room.center + Vector3(0, r * 0.42, 0)
			combiner.add_child(pod)
		# floor disc
		var fl := CSGCylinder3D.new()
		fl.radius = r * 0.96
		fl.height = 0.5
		fl.sides = 28
		fl.material = floor_mat
		fl.position = room.center + Vector3(0, -0.25, 0)
		combiner.add_child(fl)
		# stairwell: a RUNNABLE 270° ramp. It ends above the ENTRY side (where no top
		# exits ever connect), and the platform is cut away over the whole final
		# approach quadrant — full head clearance the entire way up.
		if room.type == ROOM_STAIR:
			var pdir := Vector3(0, 0, -1)
			if room.parent >= 0:
				var pd: Vector3 = rooms[room.parent].center - room.center
				pdir = Vector3(pd.x, 0, pd.z).normalized()
			var a0 := atan2(pdir.z, pdir.x)
			var rr := r - 1.15
			var ramp_start := a0 + PI * 0.75
			for s in 3:
				var aA := ramp_start + float(s) * PI * 0.5
				var aB := ramp_start + float(s + 1) * PI * 0.5
				var pA: Vector3 = room.center + Vector3(cos(aA) * rr, 0.15 + (STAIR_RISE - 0.15) * float(s) / 3.0, sin(aA) * rr)
				var pB: Vector3 = room.center + Vector3(cos(aB) * rr, 0.15 + (STAIR_RISE - 0.15) * float(s + 1) / 3.0, sin(aB) * rr)
				var seg := CSGBox3D.new()
				var span := pB - pA
				seg.size = Vector3(1.7, 0.28, span.length() + 0.7)
				seg.material = floor_mat
				seg.position = (pA + pB) * 0.5
				seg.rotation.y = atan2(span.x, span.z)
				seg.rotation.x = -atan2(span.y, Vector2(span.x, span.z).length())
				combiner.add_child(seg)
			var top := CSGCylinder3D.new()
			top.radius = r * 0.96
			top.height = 0.4
			top.sides = 24
			top.material = floor_mat
			top.position = room.center + Vector3(0, STAIR_RISE - 0.2, 0)
			combiner.add_child(top)
			# carve the platform + headroom above the final approach quadrant
			var cut := CSGBox3D.new()
			cut.operation = CSGShape3D.OPERATION_SUBTRACTION
			cut.size = Vector3(r * 1.15, 3.0, r * 1.15)
			cut.material = wall_mat
			cut.position = room.center + Vector3(cos(a0) * r * 0.60, STAIR_RISE + 1.1, sin(a0) * r * 0.60)
			cut.rotation.y = -a0
			combiner.add_child(cut)

	for cor in corridors:
		var a: Vector3 = cor.from + Vector3(0, 1.5, 0)
		var b: Vector3 = cor.to + Vector3(0, 1.5, 0)
		var tunnel := CSGCylinder3D.new()
		tunnel.operation = CSGShape3D.OPERATION_SUBTRACTION
		tunnel.radius = CORRIDOR_R
		tunnel.height = a.distance_to(b) + 2.0
		tunnel.sides = 16
		tunnel.material = wall_mat
		tunnel.position = (a + b) * 0.5
		# cylinder's axis is Y; rotate it to lie along a->b
		var axis := (b - a).normalized()
		var rot_axis := Vector3.UP.cross(axis)
		if rot_axis.length() > 0.001:
			tunnel.rotate(rot_axis.normalized(), Vector3.UP.angle_to(axis))
		combiner.add_child(tunnel)
		# flat walkway through the tunnel
		var walk := CSGBox3D.new()
		walk.size = Vector3(CORRIDOR_R * 1.5, 0.4, cor.from.distance_to(cor.to) + 2.0)
		walk.material = floor_mat
		walk.position = (cor.from + cor.to) * 0.5 + Vector3(0, -0.2, 0)
		var flat_axis: Vector3 = cor.to - cor.from
		walk.rotation.y = atan2(flat_axis.x, flat_axis.z)
		walk.rotation.x = -atan2(flat_axis.y, Vector2(flat_axis.x, flat_axis.z).length())
		combiner.add_child(walk)

	_rebuild_decor()

func _rebuild_decor() -> void:
	for c in decor_root.get_children():
		c.free()
	terminal = null
	refiners.clear()
	for i in rooms.size():
		var room = rooms[i]
		var r: float = ROOM_DEFS[room.type].radius
		# purpose-room furniture
		if room.type == ROOM_STORAGE:
			var srng := RandomNumberGenerator.new()
			srng.seed = 40 + i
			var sac_cols := [Color(0.72, 0.72, 0.75), Color(0.65, 0.42, 0.22), Color(0.45, 0.90, 1.0), Color(0.50, 1.0, 0.60)]
			for k in 5:
				var a := srng.randf() * TAU
				var sr := srng.randf_range(0.45, 0.8)
				var sac := _mi(_sphere(sr), _glow_mat(sac_cols[k % sac_cols.size()], 0.35),
					room.center + Vector3(cos(a) * r * 0.55, sr * 0.8, sin(a) * r * 0.55))
				sac.scale = Vector3(1.0, 1.25, 1.0)
				decor_root.add_child(sac)
		elif room.type == ROOM_REFINER:
			var pillar := _mi(_cyl_mesh(0.30, 0.55, 2.4), _bark_mat(), room.center + Vector3(0, 1.2, 0))
			decor_root.add_child(pillar)
			decor_root.add_child(_mi(_sphere(0.34), _glow_mat(Color(1.0, 0.55, 0.20), 3.0), room.center + Vector3(0, 2.7, 0)))
			refiners.append(room.center + Vector3(0, 1.0, 0))
		var light := OmniLight3D.new()
		light.light_color = Color(0.45, 1.0, 0.82) if i % 2 == 0 else Color(0.75, 0.55, 1.0)
		light.light_energy = 1.6
		light.omni_range = r * 2.6
		light.position = room.center + Vector3(0, r * 0.7, 0)
		decor_root.add_child(light)
		var bulb := _mi(_sphere(0.26), _glow_mat(Color(0.55, 1.0, 0.80), 2.6), room.center + Vector3(0, r * 0.95, 0))
		decor_root.add_child(bulb)
		var rng := RandomNumberGenerator.new()
		rng.seed = 700 + i
		for k in rng.randi_range(3, 5):
			var a := rng.randf() * TAU
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = rng.randf_range(0.10, 0.18)
			cone.height = rng.randf_range(0.25, 0.5)
			var mcol := Color(0.75, 0.45, 1.0) if k % 2 == 0 else Color(0.35, 1.0, 0.7)
			decor_root.add_child(_mi(cone, _glow_mat(mcol, 1.4),
				room.center + Vector3(cos(a) * r * 0.62, 0.12, sin(a) * r * 0.62)))
	# entry arch glow hugging the tunnel mouth (portal disc fills it)
	var arch := TorusMesh.new()
	arch.inner_radius = CORRIDOR_R * 0.94
	arch.outer_radius = CORRIDOR_R * 1.06
	decor_root.add_child(_mi(arch, _glow_mat(Color(0.30, 1.0, 0.65), 3.0), portal_marker.position, Vector3(90, 0, 0)))
	# THE growth terminal: one glowing stump in the entry pod
	terminal = Node3D.new()
	var r0: float = ROOM_DEFS[rooms[0].type].radius
	terminal.position = Vector3(r0 * 0.62, 0, 0)
	var stump := _mi(_cyl_mesh(0.24, 0.34, 1.0), _bark_mat(), Vector3(0, 0.5, 0))
	terminal.add_child(stump)
	terminal.add_child(_mi(_sphere(0.24), _glow_mat(Color(1.0, 0.85, 0.35), 3.2), Vector3(0, 1.18, 0)))
	decor_root.add_child(terminal)

# --- helpers -----------------------------------------------------------------------

func _mi(mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot
	return mi

func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	return s

func _cyl_mesh(top_r: float, bot_r: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top_r
	c.bottom_radius = bot_r
	c.height = h
	return c

func _bark_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.30, 0.20, 0.32)
	m.roughness = 1.0
	return m

func _glow_mat(color: Color, energy := 2.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m
