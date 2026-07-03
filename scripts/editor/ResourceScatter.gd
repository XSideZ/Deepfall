extends Node3D
## Auto-scatters resource GLBs across the world.
##  LAND: rocks, trees (split from the merged pine sheet), 3 satellites (2xA + 1xB),
##        1 space station per world on the flattest spot found.
##  SEA (strictly underwater, re-scattered when the water level changes):
##        crystals (glowing), corals (4 GLBs incl. an 8-variant reef set), kelp, starfish (3 variants).
## Spawns are real StaticBody3D props via the editor's _make_placeable, so Delete mode works
## and they can become mineable later. Deterministic seeds -> stable layouts per world+water.

const GlbVariantsScript := preload("res://scripts/editor/GlbVariants.gd")

const ROCK_PATHS := ["res://assets/props/rock_a.glb", "res://assets/props/rock_b.glb", "res://assets/props/rocks_cluster.glb"]
const CORAL_WHOLE_PATHS := ["res://assets/props/coral_a.glb", "res://assets/props/coral_orange.glb", "res://assets/props/coral_enviro.glb"]
const CORAL_SET_PATH := "res://assets/props/coral_reef_set.glb"
const TREES_PATH := "res://assets/props/pine_trees.glb"
const STARFISH_PATH := "res://assets/props/starfish.glb"
const KELP_PATH := "res://assets/props/kelp.glb"
const CRYSTAL_PATH := "res://assets/props/crystal.glb"
const SAT_A_PATH := "res://assets/props/satellite_a.glb"
const SAT_B_PATH := "res://assets/props/satellite_b.glb"

var editor                  # LevelEditor; provides _make_placeable()
var land_root: Node3D
var sea_root: Node3D

# variant template pools (built once in setup)
var rocks: Array = []
var trees: Array = []          # living trees (bloom, away from shores)
var dead_trees: Array = []     # bare/dead trees (barren world)
var palms: Array = []          # shoreline trees (bloom, near water)
var cacti: Array = []          # desert biome (alive even in the barren world)
var blooms: Array = []         # desert bloom — harvestable fruit
var crystals: Array = []
var corals: Array = []
var kelps: Array = []
var starfish: Array = []
var satellites: Array = []   # both designs, mixed by the scatter

func setup(p_editor) -> void:
	editor = p_editor
	land_root = Node3D.new(); land_root.name = "LandResources"; add_child(land_root)
	sea_root = Node3D.new(); sea_root.name = "SeaResources"; add_child(sea_root)

	# nature pack (stylized kit): filename -> res path, folders have random suffixes
	var nat := nature_index()
	for f in ["Rock_Medium_1.fbx", "Rock_Medium_2.fbx", "Rock_Medium_3.fbx"]:
		_add_whole(rocks, nat.get(f, ""), 1.6)
	for f in ["CommonTree_1.fbx", "CommonTree_2.fbx", "CommonTree_3.fbx", "CommonTree_4.fbx", "CommonTree_5.fbx"]:
		_add_whole(trees, nat.get(f, ""), 8.0)
	for f in ["Pine_1.fbx", "Pine_2.fbx", "Pine_3.fbx", "Pine_4.fbx", "Pine_5.fbx"]:
		_add_whole(trees, nat.get(f, ""), 8.5)
	for f in ["TwistedTree_1.fbx", "TwistedTree_2.fbx", "TwistedTree_3.fbx", "TwistedTree_4.fbx", "TwistedTree_5.fbx"]:
		_add_whole(trees, nat.get(f, ""), 7.5)
	for f in ["DeadTree_1.fbx", "DeadTree_2.fbx", "DeadTree_3.fbx", "DeadTree_4.fbx", "DeadTree_5.fbx"]:
		_add_whole(dead_trees, nat.get(f, ""), 6.0)
	# desert + shoreline set (Jay's GLBs): palm sheet splits into its 5 trees
	palms = _variants("res://assets/props/palm_trees.glb", 7.5)
	_add_whole(cacti, "res://assets/props/cactus_a.glb", 2.1)
	_add_whole(cacti, "res://assets/props/cactus_b.glb", 1.7)
	_add_whole(blooms, "res://assets/props/desert_bloom.glb", 0.9)
	_add_whole(crystals, CRYSTAL_PATH, 1.1)
	for c in crystals:
		_add_glow(c)
	for p in CORAL_WHOLE_PATHS:
		_add_whole(corals, p, 1.2)
	corals.append_array(_variants(CORAL_SET_PATH, 1.2))
	_add_whole(kelps, KELP_PATH, 2.2)
	starfish = _variants(STARFISH_PATH, 0.45)
	_add_whole(satellites, SAT_A_PATH, 2.8)
	_add_whole(satellites, SAT_B_PATH, 2.8)
	print("ResourceScatter pools: rocks=%d trees=%d dead=%d palms=%d cacti=%d blooms=%d corals=%d starfish=%d kelp=%d crystals=%d" %
		[rocks.size(), trees.size(), dead_trees.size(), palms.size(), cacti.size(), blooms.size(), corals.size(), starfish.size(), kelps.size(), crystals.size()])

# --- rebuilds ------------------------------------------------------------------

# --- game-mode gradual growth ------------------------------------------------------
# The barren world is scattered ONCE (dead trees + rocks). Living trees are pre-planned
# as invisible "candidates"; as the bloom front sweeps out, each candidate SPROUTS in
# and the dead trees it overtakes wither away. Nothing pops in all at once.
var live_candidates: Array = []   # { pos: Vector3, idx: int, spawned: bool }
var dead_bodies: Array = []       # { body, pos: Vector2 }

# veg_water: the waterline plant bands aim at (game passes the DESIGN sea level so
# shorelines are right once the ocean fills; -999 = use water_level).
func scatter_barren(terrain, radius: float, water_level: float, rock_count: int,
		dead_count: int, sat_count: int, live_count: int, veg_max := 46.0, veg_water := -999.0) -> void:
	for n in land_root.get_children():
		n.queue_free()
	live_candidates.clear()
	dead_bodies.clear()
	var vw := water_level if veg_water < -900.0 else veg_water
	var rng := RandomNumberGenerator.new()
	rng.seed = 913377
	# one shared spacing set for EVERYTHING on land so no two props stack
	var tree_pos: Array = []
	_scatter(terrain, rng, land_root, rocks, rock_count, radius, "Stone", water_level + 1.5, 1e9, 0.6, Vector2(0.7, 1.8), -0.06, Vector2.ZERO, 1e9, 0, tree_pos)
	_scatter(terrain, rng, land_root, satellites, sat_count, radius, "Metal", water_level + 1.5, 1e9, 0.7, Vector2(0.8, 1.2), 0.1, Vector2.ZERO, 1e9, 0, tree_pos)
	# the desert is ALIVE even in the barren world — cacti (graze) + blooms (fruit)
	_scatter(terrain, rng, land_root, cacti, int(dead_count * 0.6), radius, "Biomass", vw + 1.0, veg_max, 0.5, Vector2(0.8, 1.5), -0.08, Vector2.ZERO, 1e9, 0, tree_pos, Vector2(-1.0, 0.30))
	_scatter(terrain, rng, land_root, blooms, int(dead_count * 0.4), radius, "Fruit", vw + 1.0, veg_max, 0.5, Vector2(0.8, 1.3), -0.05, Vector2.ZERO, 1e9, 0, tree_pos, Vector2(-1.0, 0.30), 1)
	# dead trees across the whole barren island; remember each so the bloom can wither it
	if not dead_trees.is_empty():
		var placed := 0
		var attempts := 0
		while placed < dead_count and attempts < dead_count * 20:
			attempts += 1
			var a := rng.randf() * TAU
			var d := radius * sqrt(rng.randf())
			var x := cos(a) * d
			var z := sin(a) * d
			if _too_close(Vector2(x, z), tree_pos, 3.2):
				continue
			if terrain.biome_at(x, z) < 0.28:
				continue   # deserts get cacti, not dead trees
			var h: float = terrain.height_at(x, z)
			if h < water_level + 2.0 or h > veg_max or _slope_at(terrain, x, z) > 0.6:
				continue
			tree_pos.append(Vector2(x, z))
			var body := _spawn(dead_trees[rng.randi_range(0, dead_trees.size() - 1)], "dead" + str(placed), rng, Vector2(0.8, 1.4))
			body.set_meta("resource_type", "Wood")
			body.set_meta("hits", 3)
			_slim_tree_collider(body)
			land_root.add_child(body)
			body.global_position = Vector3(x, h - 0.45, z)
			dead_bodies.append({ "body": body, "pos": Vector2(x, z) })
			placed += 1
	# pre-plan living-tree spots (not spawned yet — the bloom grows them in):
	# normal trees inland + off-desert; PALMS own the shoreline band
	if not trees.is_empty():
		var tries := 0
		while live_candidates.size() < live_count and tries < live_count * 22:
			tries += 1
			var a := rng.randf() * TAU
			var d := radius * sqrt(rng.randf())
			var x := cos(a) * d
			var z := sin(a) * d
			if _too_close(Vector2(x, z), tree_pos, 3.2):
				continue
			if terrain.biome_at(x, z) < 0.28:
				continue
			var h: float = terrain.height_at(x, z)
			if h < vw + 6.0 or h > veg_max or _slope_at(terrain, x, z) > 0.5:
				continue
			tree_pos.append(Vector2(x, z))
			live_candidates.append({ "pos": Vector3(x, h - 0.45, z), "pool": "tree", "idx": rng.randi_range(0, trees.size() - 1), "spawned": false })
	if not palms.is_empty():
		var ptries := 0
		var want_palms := int(live_count * 0.5)
		var planned := 0
		while planned < want_palms and ptries < want_palms * 26:
			ptries += 1
			var a := rng.randf() * TAU
			var d := radius * sqrt(rng.randf())
			var x := cos(a) * d
			var z := sin(a) * d
			if _too_close(Vector2(x, z), tree_pos, 3.4):
				continue
			var h: float = terrain.height_at(x, z)
			if h < vw + 1.2 or h > vw + 6.0 or _slope_at(terrain, x, z) > 0.5:
				continue
			tree_pos.append(Vector2(x, z))
			live_candidates.append({ "pos": Vector3(x, h - 0.35, z), "pool": "palm", "idx": rng.randi_range(0, palms.size() - 1), "spawned": false })
			planned += 1

