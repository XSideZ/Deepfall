extends Node3D
## Ark/Rust-style base building: 3 m grid cells, 2.6 m wall levels.
## Foundations snap to the world grid; walls/half walls/doorways snap onto cell
## edges (and stack); floors cap walls or extend sideways; doors fill doorways
## (E toggles); ramps run off edges. A ghost preview shows validity.

const CELL := 3.0
const WALL_H := 2.6

const PIECES := [
	{ "name": "Foundation", "cost": { "Stone": 4 } },
	{ "name": "Floor", "cost": { "Wood": 3 } },
	{ "name": "Wall", "cost": { "Wood": 3 } },
	{ "name": "Half wall", "cost": { "Wood": 2 } },
	{ "name": "Doorway", "cost": { "Wood": 3 } },
	{ "name": "Vine door", "cost": { "Wood": 2 } },
	{ "name": "Ramp", "cost": { "Wood": 2 } },
	{ "name": "Window", "cost": { "Wood": 3 } },
	{ "name": "Stairs", "cost": { "Wood": 3 } },
]
const P_FOUNDATION := 0
const P_FLOOR := 1
const P_WALL := 2
const P_HALF := 3
const P_DOORWAY := 4
const P_DOOR := 5
const P_RAMP := 6
const P_WINDOW := 7
const P_STAIRS := 8

const EDGE_DIRS := [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)]

var terrain
var cells := {}     # Vector3i(cx,lvl,cz) -> { y_top, node, kind }
var walls := {}     # "cx,lvl,cz,edge" -> { node, type, base_y, cell: Vector3i, edge, door: Node3D|null, open }
var ramps := {}     # same key -> { node }
var doors: Array = []   # { pivot, body, open, key }

var wood_mat: StandardMaterial3D
var wood_b_mat: StandardMaterial3D
var frame_mat: StandardMaterial3D
var seam_mat: StandardMaterial3D
var vine_mat: StandardMaterial3D
var ghost_mat: StandardMaterial3D
var door_user: Node3D = null   # doors auto-part for this body (the test player)
var rot_offset := 0            # R rotates: edge snap for pieces, 90° for modules
var ghost: Node3D
var _ghost_piece := -1
var pending := {}   # resolved placement info for place_pending()

# modular prefab buildings (Meshy GLBs dropped in res://assets/modules/)
const MODULE_COST := { "Wood": 10, "Stone": 10 }
var modules: Array = []          # { name, path, scene, aabb }
var placed_modules: Array = []   # { path, node }

func setup(t) -> void:
	terrain = t
	if modules.is_empty():
		scan_modules()
	if wood_mat == null:
		# ALIEN-GROWN palette: warm planks in dark bark-purple frames (matches the
		# home tree) with thin glowing sap seams. Flat tones, detail from geometry.
		wood_mat = StandardMaterial3D.new()
		wood_mat.albedo_color = Color(0.68, 0.55, 0.36)
		wood_mat.roughness = 0.85
		wood_b_mat = StandardMaterial3D.new()
		wood_b_mat.albedo_color = Color(0.57, 0.44, 0.29)
		wood_b_mat.roughness = 0.85
		frame_mat = StandardMaterial3D.new()
		frame_mat.albedo_color = Color(0.30, 0.20, 0.30)
		frame_mat.roughness = 0.9
		seam_mat = StandardMaterial3D.new()
		seam_mat.albedo_color = Color(0.30, 1.0, 0.65)
		seam_mat.emission_enabled = true
		seam_mat.emission = Color(0.30, 1.0, 0.65)
		seam_mat.emission_energy_multiplier = 1.2
		vine_mat = StandardMaterial3D.new()
		vine_mat.albedo_color = Color(0.30, 0.55, 0.26)
		vine_mat.roughness = 0.9
		ghost_mat = StandardMaterial3D.new()
		ghost_mat.albedo_color = Color(0.3, 1.0, 0.6, 0.45)
		ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

func piece_cost(p: int) -> Dictionary:
	return PIECES[p].cost

func piece_name(p: int) -> String:
	return PIECES[p].name

## Prefab structures: any .glb/.fbx dropped in assets/modules/ becomes placeable.
func scan_modules() -> void:
	modules.clear()
	var d := DirAccess.open("res://assets/modules")
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var ext := f.get_extension().to_lower()
		if not d.current_is_dir() and (ext == "glb" or ext == "fbx"):
			var path := "res://assets/modules/" + f
			var ps = load(path)
			if ps is PackedScene:
				var inst: Node = (ps as PackedScene).instantiate()
				var aabb := _scene_aabb(inst)
				inst.free()
				modules.append({ "name": f.get_basename().capitalize(), "path": path,
					"scene": ps, "aabb": aabb })
		f = d.get_next()
	d.list_dir_end()

func _scene_aabb(n: Node) -> AABB:
	var total := AABB()
	var first := true
	var stack: Array = [[n, Transform3D()]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var cur: Node = item[0]
		var xf: Transform3D = item[1]
		if cur is Node3D:
			xf = xf * (cur as Node3D).transform
		if cur is MeshInstance3D and (cur as MeshInstance3D).mesh:
			var ab: AABB = xf * (cur as MeshInstance3D).mesh.get_aabb()
			total = ab if first else total.merge(ab)
			first = false
		for c in cur.get_children():
			stack.push_back([c, xf])
	return total

## Ghost + snap for a prefab module: world grid, terrain height, R = 90° turns.
func update_ghost_module(mi: int, cam: Camera3D) -> bool:
	if mi < 0 or mi >= modules.size():
		return false
	var want := 1000 + mi
	if _ghost_piece != want:
		_ghost_piece = want
		if ghost and is_instance_valid(ghost):
			ghost.queue_free()
		ghost = (modules[mi].scene as PackedScene).instantiate()
		_ghostify(ghost)
		add_child(ghost)
	pending = {}
	var hit := _ray(cam)
	var ok := false
	if not hit.is_empty():
		var p: Vector3 = hit.position
		var cx := int(round(p.x / CELL))
		var cz := int(round(p.z / CELL))
		var aabb: AABB = modules[mi].aabb
		var half := maxf(aabb.size.x, aabb.size.z) * 0.5
		var hs: Array = []
		for off in [Vector2(0, 0), Vector2(-half, -half), Vector2(half, -half), Vector2(-half, half), Vector2(half, half)]:
			hs.append(terrain.height_at(cx * CELL + off.x, cz * CELL + off.y))
		var hmax: float = hs.max()
		if hmax - hs.min() < 3.0:
			var y: float = hmax + 0.05 - aabb.position.y
			var b := Basis(Vector3.UP, float(rot_offset) * PI * 0.5)
			pending = { "kind": "module", "mi": mi,
				"xform": Transform3D(b, Vector3(cx * CELL, y, cz * CELL)), "ground": hmax, "half": half }
			ok = true
	ghost.visible = ok
	ghost_mat.albedo_color = Color(0.3, 1.0, 0.6, 0.45) if ok else Color(1.0, 0.3, 0.3, 0.45)
	if ok:
		ghost.global_transform = pending.xform
	return ok

func _ghostify(n: Node) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_override = ghost_mat
	for c in n.get_children():
		_ghostify(c)

# --- ghost / aiming -------------------------------------------------------------

## Aim-resolve the selected piece and show the ghost. Returns true when placeable.
func update_ghost(piece: int, cam: Camera3D) -> bool:
	if _ghost_piece != piece:
		_ghost_piece = piece
		if ghost and is_instance_valid(ghost):
			ghost.queue_free()
		ghost = _make_visual(piece, true)
		add_child(ghost)
	pending = _resolve(piece, cam)
	var ok: bool = not pending.is_empty()
	ghost.visible = ok
	ghost_mat.albedo_color = Color(0.3, 1.0, 0.6, 0.45) if ok else Color(1.0, 0.3, 0.3, 0.45)
	if ok:
		ghost.global_transform = pending.xform
	return ok

func hide_ghost() -> void:
	if ghost and is_instance_valid(ghost):
		ghost.queue_free()
	ghost = null
	_ghost_piece = -1
	pending = {}

func _ray(cam: Camera3D) -> Dictionary:
	var from := cam.global_position
	var to := from + (-cam.global_transform.basis.z) * 12.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | 2)
	return get_world_3d().direct_space_state.intersect_ray(q)

