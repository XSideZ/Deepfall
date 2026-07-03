extends SceneTree
## Debug tool: prints the node structure of multi-variant GLBs so we know how to split them.

const PATHS := [
	"res://assets/props/pine_trees.glb",
	"res://assets/props/coral_reef_set.glb",
	"res://assets/props/starfish.glb",
	"res://assets/props/coral_enviro.glb",
	"res://assets/props/satellite_a.glb",
	"res://assets/props/satellite_b.glb",
]

func _init() -> void:
	for p in PATHS:
		print("=== ", p)
		if not ResourceLoader.exists(p):
			print("  MISSING")
			continue
		var scene = load(p)
		if scene is PackedScene:
			var inst: Node = scene.instantiate()
			_dump(inst, 1)
			inst.free()
	quit()

func _dump(n: Node, depth: int) -> void:
	var info := n.get_class()
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		var mi := n as MeshInstance3D
		var aabb := mi.mesh.get_aabb()
		info += " surfaces=%d size=%.1fx%.1fx%.1f" % [mi.mesh.get_surface_count(), aabb.size.x, aabb.size.y, aabb.size.z]
	print("  ".repeat(depth), n.name, " [", info, "]")
	if depth < 4:
		for c in n.get_children():
			_dump(c, depth + 1)