## Advance the living world out to `radius` from `origin`: sprout any living-tree
## candidate now inside the front, wither any dead tree it has overtaken.
func grow_front(origin: Vector2, radius: float, instant := false) -> void:
	for c in live_candidates:
		if c.spawned:
			continue
		if Vector2(c.pos.x, c.pos.z).distance_to(origin) <= radius:
			c.spawned = true
			_sprout_live_tree(c, instant)
	for d in dead_bodies:
		if d.body != null and is_instance_valid(d.body) and d.pos.distance_to(origin) <= radius:
			var b: Node3D = d.body
			d.body = null
			if instant:
				b.queue_free()
			else:
				var s: Vector3 = b.get_meta("base_scale", b.scale)
				var tw := b.create_tween()
				tw.tween_property(b, "scale", Vector3(s.x, s.y * 0.02, s.z), 0.6).set_ease(Tween.EASE_IN)
				tw.tween_callback(b.queue_free)

func _sprout_live_tree(c: Dictionary, instant: bool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(c.pos.x * 13.0 + c.pos.z * 71.0)
	var pool: Array = palms if String(c.get("pool", "tree")) == "palm" else trees
	var body := _spawn(pool[int(c.idx)], "live", rng, Vector2(0.85, 1.35))
	body.set_meta("resource_type", "Wood")
	body.set_meta("hits", 3)
	_slim_tree_collider(body)
	land_root.add_child(body)
	# respawns/shards may have appeared here since the candidate was planned
	var spot := _clear_spot(c.pos, 2.6)
	if editor and editor.terrain and Vector2(spot.x, spot.z).distance_to(Vector2(c.pos.x, c.pos.z)) > 0.1:
		spot.y = editor.terrain.height_at(spot.x, spot.z) - 0.45
	body.global_position = spot
	var s: Vector3 = body.scale
	body.set_meta("base_scale", s)
	if instant:
		return
	body.scale = s * 0.04
	var tw := body.create_tween()
	tw.tween_property(body, "scale", s, 2.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func rebuild_land(terrain, radius: float, water_level: float, rock_count: int, tree_count: int, sat_count: int,
		dead_count := 0, bloom_center := Vector2.ZERO, bloom_radius := 1.0e9, veg_max := 46.0) -> void:
	for n in land_root.get_children():
		n.queue_free()
	var rng := RandomNumberGenerator.new()
	rng.seed = 913377
	var occ: Array = []   # shared spacing set so nothing stacks
	# rocks: anywhere on land off the beach
	_scatter(terrain, rng, land_root, rocks, rock_count, radius, "Stone", water_level + 1.5, 1e9, 0.6, Vector2(0.7, 1.8), -0.06, Vector2.ZERO, 1e9, 0, occ)
	# living trees: inland + off-desert, inside the bloom; PALMS own the shoreline band
	_scatter(terrain, rng, land_root, trees, tree_count, radius, "Wood", water_level + 6.0, veg_max, 0.5, Vector2(0.8, 1.4), -0.45,
		bloom_center, bloom_radius, 1, occ, Vector2(0.28, 2.0))
	_scatter(terrain, rng, land_root, palms, int(tree_count * 0.5), radius, "Wood", water_level + 1.2, water_level + 6.0, 0.5, Vector2(0.8, 1.3), -0.35,
		bloom_center, bloom_radius, 1, occ)
	# desert: cacti (graze) + desert blooms (fruit, picked in one hit)
	_scatter(terrain, rng, land_root, cacti, int(tree_count * 0.6), radius, "Biomass", water_level + 1.0, veg_max, 0.5, Vector2(0.8, 1.5), -0.08,
		Vector2.ZERO, 1e9, 0, occ, Vector2(-1.0, 0.30))
	_scatter(terrain, rng, land_root, blooms, int(tree_count * 0.4), radius, "Fruit", water_level + 1.0, veg_max, 0.5, Vector2(0.8, 1.3), -0.05,
		Vector2.ZERO, 1e9, 0, occ, Vector2(-1.0, 0.30), 1)
	# dead trees: OUTSIDE the bloom (the barren wastes); tolerate steeper/higher ground
	_scatter(terrain, rng, land_root, dead_trees, dead_count, radius, "Wood", water_level + 2.0, veg_max, 0.6, Vector2(0.8, 1.4), -0.45,
		bloom_center, bloom_radius, 2, occ, Vector2(0.28, 2.0))
	# satellites: crash-landed debris (mixed designs) — the land source of Metal
	_scatter(terrain, rng, land_root, satellites, sat_count, radius, "Metal", water_level + 1.5, 1e9, 0.7, Vector2(0.8, 1.2), 0.1, Vector2.ZERO, 1e9, 0, occ)

func rebuild_sea(terrain, radius: float, water_level: float, crystal_count: int, coral_count: int, starfish_count: int, kelp_count: int) -> void:
	for n in sea_root.get_children():
		n.queue_free()
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	# crystals cluster into glittering COVES in the SHALLOW band — deep water renders
	# opaque (depth fade), so deep coves were invisible from the surface
	var cove_centers: Array = []
	var cove_tries := 0
	while cove_centers.size() < clampi(crystal_count / 8, 2, 6) and cove_tries < 120:
		cove_tries += 1
		var a := rng.randf() * TAU
		var d := radius * sqrt(rng.randf())
		var cx := cos(a) * d
		var cz := sin(a) * d
		var ch: float = terrain.height_at(cx, cz)
		if ch < water_level - 1.5 and ch > water_level - 6.0:
			cove_centers.append(Vector2(cx, cz))
	if cove_centers.is_empty():
		_scatter(terrain, rng, sea_root, crystals, crystal_count, radius, "Crystal", -1e9, water_level - 1.2, 1.0, Vector2(0.7, 1.8), -0.12)
	else:
		var placed := 0
		var attempts := 0
		while placed < crystal_count and attempts < crystal_count * 10:
			attempts += 1
			var cove: Vector2 = cove_centers[rng.randi_range(0, cove_centers.size() - 1)]
			var x := cove.x + rng.randfn(0.0, 4.5)
			var z := cove.y + rng.randfn(0.0, 4.5)
			var h: float = terrain.height_at(x, z)
			if h > water_level - 1.0 or h < water_level - 8.0:
				continue
			var body := _spawn(crystals[0], "crystal", rng, Vector2(0.7, 1.8))
			body.set_meta("resource_type", "Crystal")
			body.set_meta("hits", 3)
			sea_root.add_child(body)
			body.global_position = Vector3(x, h - 0.12, z)
			body.set_meta("base_scale", body.scale)
			placed += 1
	_scatter(terrain, rng, sea_root, corals, coral_count, radius, "Coral", -1e9, water_level - 0.8, 1.0, Vector2(0.6, 1.6), -0.08)
	_scatter(terrain, rng, sea_root, starfish, starfish_count, radius, "Biomass", -1e9, water_level - 0.5, 1.0, Vector2(0.7, 1.3), 0.0)
	_scatter(terrain, rng, sea_root, kelps, kelp_count, radius, "Biomass", -1e9, water_level - 1.8, 1.0, Vector2(0.8, 1.5), -0.1)

## A crystal delivered by a meteor impact — harvestable like any scattered resource.
## Meteor impacts leave glowing RED "Meteorite Shard" resources (a red crystal variant).
func spawn_meteor_shard(pos: Vector3) -> void:
	if crystals.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = randi()
	var body := _spawn(crystals[0], "shard_meteor", rng, Vector2(0.8, 1.5))
	body.set_meta("resource_type", "Shard")
	body.set_meta("hits", 3)
	_tint_red(body)
	land_root.add_child(body)
	body.global_position = _clear_spot(pos, 2.0)
	body.set_meta("base_scale", body.scale)
	# pop out of the impact
	var s: Vector3 = body.scale
	body.scale = Vector3(0.05, 0.05, 0.05)
	var tw := body.create_tween()
	tw.tween_property(body, "scale", s, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## Recolour a spawned prop's meshes to glowing red (meteorite shards).
func _tint_red(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			for i in mi.mesh.get_surface_count():
				var red := StandardMaterial3D.new()
				red.albedo_color = Color(0.85, 0.16, 0.12)
				red.emission_enabled = true
				red.emission = Color(1.0, 0.22, 0.12)
				red.emission_energy_multiplier = 1.8
				red.roughness = 0.35
				mi.set_surface_override_material(i, red)
	for c in node.get_children():
		_tint_red(c)

## Spawn a single resource at a spot (used by the timed-respawn system). The type
## picks which pool; it pops out of the ground with a little grow tween.
func respawn_one(pos: Vector3, resource: String) -> void:
	var pool: Array = rocks
	match resource:
		"Wood": pool = trees if not trees.is_empty() else dead_trees
		"Stone": pool = rocks
		"Crystal", "Shard": pool = crystals
		"Coral": pool = corals
		"Fruit": pool = blooms
		"Biomass":
			# on land biomass regrows as cacti; underwater as kelp/starfish
			var in_desert: bool = editor and editor.terrain and pos.y > editor.water_level
			pool = cacti if in_desert and not cacti.is_empty() else (kelps if not kelps.is_empty() else starfish)
		"Metal": pool = satellites
	if pool.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = randi()
	var body := _spawn(pool[rng.randi_range(0, pool.size() - 1)], resource.to_lower() + "_re", rng, Vector2(0.8, 1.4))
	body.set_meta("resource_type", resource)
	body.set_meta("hits", 1 if resource == "Fruit" else 3)
	if resource == "Wood":
		_slim_tree_collider(body)
	land_root.add_child(body)
	# dodge whatever now stands near the old spot (no more respawn-on-top stacking)
	var spot := _clear_spot(pos, 2.4)
	if editor and editor.terrain and Vector2(spot.x, spot.z).distance_to(Vector2(pos.x, pos.z)) > 0.1:
		spot.y = editor.terrain.height_at(spot.x, spot.z) + (pos.y - editor.terrain.height_at(pos.x, pos.z))
	body.global_position = spot
	var s: Vector3 = body.scale
	body.set_meta("base_scale", s)
	body.scale = s * 0.05
	var tw := body.create_tween()
	tw.tween_property(body, "scale", s, 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func clear() -> void:
	for n in land_root.get_children():
		n.queue_free()
	for n in sea_root.get_children():
		n.queue_free()

func _exit_tree() -> void:
	# template pools live outside the scene tree, so they must be freed manually
	for pool in [rocks, trees, dead_trees, palms, cacti, blooms, crystals, corals, kelps, starfish, satellites]:
		for t in pool:
			if is_instance_valid(t):
				t.free()

# --- core scatter ----------------------------------------------------------------

# bloom_mode: 0 ignore, 1 INSIDE the bloom only, 2 OUTSIDE the bloom only.
# occupied: a SHARED position list so different resource types don't stack on each other.
# biome_rng: only place where terrain.biome_at falls in this range (desert <0.3, etc).
func _scatter(terrain, rng: RandomNumberGenerator, parent: Node3D, pool: Array, count: int, radius: float,
		resource: String, min_h: float, max_h: float, max_slope: float, scale_range: Vector2, sink: float,
		bloom_center := Vector2.ZERO, bloom_radius := 1.0e9, bloom_mode := 0, occupied = null,
		biome_rng := Vector2(-1.0, 2.0), hits := 3) -> void:
	if pool.is_empty() or count <= 0:
		return
	var min_space := 3.2 if resource == "Wood" else 2.2   # keep resources from stacking
	var placed_pos: Array = occupied if occupied != null else []
	var placed := 0
	var attempts := 0
	while placed < count and attempts < count * 20:
		attempts += 1
		var a := rng.randf() * TAU
		var d := radius * sqrt(rng.randf())
		var x := cos(a) * d
		var z := sin(a) * d
		if bloom_mode != 0:
			var dseed: float = Vector2(x, z).distance_to(bloom_center)
			if bloom_mode == 1 and dseed > bloom_radius:
				continue
			if bloom_mode == 2 and dseed < bloom_radius:
				continue
		var bio: float = terrain.biome_at(x, z)
		if bio < biome_rng.x or bio > biome_rng.y:
			continue
		if _too_close(Vector2(x, z), placed_pos, min_space):
			continue
		var h: float = terrain.height_at(x, z)
		if h < min_h or h > max_h:
			continue
		if _slope_at(terrain, x, z) > max_slope:
			continue
		placed_pos.append(Vector2(x, z))
		var idx := rng.randi_range(0, pool.size() - 1)
		var body := _spawn(pool[idx], resource.to_lower() + str(idx), rng, scale_range)
		body.set_meta("resource_type", resource)
		body.set_meta("hits", hits)
		if resource == "Wood":
			_slim_tree_collider(body)   # collide with the TRUNK, not the whole canopy
		parent.add_child(body)
		# rest on the LOWEST nearby ground so nothing floats on slopes
		var hmin: float = h
		hmin = minf(hmin, terrain.height_at(x - 1.2, z))
		hmin = minf(hmin, terrain.height_at(x + 1.2, z))
		hmin = minf(hmin, terrain.height_at(x, z - 1.2))
		hmin = minf(hmin, terrain.height_at(x, z + 1.2))
		body.global_position = Vector3(x, hmin + sink, z)
		placed += 1

# --- template building -------------------------------------------------------------

## Map every FBX in assets/nature (any subfolder) by filename.
static func nature_index() -> Dictionary:
	var out := {}
	var stack: Array = ["res://assets/nature"]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var d := DirAccess.open(dir_path)
		if d == null:
			continue
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if d.current_is_dir() and not f.begins_with("."):
				stack.push_back(dir_path + "/" + f)
			elif f.get_extension().to_lower() == "fbx":
				out[f] = dir_path + "/" + f
			f = d.get_next()
		d.list_dir_end()
	return out

func _add_whole(pool: Array, path: String, target_size: float) -> void:
	if path == "" or not ResourceLoader.exists(path):
		return
	var s = load(path)
	if s is PackedScene:
		var model: Node3D = (s as PackedScene).instantiate()
		force_opaque(model)
		var holder := Node3D.new()
		holder.add_child(model)
		_autofit(model, target_size)
		pool.append(holder)

## Imported vegetation often arrives with TRANSPARENT leaf materials. Transparent
## geometry skips the depth buffer, so the water plane (render_priority 2) painted
## straight over trees/hills. Stylized-kit textures are solid — force them opaque.
static func force_opaque(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh:
			opaque_mesh(mi.mesh)
		for i in mi.get_surface_override_material_count():
			var mo := mi.get_surface_override_material(i)
			if mo is BaseMaterial3D:
				(mo as BaseMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	for c in n.get_children():
		force_opaque(c)

static func opaque_mesh(mesh: Mesh) -> void:
	for s in mesh.get_surface_count():
		var m := mesh.surface_get_material(s)
		if m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			(m as BaseMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

func _variants(path: String, target_size: float) -> Array:
	var out: Array = []
	if not ResourceLoader.exists(path):
		return out
	var s = load(path)
	if not (s is PackedScene):
		return out
	var extracted: Array = GlbVariantsScript.extract_variants(s)
	for v in extracted:
		force_opaque(v)
	# scale each variant RELATIVE to the tallest so the pack keeps its natural
	# proportions (a small bush stays small instead of being blown up to tree size);
	# only true debris stubs are dropped
	var max_h := 0.0
	var heights: Array = []
	for v in extracted:
		var h: float = _node_aabb(v, Transform3D.IDENTITY).size.y
		heights.append(h)
		max_h = maxf(max_h, h)
	for i in extracted.size():
		var v: Node3D = extracted[i]
		if extracted.size() > 1 and heights[i] < max_h * 0.18:
			v.free()
			continue
		var holder := Node3D.new()
		holder.add_child(v)
		var rel: float = clampf(heights[i] / max_h, 0.2, 1.0)
		_autofit(v, target_size * rel)
		out.append(holder)
	return out

func _spawn(template: Node3D, id: String, rng: RandomNumberGenerator, scale_range: Vector2) -> StaticBody3D:
	var visual: Node3D = template.duplicate()
	var body: StaticBody3D = editor._make_placeable(visual, "scatter:" + id)
	body.rotation.y = rng.randf() * TAU
	var s := rng.randf_range(scale_range.x, scale_range.y)
	body.scale = Vector3(s, s, s)
	body.set_meta("base_scale", body.scale)   # hit-punch tweens restore to this
	return body

## Trees fit their collision box to the full AABB — canopy included — which made
## invisible walls. Shrink to a trunk-sized column (keep full height for mote hits).
func _slim_tree_collider(body: StaticBody3D) -> void:
	for c in body.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
			var cs := c as CollisionShape3D
			var b := cs.shape as BoxShape3D
			# ~half the canopy width, forgiving (min 1.1) so bare/leaning trees are still
			# easy to hit, but capped (max 1.6) so it's not a full-canopy invisible wall.
			var slim := BoxShape3D.new()
			slim.size = Vector3(clampf(b.size.x * 0.5, 1.1, 1.6), b.size.y, clampf(b.size.z * 0.5, 1.1, 1.6))
			cs.shape = slim
			# GROUND the box (bottom at y=0) and pull it halfway toward the body origin:
			# the fitted AABB centre sits up in the canopy, so the TRUNK — at ground
			# level, near the origin — wasn't registering hits on dead/leaning trees.
			cs.position = Vector3(cs.position.x * 0.5, slim.size.y * 0.5, cs.position.z * 0.5)

func _too_close(p: Vector2, placed: Array, d: float) -> bool:
	var d2 := d * d
	for q in placed:
		if q.distance_squared_to(p) < d2:
			return true
	return false

## Runtime spawns (respawns, meteor shards, sprouting trees) land AFTER the initial
## scatter, so they must dodge whatever exists NOW. Nudges outward until clear.
func _clear_spot(pos: Vector3, min_d: float) -> Vector3:
	var existing: Array = []
	var p2 := Vector2(pos.x, pos.z)
	for n in land_root.get_children():
		if n is Node3D and not n.is_queued_for_deletion():
			var q := Vector2((n as Node3D).global_position.x, (n as Node3D).global_position.z)
			if q.distance_to(p2) < min_d * 4.0:
				existing.append(q)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(pos.x * 37.0 + pos.z * 91.0) + randi() % 1000
	var try_p := p2
	for i in 10:
		if not _too_close(try_p, existing, min_d):
			break
		var a := rng.randf() * TAU
		try_p = p2 + Vector2(cos(a), sin(a)) * (min_d + rng.randf() * min_d * 2.0)
	return Vector3(try_p.x, pos.y, try_p.y)

func _slope_at(terrain, x: float, z: float) -> float:
	var e := 1.5
	var hx: float = terrain.height_at(x + e, z) - terrain.height_at(x - e, z)
	var hz: float = terrain.height_at(x, z + e) - terrain.height_at(x, z - e)
	return Vector2(hx, hz).length() / (2.0 * e)

func _autofit(model: Node3D, target: float) -> void:
	var box := _node_aabb(model, Transform3D.IDENTITY)
	var m: float = max(box.size.x, max(box.size.y, box.size.z))
	if m > 0.0001:
		var s := target / m
		model.scale = Vector3(s, s, s)
		# rest the model's AABB bottom on the origin so it sits on the ground
		model.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)

func _node_aabb(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var has := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out = xform * (node as MeshInstance3D).mesh.get_aabb()
		has = true
	for c in node.get_children():
		var cx := xform
		if c is Node3D:
			cx = xform * (c as Node3D).transform
		var ca := _node_aabb(c, cx)
		if ca.size.length() > 0.0:
			out = out.merge(ca) if has else ca
			has = true
	return out

## Subtle emissive glow for crystals whose materials have none.
func _add_glow(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			for i in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(i)
				if mat is StandardMaterial3D and not (mat as StandardMaterial3D).emission_enabled:
					var dup := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
					dup.emission_enabled = true
					dup.emission = dup.albedo_color * 0.8
					dup.emission_energy_multiplier = 1.1
					mi.set_surface_override_material(i, dup)
	for c in node.get_children():
		_add_glow(c)