func _resolve(piece: int, cam: Camera3D) -> Dictionary:
	var hit := _ray(cam)
	if hit.is_empty():
		return {}
	var p: Vector3 = hit.position
	var col: Object = hit.collider

	match piece:
		P_FOUNDATION:
			var cx := int(round(p.x / CELL))
			var cz := int(round(p.z / CELL))
			var key := Vector3i(cx, 0, cz)
			if cells.has(key):
				return {}
			# terrain must be reasonably flat and dry under the pad
			var hs: Array = []
			for off in [Vector2(-1.2, -1.2), Vector2(1.2, -1.2), Vector2(-1.2, 1.2), Vector2(1.2, 1.2)]:
				hs.append(terrain.height_at(cx * CELL + off.x, cz * CELL + off.y))
			var hmax: float = hs.max()
			if hmax - hs.min() > 1.8:
				return {}
			var y_top: float = hmax + 0.25
			# LEVEL-LOCK to adjacent pads: connected foundations share one height,
			# so a base is a flat platform instead of terrain-following steps
			for nb in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				var nkey: Vector3i = key + nb
				if cells.has(nkey) and cells[nkey].kind == "foundation":
					var ny: float = cells[nkey].y_top
					# reject if the ground would bury the pad or leave it floating high
					if hmax - ny > 0.9 or ny - hmax > 2.6:
						return {}
					y_top = ny
					break
			return { "piece": piece, "kind": "cell", "cellkind": "foundation", "key": key, "y_top": y_top,
				"xform": Transform3D(Basis(), Vector3(cx * CELL, y_top - 0.2, cz * CELL)) }
		P_FLOOR:
			if col is Node and (col as Node).has_meta("b_wall"):
				var w = walls.get((col as Node).get_meta("b_wall"))
				if w == null or w.type == P_HALF:
					return {}
				var c: Vector3i = w.cell
				var key2 := Vector3i(c.x, c.y + 1, c.z)
				if cells.has(key2):
					return {}
				var yt: float = w.base_y + WALL_H + 0.15
				return { "piece": piece, "kind": "cell", "cellkind": "floor", "key": key2, "y_top": yt,
					"xform": Transform3D(Basis(), Vector3(c.x * CELL, yt - 0.15, c.z * CELL)) }
			if col is Node and (col as Node).has_meta("b_cell"):
				var ck: Vector3i = (col as Node).get_meta("b_cell")
				var base = cells.get(ck)
				if base == null:
					return {}
				# extend sideways toward the aim point
				var center := Vector3(ck.x * CELL, 0, ck.z * CELL)
				var d := p - center
				var edge := 0 if absf(d.x) > absf(d.z) else 1
				var step := Vector3i(signi(int(round(d.x * 10.0))), 0, 0) if edge == 0 else Vector3i(0, 0, signi(int(round(d.z * 10.0))))
				var key3 := ck + step
				if step == Vector3i.ZERO or cells.has(key3):
					return {}
				if ck.y == 0:
					return {}   # ground level extends with foundations, not floors
				return { "piece": piece, "kind": "cell", "cellkind": "floor", "key": key3, "y_top": base.y_top,
					"xform": Transform3D(Basis(), Vector3(key3.x * CELL, base.y_top - 0.15, key3.z * CELL)) }
			return {}
		P_WALL, P_HALF, P_DOORWAY, P_WINDOW:
			if col is Node and (col as Node).has_meta("b_wall") and piece != P_HALF:
				var below = walls.get((col as Node).get_meta("b_wall"))
				if below == null or below.type == P_HALF:
					return {}
				var c3: Vector3i = below.cell
				var up := Vector3i(c3.x, c3.y + 1, c3.z)
				var wkey2 := "%d,%d,%d,%d" % [up.x, up.y, up.z, below.edge]
				if walls.has(wkey2):
					return {}
				return _wall_pending(piece, up, below.edge, below.base_y + WALL_H, wkey2)
			# pad body OR terrain near a pad (flush/buried pads still take walls)
			var spotw := _aimed_cell_edge(col, p)
			if spotw.is_empty():
				return {}
			var ck2: Vector3i = spotw.key
			var edge2: int = spotw.edge
			var base2 = cells.get(ck2)
			var wkey := "%d,%d,%d,%d" % [ck2.x, ck2.y, ck2.z, edge2]
			if walls.has(wkey):
				return {}
			return _wall_pending(piece, ck2, edge2, base2.y_top, wkey)
		P_DOOR:
			if col is Node and (col as Node).has_meta("b_wall"):
				var w2 = walls.get((col as Node).get_meta("b_wall"))
				if w2 != null and w2.type == P_DOORWAY and w2.door == null:
					var dirv: Vector3 = EDGE_DIRS[w2.edge]
					var pos := Vector3(w2.cell.x * CELL, w2.base_y, w2.cell.z * CELL) + dirv * (CELL * 0.5)
					return { "piece": piece, "kind": "door", "wkey": (col as Node).get_meta("b_wall"),
						"xform": Transform3D(Basis(Vector3.UP, _edge_yaw(w2.edge)), pos) }
			return {}
		P_RAMP:
			var spot := _aimed_cell_edge(col, p)
			if spot.is_empty():
				return {}
			var ck4: Vector3i = spot.key
			var edge4: int = spot.edge
			var base4 = cells.get(ck4)
			var rkey := "%d,%d,%d,%d" % [ck4.x, ck4.y, ck4.z, edge4]
			if ramps.has(rkey) or walls.has(rkey):
				return {}
			var dirv4: Vector3 = EDGE_DIRS[edge4]
			var top := Vector3(ck4.x * CELL, base4.y_top, ck4.z * CELL) + dirv4 * (CELL * 0.5)
			var drop := WALL_H if ck4.y > 0 else clampf(base4.y_top - terrain.height_at(top.x + dirv4.x * 3.0, top.z + dirv4.z * 3.0), 0.8, 6.0)
			var run := 3.2
			var mid := top + dirv4 * (run * 0.5) + Vector3(0, -drop * 0.5, 0)
			var b := Basis(Vector3.UP, _edge_yaw(edge4))
			b = b.rotated(b.x, -atan2(drop, run))
			return { "piece": piece, "kind": "ramp", "key": rkey, "len": sqrt(drop * drop + run * run),
				"xform": Transform3D(b, mid) }
		P_STAIRS:
			var spot2 := _aimed_cell_edge(col, p)
			if spot2.is_empty():
				return {}
			var ck5: Vector3i = spot2.key
			var edge5: int = spot2.edge
			var base5 = cells.get(ck5)
			var wkey5 := "%d,%d,%d,%d" % [ck5.x, ck5.y, ck5.z, edge5]
			var skey := "s_" + wkey5
			if ramps.has(skey) or walls.has(wkey5):
				return {}
			var dirv5: Vector3 = EDGE_DIRS[edge5]
			# stairs climb INSIDE the cell, landing at the aimed edge one level up
			var b5 := Basis(Vector3.UP, atan2(dirv5.x, dirv5.z))
			return { "piece": piece, "kind": "ramp", "key": skey, "len": 4.0,
				"xform": Transform3D(b5, Vector3(ck5.x * CELL, base5.y_top, ck5.z * CELL)) }
	return {}

