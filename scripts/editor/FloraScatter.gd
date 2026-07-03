extends Node3D
## Decorative flora from the stylized nature pack, scattered as MultiMeshes
## (no collision — pure lushness). Every species is NORMALIZED to an intended
## real-world size (the raw pack sizes are all over the place), grows in noise
## drifts, and sways in the wind via a vertex shader.

const ResourceScatterScript := preload("res://scripts/editor/ResourceScatter.gd")
const SwayShader := preload("res://scripts/editor/flora_sway.gdshader")

# f = filename | n = count on a 512 map | h = target size in metres
# dim = which axis h normalizes ("h" height, "max" biggest dimension)
# s = random variation around h | patch = clump-noise gate | sway = wind strength
const ENTRIES := [
	# ground cover — the lawn layer
	{ "f": "Grass_Common_Short.fbx", "n": 3000, "h": 0.42, "dim": "h", "s": Vector2(0.75, 1.25), "patch": 0.0, "sway": 0.05 },
	{ "f": "Grass_Common_Tall.fbx", "n": 2300, "h": 0.62, "dim": "h", "s": Vector2(0.8, 1.3), "patch": 0.12, "sway": 0.07 },
	{ "f": "Grass_Wispy_Short.fbx", "n": 2300, "h": 0.45, "dim": "h", "s": Vector2(0.75, 1.25), "patch": 0.05, "sway": 0.06 },
	{ "f": "Grass_Wispy_Tall.fbx", "n": 1800, "h": 0.70, "dim": "h", "s": Vector2(0.8, 1.3), "patch": 0.15, "sway": 0.09 },
	{ "f": "Clover_1.fbx", "n": 600, "h": 0.16, "dim": "h", "s": Vector2(0.8, 1.3), "patch": 0.2, "sway": 0.015 },
	{ "f": "Clover_2.fbx", "n": 600, "h": 0.16, "dim": "h", "s": Vector2(0.8, 1.3), "patch": 0.2, "sway": 0.015 },
	# mid layer
	{ "f": "Fern_1.fbx", "n": 420, "h": 0.55, "dim": "h", "s": Vector2(0.8, 1.4), "patch": 0.25, "sway": 0.04 },
	{ "f": "Plant_1.fbx", "n": 280, "h": 0.5, "dim": "h", "s": Vector2(0.8, 1.3), "patch": 0.0, "sway": 0.04 },
	{ "f": "Plant_7.fbx", "n": 280, "h": 0.5, "dim": "h", "s": Vector2(0.8, 1.3), "patch": 0.0, "sway": 0.04 },
	{ "f": "Plant_1_Big.fbx", "n": 100, "h": 0.9, "dim": "h", "s": Vector2(0.85, 1.3), "patch": 0.3, "sway": 0.05 },
	{ "f": "Plant_7_Big.fbx", "n": 100, "h": 0.9, "dim": "h", "s": Vector2(0.85, 1.3), "patch": 0.3, "sway": 0.05 },
	{ "f": "Bush_Common.fbx", "n": 180, "h": 1.1, "dim": "h", "s": Vector2(0.75, 1.5), "patch": 0.0, "sway": 0.02 },
	{ "f": "Bush_Common_Flowers.fbx", "n": 130, "h": 1.0, "dim": "h", "s": Vector2(0.8, 1.4), "patch": 0.1, "sway": 0.02 },
	# colour accents
	{ "f": "Flower_3_Group.fbx", "n": 160, "h": 0.5, "dim": "h", "s": Vector2(0.85, 1.2), "patch": 0.3, "sway": 0.05 },
	{ "f": "Flower_4_Group.fbx", "n": 160, "h": 0.5, "dim": "h", "s": Vector2(0.85, 1.2), "patch": 0.3, "sway": 0.05 },
	{ "f": "Flower_3_Single.fbx", "n": 240, "h": 0.45, "dim": "h", "s": Vector2(0.8, 1.25), "patch": 0.1, "sway": 0.06 },
	{ "f": "Flower_4_Single.fbx", "n": 240, "h": 0.45, "dim": "h", "s": Vector2(0.8, 1.25), "patch": 0.1, "sway": 0.06 },
	{ "f": "Petal_1.fbx", "n": 220, "h": 0.10, "dim": "max", "s": Vector2(0.7, 1.4), "patch": 0.15, "sway": 0.02 },
	{ "f": "Petal_2.fbx", "n": 220, "h": 0.10, "dim": "max", "s": Vector2(0.7, 1.4), "patch": 0.15, "sway": 0.02 },
	{ "f": "Petal_4.fbx", "n": 220, "h": 0.10, "dim": "max", "s": Vector2(0.7, 1.4), "patch": 0.15, "sway": 0.02 },
	{ "f": "Mushroom_Common.fbx", "n": 140, "h": 0.30, "dim": "h", "s": Vector2(0.7, 1.4), "patch": 0.35, "sway": 0.0 },
	{ "f": "Mushroom_Laetiporus.fbx", "n": 60, "h": 0.35, "dim": "h", "s": Vector2(0.7, 1.3), "patch": 0.35, "sway": 0.0 },
	# stones (no wind, obviously)
	{ "f": "Pebble_Round_1.fbx", "n": 150, "h": 0.30, "dim": "max", "s": Vector2(0.6, 1.6), "patch": -1.0, "sway": 0.0 },
	{ "f": "Pebble_Round_2.fbx", "n": 150, "h": 0.30, "dim": "max", "s": Vector2(0.6, 1.6), "patch": -1.0, "sway": 0.0 },
	{ "f": "Pebble_Round_4.fbx", "n": 150, "h": 0.28, "dim": "max", "s": Vector2(0.6, 1.6), "patch": -1.0, "sway": 0.0 },
	{ "f": "Pebble_Square_1.fbx", "n": 130, "h": 0.28, "dim": "max", "s": Vector2(0.6, 1.6), "patch": -1.0, "sway": 0.0 },
	{ "f": "Pebble_Square_3.fbx", "n": 130, "h": 0.28, "dim": "max", "s": Vector2(0.6, 1.6), "patch": -1.0, "sway": 0.0 },
	{ "f": "Pebble_Square_6.fbx", "n": 130, "h": 0.28, "dim": "max", "s": Vector2(0.6, 1.6), "patch": -1.0, "sway": 0.0 },
]

