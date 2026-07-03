extends RefCounted
class_name AssetLibrary

## Holds every placeable "prop" the editor knows about:
##   - built-in placeholder primitives (always available so the tool works empty)
##   - meshes/scenes found in res://assets/props/  (drop your own files there)
##   - .glb files imported at runtime via the Import button
##
## Each item is a Dictionary: { id, name, kind, payload }
##   kind = "primitive" -> payload is a String primitive name
##   kind = "packed"    -> payload is a PackedScene
##   kind = "template"  -> payload is a Node3D template we duplicate

const PROPS_DIR := "res://assets/props/"
const SCAN_EXTENSIONS := ["glb", "gltf", "tscn", "scn", "obj", "res"]

var items: Array[Dictionary] = []

func build() -> void:
	items.clear()
	_add_primitives()
	_scan_project_folder()

func get_item(id: String) -> Dictionary:
	for it in items:
		if it.id == id:
			return it
	return {}

func has_item(id: String) -> bool:
	return not get_item(id).is_empty()

# --- instancing -------------------------------------------------------------

func instantiate(id: String) -> Node3D:
	var it := get_item(id)
	if it.is_empty():
		return null
	match it.kind:
		"primitive":
			return _build_primitive(it.payload)
		"packed":
			var n := (it.payload as PackedScene).instantiate()
			return n if n is Node3D else _wrap(n)
		"template":
			return (it.payload as Node3D).duplicate()
	return null

# --- placeholder primitives -------------------------------------------------

func _add_primitives() -> void:
	items.append({ "id": "prim:rock", "name": "Rock", "kind": "primitive", "payload": "rock" })
	items.append({ "id": "prim:boulder", "name": "Boulder", "kind": "primitive", "payload": "boulder" })
	items.append({ "id": "prim:tree", "name": "Tree", "kind": "primitive", "payload": "tree" })
	items.append({ "id": "prim:bush", "name": "Bush", "kind": "primitive", "payload": "bush" })
	items.append({ "id": "prim:crystal", "name": "Crystal", "kind": "primitive", "payload": "crystal" })
	items.append({ "id": "prim:pillar", "name": "Pillar", "kind": "primitive", "payload": "pillar" })

func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	return m

func _mi(mesh: Mesh, color: Color, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(color)
	mi.position = pos
	return mi

func _build_primitive(kind: String) -> Node3D:
	var root := Node3D.new()
	match kind:
		"rock":
			var bm := BoxMesh.new(); bm.size = Vector3(1.4, 0.9, 1.2)
			root.add_child(_mi(bm, Color(0.45, 0.45, 0.48), Vector3(0, 0.45, 0)))
		"boulder":
			var sm := SphereMesh.new(); sm.radius = 1.0; sm.height = 1.6
			root.add_child(_mi(sm, Color(0.38, 0.38, 0.4), Vector3(0, 0.7, 0)))
		"tree":
			var trunk := CylinderMesh.new(); trunk.top_radius = 0.18; trunk.bottom_radius = 0.25; trunk.height = 2.2
			root.add_child(_mi(trunk, Color(0.35, 0.24, 0.14), Vector3(0, 1.1, 0)))
			var canopy := SphereMesh.new(); canopy.radius = 1.2; canopy.height = 2.2
			root.add_child(_mi(canopy, Color(0.2, 0.5, 0.24), Vector3(0, 2.6, 0)))
		"bush":
			var s := SphereMesh.new(); s.radius = 0.7; s.height = 1.0
			root.add_child(_mi(s, Color(0.25, 0.45, 0.22), Vector3(0, 0.45, 0)))
		"crystal":
			var pm := PrismMesh.new(); pm.size = Vector3(0.8, 2.0, 0.8)
			root.add_child(_mi(pm, Color(0.4, 0.7, 0.9), Vector3(0, 1.0, 0)))
		"pillar":
			var c := CylinderMesh.new(); c.top_radius = 0.5; c.bottom_radius = 0.6; c.height = 3.0
			root.add_child(_mi(c, Color(0.6, 0.58, 0.5), Vector3(0, 1.5, 0)))
		_:
			var bm := BoxMesh.new()
			root.add_child(_mi(bm, Color.MAGENTA, Vector3(0, 0.5, 0)))
	return root

func _wrap(n: Node) -> Node3D:
	var root := Node3D.new()
	root.add_child(n)
	return root

# --- project folder scan ----------------------------------------------------

func _scan_project_folder() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(PROPS_DIR)):
		return
	var dir := DirAccess.open(PROPS_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			var ext := fname.get_extension().to_lower()
			if SCAN_EXTENSIONS.has(ext):
				_add_scanned(PROPS_DIR + fname)
		fname = dir.get_next()
	dir.list_dir_end()

func _add_scanned(path: String) -> void:
	var res := load(path)
	if res == null:
		return
	var nice := path.get_file().get_basename()
	if res is PackedScene:
		items.append({ "id": "res:" + path, "name": nice, "kind": "packed", "payload": res })
	elif res is Mesh:
		var root := Node3D.new()
		var mi := MeshInstance3D.new(); mi.mesh = res
		root.add_child(mi)
		items.append({ "id": "res:" + path, "name": nice, "kind": "template", "payload": root })

# --- runtime .glb import ----------------------------------------------------

func import_glb(abs_path: String) -> String:
	var id := "glb:" + abs_path
	if has_item(id):
		return id
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(abs_path, state)
	if err != OK:
		push_warning("Failed to import glb: %s (err %d)" % [abs_path, err])
		return ""
	var scene: Node = doc.generate_scene(state)
	if scene == null:
		return ""
	var template: Node3D = scene if scene is Node3D else _wrap(scene)
	var nice := abs_path.get_file().get_basename()
	items.append({ "id": id, "name": nice, "kind": "template", "payload": template })
	return id
