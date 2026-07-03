extends StaticBody3D
class_name Chunk
## One CHUNK_SIZE^3 region of the world. Holds the visible mesh plus a matching
## collision shape, both rebuilt on demand from the shared VoxelWorld data.

# Shared across all chunks — the cartoony block shader reads everything it needs from
# the mesh (vertex colour + UV + UV2 block id), so one material instance is enough.
static var _shared_material: ShaderMaterial

var world: VoxelWorld
var coord: Vector3i

var _mesh_instance: MeshInstance3D
var _collision: CollisionShape3D


func setup(w: VoxelWorld, c: Vector3i) -> void:
	world = w
	coord = c
	position = Vector3(c) * float(VoxelWorld.CHUNK_SIZE)

	_mesh_instance = MeshInstance3D.new()
	add_child(_mesh_instance)

	_collision = CollisionShape3D.new()
	add_child(_collision)

	if _shared_material == null:
		_shared_material = ShaderMaterial.new()
		_shared_material.shader = load("res://shaders/block.gdshader")


func build_mesh() -> void:
	var mesh := Mesher.build(world, coord)
	_mesh_instance.mesh = mesh

	if mesh == null:
		_collision.shape = null
		return

	mesh.surface_set_material(0, _shared_material)

	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(mesh.get_faces())
	_collision.shape = shape