## Cell+edge from whatever is aimed at: a pad/floor body directly, or terrain near one.
func _aimed_cell_edge(col: Object, p: Vector3) -> Dictionary:
	if col is Node and (col as Node).has_meta("b_cell"):
		var ck: Vector3i = (col as Node).get_meta("b_cell")
		if cells.has(ck):
			return { "key": ck, "edge": _edge_toward(ck, p) }
	# aiming at the ground near a pad still works (generous snap radius)
	var best := {}
	var bd := CELL * 2.4
	for key in cells:
		var c: Vector3i = key
		var center := Vector3(c.x * CELL, cells[key].y_top, c.z * CELL)
		if absf(p.y - center.y) > 4.5:
			continue
		var d := Vector2(p.x - center.x, p.z - center.z).length()
		if d < bd:
			bd = d
			best = { "key": c, "edge": _edge_toward(c, p) }
	return best

## Edge facing the aim point, cycled by R (rot_offset).
func _edge_toward(ck: Vector3i, p: Vector3) -> int:
	var dv := p - Vector3(ck.x * CELL, 0, ck.z * CELL)
	var e := 0
	if absf(dv.x) > absf(dv.z):
		e = 0 if dv.x > 0 else 2
	else:
		e = 1 if dv.z > 0 else 3
	return (e + rot_offset) % 4

func _wall_pending(piece: int, cellk: Vector3i, edge: int, base_y: float, wkey: String) -> Dictionary:
	var dirv: Vector3 = EDGE_DIRS[edge]
	var pos := Vector3(cellk.x * CELL, base_y, cellk.z * CELL) + dirv * (CELL * 0.5)
	return { "piece": piece, "kind": "wall", "key": wkey, "cell": cellk, "edge": edge, "base_y": base_y,
		"xform": Transform3D(Basis(Vector3.UP, _edge_yaw(edge)), pos) }

func _edge_yaw(edge: int) -> float:
	return [PI * 0.5, 0.0, PI * 0.5, 0.0][edge]

# --- placement --------------------------------------------------------------------

## Place whatever the ghost resolved. Returns the piece id placed, or -1.
func place_pending() -> int:
	if pending.is_empty():
		return -1
	var piece: int = pending.piece
	match pending.kind:
		"cell":
			var body := _make_body(piece)
			add_child(body)
			body.global_transform = pending.xform
			body.set_meta("b_cell", pending.key)
			cells[pending.key] = { "y_top": pending.y_top, "node": body, "kind": pending.cellkind }
			# ground conforms to new foundations: uphill terrain is notched out, downhill
			# fill snugs up underneath — the pad sits IN the land (shadows land right too)
			if pending.cellkind == "foundation" and terrain:
				var k: Vector3i = pending.key
				terrain.sculpt(Vector3(k.x * CELL, 0, k.z * CELL), 2.4, 1.0, 3, pending.y_top - 0.3)
		"wall":
			var body2 := _make_body(piece)
			add_child(body2)
			body2.global_transform = pending.xform
			body2.set_meta("b_wall", pending.key)
			walls[pending.key] = { "node": body2, "type": piece, "base_y": pending.base_y,
				"cell": pending.cell, "edge": pending.edge, "door": null, "open": false }
		"door":
			var w = walls.get(pending.wkey)
			if w == null or w.door != null:
				return -1
			var door := _make_door()
			add_child(door)
			door.global_transform = pending.xform
			w.door = door
			doors.append({ "root": door, "open": false, "wkey": pending.wkey })
		"ramp":
			var body3 := _make_body(piece, pending.get("len", 4.0))
			add_child(body3)
			body3.global_transform = pending.xform
			body3.set_meta("b_ramp", pending.key)
			ramps[pending.key] = { "node": body3, "t": piece, "len": pending.get("len", 4.0) }
		"module":
			var m: Dictionary = modules[pending.mi]
			var body4 := _spawn_module(m.path, pending.xform)
			if body4 == null:
				return -1
			# seat the building into the land like foundations do
			terrain.sculpt(Vector3(pending.xform.origin.x, 0, pending.xform.origin.z),
				minf(pending.half + 1.2, 14.0), 1.0, 3, pending.ground - 0.05)
			pending = {}
			return 1000
	var placed: int = piece
	pending = {}
	return placed

