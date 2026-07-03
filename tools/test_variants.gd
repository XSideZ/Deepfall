extends SceneTree
const GV := preload("res://scripts/editor/GlbVariants.gd")
func _init() -> void:
	for p in ["pine_trees", "coral_reef_set", "starfish"]:
		var v: Array = GV.extract_variants(load("res://assets/props/%s.glb" % p))
		var line: String = str(p) + " -> " + str(v.size()) + " variants | heights: "
		for n in v:
			line += "%.2f " % _aabb(n, Transform3D.IDENTITY).size.y
			n.free()
		print(line)
	quit()
static func _aabb(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var has := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out = xform * (node as MeshInstance3D).mesh.get_aabb()
		has = true
	for c in node.get_children():
		var cx := xform
		if c is Node3D:
			cx = xform * (c as Node3D).transform
		var ca := _aabb(c, cx)
		if ca.size.length() > 0.0:
			out = out.merge(ca) if has else ca
			has = true
	return out
