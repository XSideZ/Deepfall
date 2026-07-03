extends RefCounted
## Splits a multi-model GLB into individual variant templates.
##
## Strategy:
##  - If the scene has MULTIPLE MeshInstance3D nodes -> each node is one variant
##    (e.g. coral_reef_set has 8 coral nodes).
##  - If it has ONE MeshInstance3D -> split its geometry into connected components
##    (triangles sharing vertices), then group components whose XZ footprints overlap
##    (a trunk + its leaves = one tree; UV-seam islands rejoin their model).
##    Works for the merged pine_trees sheet and the 3-surface starfish sheet.

static func extract_variants(scene: PackedScene) -> Array:
	var out: Array = []
	if scene == null:
		return out
	var inst: Node = scene.instantiate()
	var found: Array = []   # { mesh: Mesh, xform: Transform3D }
	_collect(inst, Transform3D.IDENTITY, found)
	if found.size() > 1:
		for f in found:
			out.append(_wrap_mesh(f.mesh, f.xform))
	elif found.size() == 1:
		out = _split_mesh(found[0].mesh, found[0].xform)
		if out.is_empty():
			out.append(_wrap_mesh(found[0].mesh, found[0].xform))
	inst.free()
	return out

static func _collect(node: Node, xform: Transform3D, found: Array) -> void:
	var cx := xform
	if node is Node3D:
		cx = xform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		found.append({ "mesh": (node as MeshInstance3D).mesh, "xform": cx })
	for c in node.get_children():
		_collect(c, cx, found)

static func _wrap_mesh(mesh: Mesh, xform: Transform3D) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = xform
	root.add_child(mi)
	return root

# --- single-mesh splitting ----------------------------------------------------

static func _split_mesh(mesh: Mesh, xform: Transform3D) -> Array:
	# budget guard: very dense meshes aren't worth splitting (and would stall startup)
	var total_verts := 0
	for s in mesh.get_surface_count():
		total_verts += mesh.surface_get_array_len(s)
	if total_verts > 40000:
		return []

	var pieces: Array = []   # { arrays, material, aabb }
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			idx = PackedInt32Array(range(verts.size()))
		var mat := mesh.surface_get_material(s)
		pieces.append_array(_surface_components(arrays, verts, idx, mat))

	if pieces.size() <= 1:
		return []

	# CRITICAL: cluster in UPRIGHT space. GLB meshes are often modelled with a different
	# up-axis and stood upright by the node transform (the pine sheet is Z-up raw) —
	# measuring "horizontal" separation on raw coordinates mixes in the vertical axis
	# and no grouping rule can work. Transform every piece's AABB through the node
	# transform first, then Y-up logic below is universally valid.
	for p in pieces:
		p.aabb = xform * (p.aabb as AABB)

	# CONCENTRIC clustering: all pieces of one model stack around a shared vertical
	# axis (a tree's trunk and cone tiers have nearly identical XZ centers), while
	# separate models on the sheet sit a canopy-width apart. Merge two pieces when
	# their XZ centers are within 45% of the LARGER piece's radius — stacked tiers
	# pass easily, neighbouring trees never do. (Anchor- and overlap-based grouping
	# both butchered this asset: fused neighbours or orphaned cones/trunks.)
	var group_parent := PackedInt32Array()
	group_parent.resize(pieces.size())
	for i in pieces.size():
		group_parent[i] = i
	for i in pieces.size():
		for j in range(i + 1, pieces.size()):
			var a: AABB = pieces[i].aabb
			var b: AABB = pieces[j].aabb
			var ra := maxf(a.size.x, a.size.z) * 0.5
			var rb := maxf(b.size.x, b.size.z) * 0.5
			var ca := a.get_center()
			var cb := b.get_center()
			var d := Vector2(ca.x - cb.x, ca.z - cb.z).length()
			# same model = pieces physically touch in 3D (tiers stack, trunk runs up
			# through cones) AND share a rough vertical axis (allows stylised lean);
			# neighbouring models may touch canopies but their axes are far apart
			var margin := maxf(ra, rb) * 0.15
			var ae := a.grow(margin)
			if ae.intersects(b) and d < maxf(ra, rb) * 0.95:
				_union(group_parent, i, j)

	var groups := {}
	for i in pieces.size():
		var r := _find(group_parent, i)
		if not groups.has(r):
			groups[r] = []
		groups[r].append(pieces[i])

	var out: Array = []
	for key in groups.keys():
		var am := ArrayMesh.new()
		var tri_total := 0
		for p in groups[key]:
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, p.arrays)
			if p.material:
				am.surface_set_material(am.get_surface_count() - 1, p.material)
			tri_total += (p.arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		if tri_total >= 8:
			out.append(_wrap_mesh(am, xform))
	return out

## Connected components of one surface. Returns pieces with rebuilt arrays + local AABB.
static func _surface_components(arrays: Array, verts: PackedVector3Array, idx: PackedInt32Array, mat: Material) -> Array:
	var n := verts.size()
	var parent := PackedInt32Array()
	parent.resize(n)
	for i in n:
		parent[i] = i
	var tri_count := idx.size() / 3
	for t in tri_count:
		var a := idx[t * 3]
		_union(parent, a, idx[t * 3 + 1])
		_union(parent, a, idx[t * 3 + 2])

	# bucket triangles by component root
	var comp_tris := {}
	for t in tri_count:
		var r := _find(parent, idx[t * 3])
		if not comp_tris.has(r):
			comp_tris[r] = PackedInt32Array()
		var arr: PackedInt32Array = comp_tris[r]
		arr.append(idx[t * 3]); arr.append(idx[t * 3 + 1]); arr.append(idx[t * 3 + 2])
		comp_tris[r] = arr

	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()

	var out: Array = []
	for key in comp_tris.keys():
		var tris: PackedInt32Array = comp_tris[key]
		var remap := {}
		var nv := PackedVector3Array()
		var nn := PackedVector3Array()
		var nuv := PackedVector2Array()
		var nidx := PackedInt32Array()
		var box := AABB()
		var first := true
		for k in tris.size():
			var old := tris[k]
			if not remap.has(old):
				remap[old] = nv.size()
				nv.append(verts[old])
				if normals.size() == verts.size():
					nn.append(normals[old])
				if uvs.size() == verts.size():
					nuv.append(uvs[old])
				if first:
					box = AABB(verts[old], Vector3.ZERO)
					first = false
				else:
					box = box.expand(verts[old])
			nidx.append(remap[old])
		var na := []
		na.resize(Mesh.ARRAY_MAX)
		na[Mesh.ARRAY_VERTEX] = nv
		if nn.size() == nv.size() and nn.size() > 0:
			na[Mesh.ARRAY_NORMAL] = nn
		if nuv.size() == nv.size() and nuv.size() > 0:
			na[Mesh.ARRAY_TEX_UV] = nuv
		na[Mesh.ARRAY_INDEX] = nidx
		out.append({ "arrays": na, "material": mat, "aabb": box })
	return out

static func _find(parent: PackedInt32Array, i: int) -> int:
	var r := i
	while parent[r] != r:
		r = parent[r]
	while parent[i] != r:
		var next := parent[i]
		parent[i] = r
		i = next
	return r

static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra
