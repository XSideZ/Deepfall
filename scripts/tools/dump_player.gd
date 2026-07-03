extends SceneTree
## Dump the player GLB structure: skeletons, animations, meshes, sizes.

func _init() -> void:
	var ps: PackedScene = load("res://assets/player/player.glb")
	if ps == null:
		print("LOAD FAILED")
		quit()
		return
	var root := ps.instantiate()
	_walk(root, 0)
	var aabb := _total_aabb(root)
	print("TOTAL AABB pos=", aabb.position, " size=", aabb.size)
	# also check one nature FBX imports with a mesh + material
	var t: PackedScene = load("res://assets/nature/Tree/CommonTree_3.fbx")
	print("TREE FBX: ", "OK" if t != null else "LOAD FAILED")
	if t:
		var tr := t.instantiate()
		_walk(tr, 0)
		tr.free()
	var g: PackedScene = load("res://assets/nature/Grass/Grass_Common_Short.fbx")
	if g:
		var gr := g.instantiate()
		print("GRASS:")
		_walk(gr, 0)
		gr.free()
	root.free()
	quit()

func _walk(n: Node, depth: int) -> void:
	var line := "  ".repeat(depth) + n.get_class() + " '" + n.name + "'"
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh:
			line += "  surfaces=" + str(mi.mesh.get_surface_count()) + " aabb=" + str(mi.mesh.get_aabb().size)
			var m := mi.mesh.surface_get_material(0)
			if m is BaseMaterial3D:
				line += " albedo=" + str((m as BaseMaterial3D).albedo_color) + " tex=" + str((m as BaseMaterial3D).albedo_texture != null)
	if n is AnimationPlayer:
		line += "  anims=" + str((n as AnimationPlayer).get_animation_list())
	if n is Skeleton3D:
		line += "  bones=" + str((n as Skeleton3D).get_bone_count())
	print(line)
	for c in n.get_children():
		_walk(c, depth + 1)

func _total_aabb(n: Node) -> AABB:
	var total := AABB()
	var first := true
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D and (cur as MeshInstance3D).mesh:
			var mi := cur as MeshInstance3D
			var xf: Transform3D = mi.transform
			var p: Node = mi.get_parent()
			while p != null and p is Node3D and p != n:
				xf = (p as Node3D).transform * xf
				p = p.get_parent()
			var ab := xf * mi.mesh.get_aabb()
			if first:
				total = ab
				first = false
			else:
				total = total.merge(ab)
		for c in cur.get_children():
			stack.push_back(c)
	return total