var _layers: Array = []   # { mm, entry, base_xf, norm }
var _sway_mats: Array = []   # flora ShaderMaterials, for the grow-in front uniform
var _noise: FastNoiseLite

func _ready() -> void:
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.035
	_noise.seed = 5711
	var nat: Dictionary = ResourceScatterScript.nature_index()
	for e in ENTRIES:
		var path: String = nat.get(e.f, "")
		if path == "" or not ResourceLoader.exists(path):
			continue
		var ps = load(path)
		if not (ps is PackedScene):
			continue
		var inst: Node = (ps as PackedScene).instantiate()
		var found := _first_mesh(inst, Transform3D())
		if found.is_empty():
			inst.free()
			continue
		ResourceScatterScript.opaque_mesh(found.mesh)
		var mesh: Mesh = found.mesh
		# normalize: raw pack sizes are inconsistent, so scale to the intended size
		var ab: AABB = (found.xf as Transform3D) * mesh.get_aabb()
		var native: float = ab.size.y if String(e.dim) == "h" else ab.size[ab.size.max_axis_index()]
		var norm: float = float(e.h) / maxf(native, 0.001)
		_apply_sway(mesh, float(e.sway), mesh.get_aabb().size.y)
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_layers.append({ "mm": mmi, "entry": e, "base_xf": found.xf, "norm": norm })
		inst.free()
	print("FloraScatter layers: %d" % _layers.size())

## Swap each surface's StandardMaterial for the wind-sway shader (keeps its
## albedo texture + colour). sway 0 still swaps so lighting stays consistent.
func _apply_sway(mesh: Mesh, sway: float, mesh_h: float) -> void:
	for s in mesh.get_surface_count():
		var m := mesh.surface_get_material(s)
		if m is ShaderMaterial:
			continue   # already converted (meshes are shared between runs)
		var sm := ShaderMaterial.new()
		sm.shader = SwayShader
		if m is BaseMaterial3D:
			sm.set_shader_parameter("albedo_tex", (m as BaseMaterial3D).albedo_texture)
			sm.set_shader_parameter("albedo_col", (m as BaseMaterial3D).albedo_color)
		sm.set_shader_parameter("sway", sway)
		sm.set_shader_parameter("mesh_h", maxf(mesh_h, 0.001))
		mesh.surface_set_material(s, sm)
		_sway_mats.append(sm)

## Move the grow-in front: blades within it are grown, blades ahead are scaled to 0.
func set_grow_front(origin: Vector2, front: float) -> void:
	for m in _sway_mats:
		m.set_shader_parameter("bloom_origin", origin)
		m.set_shader_parameter("bloom_front", front)

## Mesh + accumulated transform of the first MeshInstance3D in the scene.
func _first_mesh(n: Node, xf: Transform3D) -> Dictionary:
	var local := xf
	if n is Node3D:
		local = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return { "mesh": (n as MeshInstance3D).mesh, "xf": local }
	for c in n.get_children():
		var r := _first_mesh(c, local)
		if not r.is_empty():
			return r
	return {}

# Flora positions are sampled deterministically over the WHOLE map (stable across
# calls), then only those inside the bloom front are shown. So as bloom_radius grows,
# the same blades progressively appear — the carpet SPREADS instead of re-randomising.
func rebuild(terrain, radius: float, water_level: float, snow_line: float, mult: float,
		bloom_origin := Vector2.ZERO, bloom_radius := 1.0e9) -> void:
	var idx := 0
	for layer in _layers:
		var e: Dictionary = layer.entry
		var mm: MultiMesh = (layer.mm as MultiMeshInstance3D).multimesh
		var base_xf: Transform3D = layer.base_xf
		var norm: float = layer.norm
		var full_want := int(float(e.n) * mult)
		var rng := RandomNumberGenerator.new()
		rng.seed = 40427 + idx * 977
		idx += 1
		var sink: float = float(e.get("sink", 0.04))
		var xforms: Array = []
		for i in full_want:
			var a := rng.randf() * TAU
			var d := radius * sqrt(rng.randf())
			var x := cos(a) * d
			var z := sin(a) * d
			# per-blade random values pulled NOW so positions stay identical every call
			var s: float = norm * rng.randf_range(e.s.x, e.s.y)
			var yaw := rng.randf() * TAU
			# only reveal blades the bloom front has reached (noisy edge)
			var dseed: float = Vector2(x, z).distance_to(bloom_origin) + _noise.get_noise_2d(x * 2.0, z * 2.0) * 14.0
			if dseed > bloom_radius:
				continue
			var h: float = terrain.height_at(x, z)
			if h < water_level + 1.1 or h > snow_line:
				continue
			var dh: float = absf(terrain.height_at(x + 0.9, z) - h) + absf(terrain.height_at(x, z + 0.9) - h)
			if dh > 1.0:
				continue
			if _noise.get_noise_2d(x, z) < float(e.patch) - 0.35:
				continue
			var t := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s)), Vector3(x, h - sink, z))
			xforms.append(t * base_xf)
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])

func clear() -> void:
	for layer in _layers:
		(layer.mm as MultiMeshInstance3D).multimesh.instance_count = 0
