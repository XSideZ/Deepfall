extends Node3D
## Scatters grass-blade tufts across the grassy parts of the terrain using a MultiMesh
## (one draw call for hundreds of thousands of blades). Rebuilt on demand.

var mmi: MultiMeshInstance3D
var mm: MultiMesh

func _ready() -> void:
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _make_tuft()
	mmi = MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/editor/grass.gdshader")
	mmi.material_override = mat
	# grass covers a lot of ground -> generous draw distance
	mmi.custom_aabb = AABB(Vector3(-2000, -100, -2000), Vector3(4000, 400, 4000))
	add_child(mmi)

## Build a small tuft: 3 crossed tapered blades, ~0.7 m tall, UV.y 0=base 1=tip.
func _make_tuft() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_w := 0.055
	var top_w := 0.014
	var height := 0.52
	for b in 3:
		var ang := float(b) * (PI / 3.0) + 0.4
		var basis := Basis(Vector3.UP, ang)
		var bl := basis * Vector3(-half_w, 0.0, 0.0)
		var br := basis * Vector3(half_w, 0.0, 0.0)
		var tr := basis * Vector3(top_w, height, 0.0)
		var tl := basis * Vector3(-top_w, height, 0.0)
		var nrm := basis * Vector3(0.0, 0.4, 1.0)
		nrm = nrm.normalized()
		# tri 1
		st.set_normal(nrm); st.set_uv(Vector2(0, 0)); st.add_vertex(bl)
		st.set_normal(nrm); st.set_uv(Vector2(1, 0)); st.add_vertex(br)
		st.set_normal(nrm); st.set_uv(Vector2(1, 1)); st.add_vertex(tr)
		# tri 2
		st.set_normal(nrm); st.set_uv(Vector2(0, 0)); st.add_vertex(bl)
		st.set_normal(nrm); st.set_uv(Vector2(1, 1)); st.add_vertex(tr)
		st.set_normal(nrm); st.set_uv(Vector2(0, 1)); st.add_vertex(tl)
	return st.commit()

## Repopulate. `terrain` must expose height_at(x,z); grass only grows on flat ground
## above the water line and below the snow line.
func rebuild(terrain, radius: float, water_level: float, snow_level: float, density: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260701
	# clumps grass into patches (bare ground between shows the 2D grass texture, Planet-Crafter style)
	var patch := FastNoiseLite.new()
	patch.noise_type = FastNoiseLite.TYPE_SIMPLEX
	patch.frequency = 0.03
	patch.seed = 4242
	var xforms: Array[Transform3D] = []
	var e := 1.5
	for i in density:
		var a := rng.randf() * TAU
		var d := radius * sqrt(rng.randf())
		var x := cos(a) * d
		var z := sin(a) * d
		var h: float = terrain.height_at(x, z)
		# start grass above the beach band (sand reaches ~water_level + 4)
		if h < water_level + 4.0 or h > snow_level - 4.0:
			continue
		var hx: float = terrain.height_at(x + e, z) - terrain.height_at(x - e, z)
		var hz: float = terrain.height_at(x, z + e) - terrain.height_at(x, z - e)
		var slope := Vector2(hx, hz).length() / (2.0 * e)
		if slope > 0.55:
			continue
		# only grow inside grassy patches, leaving bare ground between
		if patch.get_noise_2d(x, z) < 0.05:
			continue
		var yaw := rng.randf() * TAU
		var sc := rng.randf_range(0.7, 1.4)
		var bx := Basis(Vector3.UP, yaw).scaled(Vector3(sc, sc, sc))
		xforms.append(Transform3D(bx, Vector3(x, h, z)))

	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])

func clear() -> void:
	mm.instance_count = 0
