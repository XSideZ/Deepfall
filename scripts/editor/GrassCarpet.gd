extends MultiMeshInstance3D
## A dense ground-cover carpet: static MultiMesh grid that snaps along with the
## camera; carpet.gdshader positions every clump on the heightmap and hides the
## ones that don't belong (see the shader for the full story).

const ResourceScatterScript := preload("res://scripts/editor/ResourceScatter.gd")
const CarpetShader := preload("res://scripts/editor/carpet.gdshader")

var cell := 0.68
var radius := 54.0
var mat: ShaderMaterial

## mode 0 = land (biome/bloom gated), 1 = sea (submerged only).
## mesh_file picks any clump from the nature pack; cell/radius/height tune the layer.
func setup(mode: int, mesh_file := "Grass_Common_Short.fbx", p_cell := 0.0, p_radius := 0.0, p_height := 0.0) -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if mode == 1:
		cell = 0.95
		radius = 42.0
	if p_cell > 0.0:
		cell = p_cell
	if p_radius > 0.0:
		radius = p_radius

	# clump mesh + its albedo texture from the nature pack
	var nat: Dictionary = ResourceScatterScript.nature_index()
	var path: String = nat.get(mesh_file, "")
	if path == "" or not ResourceLoader.exists(path):
		return
	var ps = load(path)
	if not (ps is PackedScene):
		return
	var inst: Node = (ps as PackedScene).instantiate()
	var found := _first_mesh(inst, Transform3D())
	inst.free()
	if found.is_empty():
		return
	var mesh: Mesh = found.mesh
	var ab: AABB = (found.xf as Transform3D) * mesh.get_aabb()
	var albedo: Texture2D = null
	var m0 := mesh.surface_get_material(0)
	if m0 is ShaderMaterial:   # FloraScatter already swapped it for the sway shader
		albedo = (m0 as ShaderMaterial).get_shader_parameter("albedo_tex")
	elif m0 is BaseMaterial3D:
		albedo = (m0 as BaseMaterial3D).albedo_texture

	mat = ShaderMaterial.new()
	mat.shader = CarpetShader
	mat.set_shader_parameter("albedo_tex", albedo)
	mat.set_shader_parameter("mode", mode)
	mat.set_shader_parameter("cell", cell)
	var target_h := p_height if p_height > 0.0 else (0.5 if mode == 0 else 0.62)
	mat.set_shader_parameter("base_scale", target_h / maxf(ab.size.y, 0.001))
	mat.set_shader_parameter("mesh_h", ab.size.y)
	mat.set_shader_parameter("fade_start", radius * 0.55)
	mat.set_shader_parameter("fade_end", radius * 0.96)
	material_override = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	var n := int(radius * 2.0 / cell)
	mm.instance_count = n * n
	# offsets MUST be integer multiples of cell: half-cell offsets put every instance
	# exactly on the round() boundary in the shader -> cell ids flickered with float
	# jitter while moving and every clump re-rolled its look ("flashing grass")
	var half := n / 2
	for z in n:
		for x in n:
			mm.set_instance_transform(z * n + x,
				Transform3D(Basis(), Vector3(float(x - half) * cell, 0.0, float(z - half) * cell)))
	# instances get repositioned by the shader — keep a culling box that always covers them
	mm.custom_aabb = AABB(Vector3(-radius - 8.0, -300.0, -radius - 8.0),
		Vector3(radius * 2.0 + 16.0, 700.0, radius * 2.0 + 16.0))
	multimesh = mm

## Wire the terrain's height/biome textures (after every generate/load).
func wire(hm: Texture2D, bm: Texture2D, span: float) -> void:
	if mat == null:
		return
	mat.set_shader_parameter("heightmap", hm)
	if bm:
		mat.set_shader_parameter("biome_map", bm)
	mat.set_shader_parameter("terrain_span", span)

## Per-frame: snap the grid with the camera + track the tide.
func follow(cam_pos: Vector3, eff_water: float) -> void:
	position = Vector3(floor(cam_pos.x / cell) * cell, 0.0, floor(cam_pos.z / cell) * cell)
	if mat:
		mat.set_shader_parameter("water_level", eff_water)

func set_bloom(origin: Vector2, front: float) -> void:
	if mat:
		mat.set_shader_parameter("bloom_origin", origin)
		mat.set_shader_parameter("bloom_front", front)

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
