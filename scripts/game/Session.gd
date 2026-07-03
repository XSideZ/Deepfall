extends Node
## Carries the chosen mode + world between the main menu and the game scene.
## Worlds live in user://worlds/<slug>/ as meta.json + world.json + heights.bin.

var mode := "editor"      # "editor" | "game"
var world_dir := ""       # active world folder (game mode)
var meta := {}            # active world meta

const WORLDS_ROOT := "user://worlds"
const SIZES := { "Small": 256, "Medium": 512, "Large": 768, "Huge": 1536 }

func list_worlds() -> Array:
	var out: Array = []
	var d := DirAccess.open(WORLDS_ROOT)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if d.current_is_dir() and not f.begins_with("."):
			var m := load_meta(WORLDS_ROOT + "/" + f)
			if not m.is_empty():
				m["dir"] = WORLDS_ROOT + "/" + f
				out.append(m)
		f = d.get_next()
	d.list_dir_end()
	out.sort_custom(func(a, b): return float(a.get("last_played", 0)) > float(b.get("last_played", 0)))
	return out

func create_world(wname: String, size_label: String) -> String:
	DirAccess.make_dir_recursive_absolute(WORLDS_ROOT)
	var slug := wname.to_lower().strip_edges().replace(" ", "_")
	slug = slug.substr(0, 24)
	if slug == "":
		slug = "world"
	var dir := WORLDS_ROOT + "/" + slug
	var n := 2
	while DirAccess.dir_exists_absolute(dir):
		dir = WORLDS_ROOT + "/" + slug + str(n)
		n += 1
	DirAccess.make_dir_recursive_absolute(dir)
	var m := {
		"name": wname, "size": size_label, "grid": int(SIZES.get(size_label, 512)),
		"seed": randi(), "water_design": 8.0,
		"day": 1, "terraform": 0.0, "water_on": false,
		"created": Time.get_unix_time_from_system(),
		"last_played": Time.get_unix_time_from_system(),
	}
	save_meta(dir, m)
	return dir

func save_meta(dir: String, m: Dictionary) -> void:
	var f := FileAccess.open(dir + "/meta.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(m, "\t"))
		f.close()

func load_meta(dir: String) -> Dictionary:
	if not FileAccess.file_exists(dir + "/meta.json"):
		return {}
	var f := FileAccess.open(dir + "/meta.json", FileAccess.READ)
	var m = JSON.parse_string(f.get_as_text())
	f.close()
	return m if typeof(m) == TYPE_DICTIONARY else {}

func delete_world(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir():
			d.remove(f)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(dir)
