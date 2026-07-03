extends Node3D
## The player's alien home-tree. Planted as a glowing seed, it grows through
## three stages (seed -> sapling -> full tree) with juicy tweens. When grown,
## a glowing door arch at the base becomes the portal to the tree's interior.

signal fully_grown

var grown := false
var instant := false      # set before add_child to skip the growth animation (save-load)
var seed_node: Node3D
var sapling: Node3D
var tree: Node3D
var door_marker: Node3D   # portal anchor: -Z points outward, toward the approaching player

func _ready() -> void:
	seed_node = _build_seed()
	add_child(seed_node)
	sapling = _build_sapling()
	sapling.visible = false
	add_child(sapling)
	tree = _build_tree()
	tree.visible = false
	add_child(tree)
	door_marker = Node3D.new()
	# same height above the ground as the interior portal sits above its floor,
	# so the view through maps level-to-level instead of dipping underground
	door_marker.position = Vector3(0, 1.5, 1.08)
	door_marker.rotation.y = PI   # door is on the +Z face; -Z of the marker faces outward
	add_child(door_marker)
	if instant:
		seed_node.visible = false
		tree.visible = true
		_add_trunk_collision()
		grown = true
	else:
		_grow()

## World position just in front of the door arch (for proximity checks / exits).
func door_global() -> Vector3:
	return to_global(Vector3(0, 1.0, 2.2))

func _grow() -> void:
	seed_node.scale = Vector3(0.01, 0.01, 0.01)
	var tw := create_tween()
	tw.tween_property(seed_node, "scale", Vector3.ONE, 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.2)
	await tw.finished
	seed_node.visible = false
	sapling.visible = true
	sapling.scale = Vector3(0.2, 0.2, 0.2)
	var tw2 := create_tween()
	tw2.tween_property(sapling, "scale", Vector3.ONE, 1.1).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw2.tween_interval(0.8)
	await tw2.finished
	sapling.visible = false
	tree.visible = true
	tree.scale = Vector3(0.15, 0.15, 0.15)
	var tw3 := create_tween()
	tw3.tween_property(tree, "scale", Vector3.ONE, 2.6).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	await tw3.finished
	_add_trunk_collision()
	grown = true
	fully_grown.emit()

# --- stage builders -----------------------------------------------------------

