extends RefCounted
class_name Mesher
## Face-culling voxel mesher. For each solid voxel it emits a quad only for faces
## whose neighbour is air. Queries VoxelWorld.is_solid in WORLD space (so seams
## between chunks cull correctly), but emits vertices in CHUNK-LOCAL space.
##
## Each face's 4 vertices are ordered so cross(v1-v0, v2-v0) points along the
## outward normal, which is the winding Godot treats as front-facing.
## Vertex colour + UVs are emitted now so a texture atlas can drop in later.

# dir = outward normal, verts = 4 corner offsets (unit cube) in correct winding.
const FACES := [
	{"dir": Vector3i(0, 1, 0),  # top +Y
		"verts": [Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)]},
	{"dir": Vector3i(0, -1, 0),  # bottom -Y
		"verts": [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)]},
	{"dir": Vector3i(1, 0, 0),  # right +X
		"verts": [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)]},
	{"dir": Vector3i(-1, 0, 0),  # left -X
		"verts": [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)]},
	{"dir": Vector3i(0, 0, 1),  # front +Z
		"verts": [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)]},
	{"dir": Vector3i(0, 0, -1),  # back -Z
		"verts": [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)]},
]

const _UVS := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]


## Returns an ArrayMesh for the given chunk, or null if the chunk has no visible
## faces (fully solid interior or fully air).
static func build(world, coord: Vector3i) -> ArrayMesh:
	var cs: int = world.CHUNK_SIZE
	var base := coord * cs
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false

	for lz in cs:
		for ly in cs:
			for lx in cs:
				var wx := base.x + lx
				var wy := base.y + ly
				var wz := base.z + lz
				var id: int = world.get_voxel(wx, wy, wz)
				if id == Blocks.AIR:
					continue
				var col: Color = Blocks.color_for(id)
				var local := Vector3(lx, ly, lz)
				for face in FACES:
					var d: Vector3i = face.dir
					if world.is_solid(wx + d.x, wy + d.y, wz + d.z):
						continue
					any = true
					_add_quad(st, local, face.verts, Vector3(d), col, id)

	if not any:
		return null
	return st.commit()


static func _add_quad(st: SurfaceTool, origin: Vector3, verts: Array, n: Vector3, col: Color, id: int) -> void:
	# Winding reversed so the outward side is front-facing in Godot
	# (Godot treats clockwise vertex order as the front face).
	# UV2.x carries the block id so the shader can pick a per-type pattern.
	var id_uv := Vector2(float(id), 0.0)
	for i in [0, 2, 1, 0, 3, 2]:
		st.set_color(col)
		st.set_uv(_UVS[i])
		st.set_uv2(id_uv)
		st.set_normal(n)
		st.add_vertex(origin + verts[i])