## Spawn a placed prefab: real scene + walkable trimesh collision per mesh.
func _spawn_module(path: String, xform: Transform3D) -> StaticBody3D:
	var ps = load(path)
	if not (ps is PackedScene):
		return null
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.set_meta("build", true)
	body.set_meta("b_module", path)
	body.set_meta("hits", 4)
	var inst: Node3D = (ps as PackedScene).instantiate()
	body.add_child(inst)
	# trimesh shapes so interiors are walkable
	var stack: Array = [[inst as Node, Transform3D()]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var cur: Node = item[0]
		var xf: Transform3D = item[1]
		if cur is Node3D:
			xf = xf * (cur as Node3D).transform
		if cur is MeshInstance3D and (cur as MeshInstance3D).mesh:
			var cs := CollisionShape3D.new()
			cs.shape = (cur as MeshInstance3D).mesh.create_trimesh_shape()
			cs.transform = xf
			body.add_child(cs)
		for c in cur.get_children():
			stack.push_back([c, xf])
	add_child(body)
	body.global_transform = xform
	placed_modules.append({ "path": path, "node": body })
	return body

## A build piece was destroyed by motes: unregister it.
func remove_by_body(body: Node) -> void:
	for i in placed_modules.size():
		if placed_modules[i].node == body:
			placed_modules.remove_at(i)
			return
	for i in doors.size():
		if doors[i].root == body:
			var w = walls.get(doors[i].wkey)
			if w != null:
				w.door = null
			doors.remove_at(i)
			return
	for key in cells.keys():
		if cells[key].node == body:
			cells.erase(key)
			return
	for key in walls.keys():
		if walls[key].node == body:
			if walls[key].door and is_instance_valid(walls[key].door):
				walls[key].door.queue_free()
			walls.erase(key)
			return
	for key in ramps.keys():
		if ramps[key].node == body:
			ramps.erase(key)
			return

# --- geometry ----------------------------------------------------------------------

## Simple physics shapes (visuals are detailed planks; collision stays cheap & clean).
func _collision_boxes(piece: int, ramp_len := 4.0) -> Array:
	match piece:
		P_FOUNDATION:
			return [[Vector3(CELL, 0.4, CELL), Vector3.ZERO]]
		P_FLOOR:
			return [[Vector3(CELL, 0.3, CELL), Vector3.ZERO]]
		P_WALL:
			return [[Vector3(CELL, WALL_H, 0.24), Vector3(0, WALL_H * 0.5, 0)]]
		P_HALF:
			return [[Vector3(CELL, WALL_H * 0.5, 0.24), Vector3(0, WALL_H * 0.25, 0)]]
		P_DOORWAY:
			return [
				[Vector3(0.95, WALL_H, 0.24), Vector3(-1.025, WALL_H * 0.5, 0)],
				[Vector3(0.95, WALL_H, 0.24), Vector3(1.025, WALL_H * 0.5, 0)],
				[Vector3(1.1, 0.6, 0.24), Vector3(0, WALL_H - 0.3, 0)],
			]
		P_RAMP:
			return [[Vector3(CELL, 0.25, ramp_len), Vector3.ZERO]]
		P_WINDOW:
			return [
				[Vector3(CELL, 1.0, 0.24), Vector3(0, 0.5, 0)],
				[Vector3(CELL, 0.6, 0.24), Vector3(0, WALL_H - 0.3, 0)],
				[Vector3(0.95, 1.0, 0.24), Vector3(-1.025, 1.5, 0)],
				[Vector3(0.95, 1.0, 0.24), Vector3(1.025, 1.5, 0)],
			]
		P_STAIRS:
			return [[Vector3(CELL, 0.25, 4.0), Vector3(0, WALL_H * 0.5, 0),
				Vector3(rad_to_deg(atan2(WALL_H, CELL)), 0, 0)]]
	return []

## Detailed plank visuals: [size, offset, mat 0=wood / 1=frame / 2=wood-dark].
func _visual_boxes(piece: int, ramp_len := 4.0) -> Array:
	var out: Array = []
	match piece:
		P_FOUNDATION:
			out.append([Vector3(CELL, 0.34, CELL), Vector3(0, -0.03, 0), 1])
			for i in 6:
				out.append([Vector3(0.47, 0.14, CELL - 0.1), Vector3(-1.25 + i * 0.5, 0.14, 0), (i % 2) * 2])
			out.append([Vector3(CELL - 0.2, 0.05, 0.07), Vector3(0, 0.16, 1.42), 3])
			out.append([Vector3(CELL - 0.2, 0.05, 0.07), Vector3(0, 0.16, -1.42), 3])
		P_FLOOR:
			out.append([Vector3(CELL, 0.14, 0.2), Vector3(0, -0.05, 1.4), 1])
			out.append([Vector3(CELL, 0.14, 0.2), Vector3(0, -0.05, -1.4), 1])
			for i in 6:
				out.append([Vector3(0.47, 0.16, CELL - 0.28), Vector3(-1.25 + i * 0.5, 0.05, 0), (i % 2) * 2])
		P_WALL:
			out.append([Vector3(0.20, WALL_H, 0.26), Vector3(-1.4, WALL_H * 0.5, 0), 1])
			out.append([Vector3(0.20, WALL_H, 0.26), Vector3(1.4, WALL_H * 0.5, 0), 1])
			out.append([Vector3(2.6, 0.20, 0.26), Vector3(0, 0.12, 0), 1])
			out.append([Vector3(2.6, 0.20, 0.26), Vector3(0, WALL_H - 0.12, 0), 1])
			for i in 5:
				out.append([Vector3(0.5, WALL_H - 0.42, 0.18), Vector3(-1.04 + i * 0.52, WALL_H * 0.5, 0), (i % 2) * 2])
			out.append([Vector3(0.06, WALL_H - 0.5, 0.28), Vector3(-1.28, WALL_H * 0.5, 0), 3])
			out.append([Vector3(0.06, WALL_H - 0.5, 0.28), Vector3(1.28, WALL_H * 0.5, 0), 3])
		P_HALF:
			var h := WALL_H * 0.5
			out.append([Vector3(0.20, h, 0.26), Vector3(-1.4, h * 0.5, 0), 1])
			out.append([Vector3(0.20, h, 0.26), Vector3(1.4, h * 0.5, 0), 1])
			out.append([Vector3(2.6, 0.18, 0.26), Vector3(0, h - 0.1, 0), 1])
			for i in 5:
				out.append([Vector3(0.5, h - 0.24, 0.18), Vector3(-1.04 + i * 0.52, h * 0.5 - 0.05, 0), (i % 2) * 2])
		P_DOORWAY:
			out.append([Vector3(0.20, WALL_H, 0.26), Vector3(-1.4, WALL_H * 0.5, 0), 1])
			out.append([Vector3(0.20, WALL_H, 0.26), Vector3(1.4, WALL_H * 0.5, 0), 1])
			out.append([Vector3(0.20, WALL_H, 0.26), Vector3(-0.62, WALL_H * 0.5, 0), 1])
			out.append([Vector3(0.20, WALL_H, 0.26), Vector3(0.62, WALL_H * 0.5, 0), 1])
			out.append([Vector3(1.04, 0.5, 0.26), Vector3(0, WALL_H - 0.28, 0), 1])
			for side in [-1.0, 1.0]:
				for i in 2:
					out.append([Vector3(0.34, WALL_H - 0.2, 0.18), Vector3(side * (0.85 + i * 0.37), WALL_H * 0.5, 0), i * 2])
			out.append([Vector3(0.06, WALL_H - 0.7, 0.28), Vector3(-0.56, (WALL_H - 0.6) * 0.5, 0), 3])
			out.append([Vector3(0.06, WALL_H - 0.7, 0.28), Vector3(0.56, (WALL_H - 0.6) * 0.5, 0), 3])
		P_RAMP:
			out.append([Vector3(0.20, 0.18, ramp_len), Vector3(-1.4, 0.02, 0), 1])
			out.append([Vector3(0.20, 0.18, ramp_len), Vector3(1.4, 0.02, 0), 1])
			for i in 5:
				out.append([Vector3(0.52, 0.14, ramp_len - 0.15), Vector3(-1.04 + i * 0.52, 0.0, 0), (i % 2) * 2])
		P_DOOR:
			# ghost silhouette: a curtain of vine strands
			for i in 6:
				out.append([Vector3(0.10, 2.0, 0.10), Vector3(-0.45 + i * 0.18, 1.0, 0), 2])
		P_WINDOW:
			out.append([Vector3(0.20, WALL_H, 0.26), Vector3(-1.4, WALL_H * 0.5, 0), 1])
			out.append([Vector3(0.20, WALL_H, 0.26), Vector3(1.4, WALL_H * 0.5, 0), 1])
			out.append([Vector3(2.6, 0.20, 0.26), Vector3(0, 0.12, 0), 1])
			out.append([Vector3(2.6, 0.20, 0.26), Vector3(0, WALL_H - 0.12, 0), 1])
			# planks below the sill and above the header
			for i in 5:
				out.append([Vector3(0.5, 0.72, 0.18), Vector3(-1.04 + i * 0.52, 0.6, 0), (i % 2) * 2])
				out.append([Vector3(0.5, 0.36, 0.18), Vector3(-1.04 + i * 0.52, WALL_H - 0.42, 0), (i % 2) * 2])
			# side planks + sill/lintel frame around the opening
			for side in [-1.0, 1.0]:
				out.append([Vector3(0.72, 1.04, 0.18), Vector3(side * 0.94, 1.52, 0), 0])
			out.append([Vector3(1.3, 0.14, 0.28), Vector3(0, 0.99, 0), 1])
			out.append([Vector3(1.3, 0.14, 0.28), Vector3(0, 2.06, 0), 1])
			out.append([Vector3(0.06, 1.0, 0.28), Vector3(-0.6, 1.52, 0), 3])
			out.append([Vector3(0.06, 1.0, 0.28), Vector3(0.6, 1.52, 0), 3])
		P_STAIRS:
			for i in 6:
				out.append([Vector3(2.9, 0.42, 0.52), Vector3(0, 0.21 + float(i) * 0.433, -1.25 + float(i) * 0.5), (i % 2) * 2])
			out.append([Vector3(0.18, 0.2, CELL), Vector3(-1.4, 1.35, 0), 1])
			out.append([Vector3(0.18, 0.2, CELL), Vector3(1.4, 1.35, 0), 1])
	return out

func _mat_for(idx: int) -> StandardMaterial3D:
	match idx:
		1: return frame_mat
		2: return wood_b_mat
		3: return seam_mat
	return wood_mat

func _make_visual(piece: int, as_ghost: bool, ramp_len := 4.0) -> Node3D:
	var root := Node3D.new()
	for part in _visual_boxes(piece, ramp_len):
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = part[0]
		mi.mesh = bm
		mi.position = part[1]
		mi.material_override = ghost_mat if as_ghost else _mat_for(part[2])
		root.add_child(mi)
	return root

func _make_body(piece: int, ramp_len := 4.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.set_meta("build", true)
	body.set_meta("b_piece", piece)
	body.set_meta("hits", 2)
	body.add_child(_make_visual(piece, false, ramp_len))
	for part in _collision_boxes(piece, ramp_len):
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = part[0]
		cs.shape = shape
		cs.position = part[1]
		if part.size() > 2:
			cs.rotation_degrees = part[2]
		body.add_child(cs)
	return body

## Door = a living VINE CURTAIN filling the doorway. It parts to the sides when the
## player approaches (auto-open, no facing direction to get wrong) and regrows shut.
func _make_door() -> StaticBody3D:
	var root := StaticBody3D.new()
	root.collision_layer = 2
	root.collision_mask = 0
	root.set_meta("build", true)
	root.set_meta("b_piece", P_DOOR)
	root.set_meta("hits", 2)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.1, 2.05, 0.16)
	cs.shape = shape
	cs.position = Vector3(0, 1.02, 0)
	root.add_child(cs)
	# two banks of strands hinged at the header, swinging outward to the jambs
	for side in [-1.0, 1.0]:
		var bank := Node3D.new()
		bank.name = "L" if side < 0 else "R"
		bank.position = Vector3(side * 0.52, 2.05, 0)
		root.add_child(bank)
		for i in 4:
			var strand := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.05
			cm.bottom_radius = 0.035
			cm.height = 2.0 - float(i) * 0.12
			strand.mesh = cm
			strand.material_override = vine_mat
			strand.position = Vector3(-side * (0.13 + i * 0.26), -cm.height * 0.5, (0.05 if i % 2 == 0 else -0.05))
			bank.add_child(strand)
			var tip := MeshInstance3D.new()
			var tm := SphereMesh.new()
			tm.radius = 0.055
			tm.height = 0.11
			tip.mesh = tm
			tip.material_override = seam_mat
			tip.position = strand.position + Vector3(0, -cm.height * 0.5, 0)
			bank.add_child(tip)
	return root

## Doors part for the door_user automatically (hysteresis so they don't flutter).
func _process(_delta: float) -> void:
	if door_user == null or not is_instance_valid(door_user):
		return
	for d in doors:
		if not is_instance_valid(d.root):
			continue
		var dist: float = door_user.global_position.distance_to(d.root.global_position + Vector3(0, 1.0, 0))
		if not d.open and dist < 2.3:
			_set_door(d, true)
		elif d.open and dist > 3.0:
			_set_door(d, false)

func _set_door(d: Dictionary, open: bool) -> void:
	d.open = open
	var root: StaticBody3D = d.root
	var col := root.get_child(0) as CollisionShape3D
	col.disabled = open
	# the vines RETRACT UP into the header (banks are anchored there), then regrow down
	var left := root.get_node("L") as Node3D
	var right := root.get_node("R") as Node3D
	var tw := create_tween()
	tw.set_parallel(true)
	var s := 0.06 if open else 1.0
	tw.tween_property(left, "scale:y", s, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(right, "scale:y", s, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

# --- persistence ---------------------------------------------------------------------

func serialize() -> Dictionary:
	var out := { "cells": [], "walls": [], "ramps": [] }
	for key in cells:
		var c = cells[key]
		out.cells.append({ "x": key.x, "l": key.y, "z": key.z, "k": c.kind, "y": c.y_top })
	for key in walls:
		var w = walls[key]
		out.walls.append({ "x": w.cell.x, "l": w.cell.y, "z": w.cell.z, "e": w.edge,
			"t": w.type, "y": w.base_y, "d": w.door != null })
	for key in ramps:
		var r = ramps[key]
		out.ramps.append({ "key": key, "xf": var_to_str((r.node as Node3D).global_transform),
			"len": r.get("len", 4.0), "t": r.get("t", P_RAMP) })
	out["modules"] = []
	for m in placed_modules:
		if is_instance_valid(m.node):
			out.modules.append({ "path": m.path, "xf": var_to_str((m.node as Node3D).global_transform) })
	return out

func deserialize(data: Dictionary) -> void:
	clear_all()
	for c in data.get("cells", []):
		var key := Vector3i(int(c.x), int(c.l), int(c.z))
		var piece := P_FOUNDATION if String(c.k) == "foundation" else P_FLOOR
		var body := _make_body(piece)
		add_child(body)
		var yoff := -0.2 if piece == P_FOUNDATION else -0.15
		body.global_position = Vector3(key.x * CELL, float(c.y) + yoff, key.z * CELL)
		body.set_meta("b_cell", key)
		cells[key] = { "y_top": float(c.y), "node": body, "kind": String(c.k) }
	for w in data.get("walls", []):
		var cellk := Vector3i(int(w.x), int(w.l), int(w.z))
		var edge := int(w.e)
		var wkey := "%d,%d,%d,%d" % [cellk.x, cellk.y, cellk.z, edge]
		var body2 := _make_body(int(w.t))
		add_child(body2)
		var dirv: Vector3 = EDGE_DIRS[edge]
		body2.global_transform = Transform3D(Basis(Vector3.UP, _edge_yaw(edge)),
			Vector3(cellk.x * CELL, float(w.y), cellk.z * CELL) + dirv * (CELL * 0.5))
		body2.set_meta("b_wall", wkey)
		walls[wkey] = { "node": body2, "type": int(w.t), "base_y": float(w.y),
			"cell": cellk, "edge": edge, "door": null, "open": false }
		if bool(w.get("d", false)):
			var door := _make_door()
			add_child(door)
			door.global_transform = body2.global_transform
			walls[wkey].door = door
			doors.append({ "root": door, "open": false, "wkey": wkey })
	for r in data.get("ramps", []):
		var rtype := int(r.get("t", P_RAMP))
		var body3 := _make_body(rtype, float(r.get("len", 4.0)))
		add_child(body3)
		body3.global_transform = str_to_var(String(r.xf))
		body3.set_meta("b_ramp", String(r.key))
		ramps[String(r.key)] = { "node": body3, "t": rtype, "len": float(r.get("len", 4.0)) }
	for m in data.get("modules", []):
		_spawn_module(String(m.path), str_to_var(String(m.xf)))

func clear_all() -> void:
	for key in cells:
		if is_instance_valid(cells[key].node):
			cells[key].node.queue_free()
	for key in walls:
		if is_instance_valid(walls[key].node):
			walls[key].node.queue_free()
		if walls[key].door and is_instance_valid(walls[key].door):
			walls[key].door.queue_free()
	for key in ramps:
		if is_instance_valid(ramps[key].node):
			ramps[key].node.queue_free()
	for m in placed_modules:
		if is_instance_valid(m.node):
			m.node.queue_free()
	cells.clear()
	walls.clear()
	ramps.clear()
	doors.clear()
	placed_modules.clear()