func _mat(color: Color, rough := 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m

func _glow_mat(color: Color, energy := 2.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m

func _mi(mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO, scl := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot
	mi.scale = scl
	return mi

func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	return s

func _cyl(top_r: float, bot_r: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top_r
	c.bottom_radius = bot_r
	c.height = h
	return c

func _build_seed() -> Node3D:
	var n := Node3D.new()
	n.add_child(_mi(_sphere(0.35), _glow_mat(Color(0.35, 1.0, 0.7), 3.0), Vector3(0, 0.25, 0)))
	return n

func _build_sapling() -> Node3D:
	var n := Node3D.new()
	var bark := _mat(Color(0.30, 0.20, 0.32))
	n.add_child(_mi(_cyl(0.10, 0.16, 1.8), bark, Vector3(0, 0.9, 0), Vector3(0, 0, 5)))
	n.add_child(_mi(_sphere(0.7), _mat(Color(0.15, 0.72, 0.62)), Vector3(0.1, 2.0, 0)))
	n.add_child(_mi(_sphere(0.14), _glow_mat(Color(0.35, 1.0, 0.7)), Vector3(0, 1.2, 0.14)))
	return n

func _build_tree() -> Node3D:
	var n := Node3D.new()
	var bark := _mat(Color(0.28, 0.18, 0.30))
	var canopy_a := _mat(Color(0.14, 0.72, 0.62), 0.8)
	var canopy_b := _mat(Color(0.48, 0.28, 0.68), 0.8)
	var vein := _glow_mat(Color(0.30, 1.0, 0.65), 2.2)

	# twisted trunk: three stacked, offset, tilted segments
	n.add_child(_mi(_cyl(0.72, 1.0, 3.0), bark, Vector3(0, 1.5, 0), Vector3(0, 0, 4)))
	n.add_child(_mi(_cyl(0.52, 0.74, 2.6), bark, Vector3(0.18, 4.1, -0.08), Vector3(3, 25, -6)))
	n.add_child(_mi(_cyl(0.30, 0.54, 2.2), bark, Vector3(0.05, 6.2, 0.10), Vector3(-4, 50, 5)))
	# root flares
	for i in 5:
		var a := float(i) * TAU / 5.0 + 0.3
		var pos := Vector3(cos(a) * 0.95, 0.35, sin(a) * 0.95)
		n.add_child(_mi(_cyl(0.10, 0.24, 1.3), bark, pos, Vector3(0, -rad_to_deg(a) + 90.0, 62)))
	# glowing sap veins up the trunk
	n.add_child(_mi(_cyl(0.03, 0.05, 2.8), vein, Vector3(0.62, 1.6, 0.42), Vector3(4, 0, -7)))
	n.add_child(_mi(_cyl(0.03, 0.05, 2.4), vein, Vector3(-0.55, 2.1, -0.35), Vector3(-5, 0, 8)))
	n.add_child(_mi(_cyl(0.02, 0.04, 2.0), vein, Vector3(0.1, 3.4, -0.62), Vector3(7, 0, 2)))
	# alien canopy: teal mass with purple accents
	n.add_child(_mi(_sphere(2.6), canopy_a, Vector3(0.2, 8.0, 0.0)))
	n.add_child(_mi(_sphere(1.9), canopy_a, Vector3(-1.6, 7.0, 0.9)))
	n.add_child(_mi(_sphere(1.8), canopy_a, Vector3(1.7, 7.2, -0.8)))
	n.add_child(_mi(_sphere(1.3), canopy_b, Vector3(1.1, 8.7, 1.2)))
	n.add_child(_mi(_sphere(1.1), canopy_b, Vector3(-1.3, 8.9, -1.0)))
	# hanging glow bulbs under the canopy
	n.add_child(_mi(_sphere(0.16), _glow_mat(Color(0.35, 1.0, 0.7)), Vector3(1.0, 6.2, 0.6)))
	n.add_child(_mi(_sphere(0.13), _glow_mat(Color(0.75, 0.45, 1.0)), Vector3(-0.9, 6.4, -0.5)))
	n.add_child(_mi(_sphere(0.11), _glow_mat(Color(0.35, 1.0, 0.7)), Vector3(0.2, 5.9, -1.0)))

	# door: glowing arch on the +Z face of the trunk. Lives on visual layer 2 so the
	# portal cameras never render it — from inside you see ONE ring, not two.
	var arch := TorusMesh.new()
	arch.inner_radius = 0.72
	arch.outer_radius = 0.86
	var arch_mi := _mi(arch, _glow_mat(Color(0.30, 1.0, 0.65), 3.0), Vector3(0, 1.5, 1.02), Vector3(90, 0, 0))
	arch_mi.layers = 2
	n.add_child(arch_mi)
	# mossy landing pad under the door so the arch never clips into sloped ground
	var pad := CylinderMesh.new()
	pad.top_radius = 1.6
	pad.bottom_radius = 2.0
	pad.height = 0.55
	var pad_mat := _mat(Color(0.30, 0.48, 0.22))
	n.add_child(_mi(pad, pad_mat, Vector3(0, -0.08, 1.45)))
	return n

## Trunk collision with an open doorway on the +Z face, so the player walks cleanly
## through the door plane (a solid cylinder here made entering feel blocked/janky).
func _add_trunk_collision() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	var parts := [
		[Vector3(-0.95, 2.5, 0.35), Vector3(0.55, 5.0, 1.6)],   # left of door
		[Vector3(0.95, 2.5, 0.35), Vector3(0.55, 5.0, 1.6)],    # right of door
		[Vector3(0.0, 2.5, -0.65), Vector3(2.2, 5.0, 0.9)],     # back of trunk
		[Vector3(0.0, 4.3, 0.5), Vector3(1.6, 1.4, 1.2)],       # above the door
	]
	for p in parts:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = p[1]
		cs.shape = shape
		cs.position = p[0]
		body.add_child(cs)
	add_child(body)
