extends Node
## The DeepFall game loop. You crash-land on a DEAD island. You plant a Heart Seed,
## then SPREAD its bloom outward stage by stage by feeding it resources you gather.
## Each spread greens a wider patch of the island (revealing richer resources) and,
## days in, brings weather: higher bloom -> more rain -> the ocean slowly fills.
##
## Progression is DELIBERATE (spend at the seed), never automatic — breaking things
## just gives resources. Water is driven ONLY by rain, never by the index directly.

var editor                       # LevelEditor
var day := 1
var _phase_prev := 0.0

# --- the bloom (spatial, spreads from the seed) ---
var planted := false
var bloom_origin := Vector2.ZERO   # world xz of the Heart Seed
var bloom_stage := 0               # 0 = not planted; grows on each spread
var bloom_radius := 0.0
var _bloom_r_display := 0.0        # the visible bloom FRONT, crawls toward bloom_radius
var _last_grown_r := 0.0           # radius the flora/trees were last grown to
const FRONT_SPEED := 0.55          # metres/sec the living front spreads (deliberately slow + rewarding)
const GROW_STEP := 2.0             # re-check tree sprouts every this many metres of front
const MAX_STAGE := 8
var _base_radius := 30.0
var _grow_radius := 20.0

# --- water: driven by rain accumulation, independent of the index ---
const WATER_HIDDEN := -20.0
const RAIN_RISE := 0.07            # metres/sec the tide climbs while raining
var design_water_y := 8.0
var _water_low := WATER_HIDDEN     # persistent floor the tide recedes to (ratchets up)

# --- weather gating ---
const RAIN_FIRST_STAGE := 2        # no weather until the world has some life
var _rain_cd := 80.0

const INTERACT_DIST := 6.0
const PICKUP_DIST := 3.6

# findable Heart Seeds: 1 (Small) .. 4 (Huge). Take one and the rest vanish.
var has_seed := false
var _seeds: Array = []   # Node3D beacons

var hud: Control
var day_label: Label
var tf_fill: ColorRect
var stage_label: Label
var cost_label: Label

func setup(ed) -> void:
	editor = ed
	day = int(Session.meta.get("day", 1))
	has_seed = bool(Session.meta.get("has_seed", false))
	bloom_stage = int(Session.meta.get("bloom_stage", 0))
	bloom_radius = float(Session.meta.get("bloom_radius", 0.0))
	var bo = Session.meta.get("bloom_origin", null)
	if bo is Array and bo.size() == 2:
		bloom_origin = Vector2(bo[0], bo[1])
		planted = true
	planted = planted or bool(Session.meta.get("planted", false))
	design_water_y = float(Session.meta.get("water_design", 8.0))
	_water_low = float(Session.meta.get("water_low", WATER_HIDDEN))
	_bloom_r_display = bloom_radius

	var grid := int(Session.meta.get("grid", 512))
	_base_radius = 26.0 + grid * 0.02
	_grow_radius = 16.0 + grid * 0.03

	await editor.generate_world_for_game(int(Session.meta.get("seed", 12345)), grid, WATER_HIDDEN)
	# fresh worlds begin at daybreak so you get a full day of light
	if not FileAccess.file_exists(Session.world_dir + "/world.json") or bloom_stage == 0:
		editor.day_phase = 0.05
	editor.game_denser_fog()

	_build_hud()
	# resuming a grown world -> materialise it instantly; a fresh world stays barren
	# until the player finds a seed, plants it, and the front crawls out
	if planted and bloom_radius > 0.0:
		_bloom_r_display = bloom_radius
		_last_grown_r = bloom_radius
		editor.set_bloom_field(bloom_origin, bloom_radius, 1.0)
		editor.plant_flora_field(bloom_origin, bloom_radius)
		editor.set_flora_front(bloom_origin, bloom_radius)
		editor.grow_trees_front(bloom_origin, bloom_radius, true)
	else:
		_bloom_r_display = 0.0
		_last_grown_r = 0.0
		editor.set_bloom_field(bloom_origin, 0.0, 1.0)
		editor.set_flora_front(bloom_origin, 0.0)   # carpet hidden until the seed blooms
		_spawn_alien_seeds()
	editor.set_game_water(editor.water_level)  # keep whatever was loaded
	editor.spawn_player_for_game()
	if editor.rain_timer:
		editor.rain_timer.stop()

func _process(delta: float) -> void:
	if editor == null or not editor.testing:
		return
	# day counter (a new day each sunrise)
	var phase: float = editor.day_phase
	if phase < _phase_prev - 0.5:
		day += 1
		editor.flash_msg("Day %d" % day)
		_save()
	_phase_prev = phase

	# the living front crawls outward — ground greens, grass/flowers grow up out of the
	# soil, trees sprout, dead trees wither — all gradually, never in a single pop
	if _bloom_r_display < bloom_radius - 0.05:
		_bloom_r_display = move_toward(_bloom_r_display, bloom_radius, FRONT_SPEED * delta)
		editor.set_bloom_field(bloom_origin, _bloom_r_display, 1.0)     # ground greens
		editor.set_flora_front(bloom_origin, _bloom_r_display)          # grass rises
		if _bloom_r_display - _last_grown_r >= GROW_STEP or _bloom_r_display >= bloom_radius - 0.05:
			_last_grown_r = _bloom_r_display
			editor.grow_trees_front(bloom_origin, _bloom_r_display, false)

	_update_water(delta)
	_update_rain(delta)
	_update_bloom_fog()
	_refresh_hud()

## Clear air within the living bloom, thick mist out in the barren wastes.
func _update_bloom_fog() -> void:
	if editor.player == null:
		return
	var pd: float = Vector2(editor.player.global_position.x, editor.player.global_position.z).distance_to(bloom_origin)
	var inside: float = clampf((_bloom_r_display - pd) / maxf(_bloom_r_display * 0.6, 14.0), 0.0, 1.0)
	editor.game_set_bloom_fog(lerpf(0.010, 0.0012, inside))

## Terraform % = how much of the ISLAND the bloom actually covers (area fraction).
## On big maps a few stages cover only a sliver, so the HUD reads honestly.
func terraform() -> float:
	if not planted:
		return 0.0
	var island_r: float = maxf(float(Session.meta.get("grid", 512)) * 0.42, 1.0)
	return clampf((bloom_radius * bloom_radius) / (island_r * island_r), 0.0, 1.0)

## Stage-based progress (0..1) — drives weather so gameplay isn't gated by map size.
func _stage_progress() -> float:
	return clampf(float(bloom_stage) / float(MAX_STAGE), 0.0, 1.0)

# --- planting + spreading ----------------------------------------------------------

## Called by the editor when the player plants their home/heart seed.
func on_planted(pos: Vector3) -> void:
	planted = true
	bloom_origin = Vector2(pos.x, pos.z)
	bloom_stage = 1
	bloom_radius = _base_radius
	# the front starts at the seed and crawls out slowly over the coming minute+
	_bloom_r_display = 0.0
	_last_grown_r = 0.0
	editor.plant_flora_field(bloom_origin, bloom_radius)
	editor.set_flora_front(bloom_origin, 0.0)
	editor.flash_msg("The Heart Seed takes hold — life begins to spread")
	_save()

func _spread_cost(stage: int) -> Dictionary:
	var c := { "Wood": 6 + stage * 4, "Stone": 4 + stage * 3 }
	if stage >= 3:
		c["Shard"] = (stage - 2) * 2
	if stage >= 5:
		c["Biomass"] = (stage - 4) * 3
	return c

func _can_afford(cost: Dictionary) -> bool:
	for t in cost:
		if editor._type_total(t) < int(cost[t]):
			return false
	return true

# --- findable Heart Seeds ----------------------------------------------------------

func _seed_count() -> int:
	return clampi(int(round(float(Session.meta.get("grid", 512)) / 256.0)), 1, 4)

func _spawn_alien_seeds() -> void:
	if has_seed or planted:
		return
	var n := _seed_count()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(Session.meta.get("seed", 1)) ^ 0x5EED
	var map_r: float = float(Session.meta.get("grid", 512)) * 0.42
	var placed := 0
	var tries := 0
	while placed < n and tries < 400:
		tries += 1
		var a := rng.randf() * TAU
		var d := map_r * sqrt(rng.randf())
		var x := cos(a) * d
		var z := sin(a) * d
		var h: float = editor.terrain.height_at(x, z)
		if h < 2.0:
			continue
		var ok := true
		for s in _seeds:
			if Vector2(x, z).distance_to(Vector2(s.global_position.x, s.global_position.z)) < map_r * 0.5:
				ok = false
				break
		if not ok:
			continue
		_seeds.append(_make_seed_beacon(Vector3(x, h + 0.6, z)))
		placed += 1
	editor.flash_msg("A Heart Seed pulses somewhere on this island — find it")

## Glowing floating orb + a tall light beam so it can be spotted from far off.
func _make_seed_beacon(pos: Vector3) -> Node3D:
	var root := Node3D.new()
	editor.add_child(root)
	root.global_position = pos

	var orb := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.4
	sm.height = 0.8
	orb.mesh = sm
	var om := StandardMaterial3D.new()
	om.albedo_color = Color(0.55, 1.0, 0.7)
	om.emission_enabled = true
	om.emission = Color(0.4, 1.0, 0.65)
	om.emission_energy_multiplier = 5.0
	orb.material_override = om
	root.add_child(orb)

	var light := OmniLight3D.new()
	light.light_color = Color(0.5, 1.0, 0.7)
	light.light_energy = 4.0
	light.omni_range = 14.0
	root.add_child(light)

	# gentle bob
	var tw := root.create_tween().set_loops()
	tw.tween_property(orb, "position:y", 0.3, 1.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(orb, "position:y", 0.0, 1.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return root

func _nearest_seed(ppos: Vector3) -> int:
	for i in _seeds.size():
		if is_instance_valid(_seeds[i]) and ppos.distance_to(_seeds[i].global_position) < PICKUP_DIST:
			return i
	return -1

func _pickup_seed() -> void:
	has_seed = true
	for s in _seeds:
		if is_instance_valid(s):
			s.queue_free()
	_seeds.clear()
	if editor.audio:
		editor.audio.play("chime")
	editor.flash_msg("You take the Heart Seed — find dry ground and plant it")
	_save()

## Editor forwards E near the seed here.
func game_try_interact(ppos: Vector3) -> bool:
	if not planted:
		if not has_seed and _nearest_seed(ppos) >= 0:
			_pickup_seed()
			return true
		return false   # carrying the seed -> let the editor's plant flow handle E
	if Vector2(ppos.x, ppos.z).distance_to(bloom_origin) > INTERACT_DIST:
		return false
	if bloom_stage >= MAX_STAGE:
		editor.flash_msg("The bloom has reached its peak")
		return true
	var cost := _spread_cost(bloom_stage)
	if not _can_afford(cost):
		editor.flash_msg("The seed hungers — bring %s" % _cost_text(cost))
		return true
	for t in cost:
		editor._consume_type(t, int(cost[t]))
		editor._update_inv_pod(t)
	bloom_stage += 1
	bloom_radius = _base_radius + float(bloom_stage - 1) * _grow_radius
	# place the wider flora field (hidden past the front) — it grows in gradually
	editor.plant_flora_field(bloom_origin, bloom_radius)
	if editor.audio:
		editor.audio.play("grow")
	editor.flash_msg("The bloom pushes outward — stage %d begins to spread" % bloom_stage)
	_save()
	return true

## Editor forwards its interact-prompt query here; returns true if it set the label.
func game_update_interact(ppos: Vector3) -> bool:
	if editor.interact_label == null:
		return false
	if not planted:
		if not has_seed and _nearest_seed(ppos) >= 0:
			editor.interact_label.text = "E  —  take the Heart Seed"
			return true
		return false   # carrying the seed -> editor shows the "plant" prompt
	if Vector2(ppos.x, ppos.z).distance_to(bloom_origin) > INTERACT_DIST:
		return false
	if bloom_stage >= MAX_STAGE:
		editor.interact_label.text = "The Heart Seed is fully bloomed"
		return true
	var cost := _spread_cost(bloom_stage)
	if _can_afford(cost):
		editor.interact_label.text = "E  —  Spread the Bloom  (%s)" % _cost_text(cost)
	else:
		editor.interact_label.text = "Heart Seed needs  %s  to spread" % _cost_text(cost)
	return true

func _cost_text(cost: Dictionary) -> String:
	var parts := []
	for t in cost:
		parts.append("%d %s" % [int(cost[t]), t])
	return ", ".join(parts)

# --- resource respawn timers -------------------------------------------------------

var _respawns: Array = []   # { pos: Vector3, type: String, t: float }

func on_resource_broke(pos: Vector3, type: String) -> void:
	# respawn after a delay, sometimes as a different resource
	var new_type := type
	if randf() < 0.5:
		new_type = ["Wood", "Stone", "Stone", "Biomass"][randi() % 4]
	_respawns.append({ "pos": pos, "type": new_type, "t": randf_range(45.0, 90.0) })

func _update_respawns(delta: float) -> void:
	for i in range(_respawns.size() - 1, -1, -1):
		_respawns[i].t -= delta
		if _respawns[i].t <= 0.0:
			var r = _respawns[i]
			if editor.resource_scatter:
				editor.resource_scatter.respawn_one(r.pos, r.type)
			_respawns.remove_at(i)

# --- water (rain-driven only) ------------------------------------------------------

func _update_water(delta: float) -> void:
	_update_respawns(delta)
	var tf := _stage_progress()
	# stage progress sets how HIGH the sea can ever get; rain does the actual filling
	var ceiling: float = lerpf(-13.0, design_water_y, tf)
	var wl: float = editor.water_level
	if editor.rain_intensity > 0.0:
		wl = move_toward(wl, ceiling, RAIN_RISE * (0.4 + editor.rain_intensity) * delta)
		_water_low = maxf(_water_low, minf(wl, ceiling) - 7.0)
	else:
		# gentle receding tide between rains, but oceans that formed stay formed
		wl = move_toward(wl, maxf(_water_low, WATER_HIDDEN), 0.01 * delta)
	editor.set_game_water(wl)

# --- rain (gated to later stages; more frequent as the world lives) ----------------

func _update_rain(delta: float) -> void:
	if bloom_stage < RAIN_FIRST_STAGE:
		return
	if editor.rain_intensity > 0.0:
		return
	_rain_cd -= delta
	if _rain_cd <= 0.0:
		if randf() < 0.12 + 0.05 * float(bloom_stage):
			editor.start_rain_game()
		_rain_cd = randf_range(55.0, 130.0) / (1.0 + float(bloom_stage) * 0.15)

# --- persistence -------------------------------------------------------------------

func _save() -> void:
	if Session.world_dir == "":
		return
	Session.meta["day"] = day
	Session.meta["has_seed"] = has_seed
	Session.meta["bloom_stage"] = bloom_stage
	Session.meta["bloom_radius"] = bloom_radius
	Session.meta["planted"] = planted
	Session.meta["bloom_origin"] = [bloom_origin.x, bloom_origin.y]
	Session.meta["water_low"] = _water_low
	Session.meta["terraform"] = terraform()
	Session.meta["last_played"] = Time.get_unix_time_from_system()
	Session.save_meta(Session.world_dir, Session.meta)
	editor.save_world_to(Session.world_dir)

func save_now() -> void:
	_save()

# --- HUD ---------------------------------------------------------------------------

func _build_hud() -> void:
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	editor.test_layer.add_child(hud)

	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.position = Vector2(-140, 12)
	top.custom_minimum_size = Vector2(280, 0)
	top.add_theme_constant_override("separation", 3)
	hud.add_child(top)

	day_label = _mk_label(top, 22, Color(0.85, 1.0, 0.92), true)
	stage_label = _mk_label(top, 13, Color(0.6, 0.9, 0.72), false)

	var track := PanelContainer.new()
	track.custom_minimum_size = Vector2(280, 14)
	track.add_theme_stylebox_override("panel",
		editor._organic_style(Color(0.05, 0.10, 0.09, 0.85), Color(0.30, 1.0, 0.65, 0.5), 7, 1, 3))
	track.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	top.add_child(track)
	tf_fill = ColorRect.new()
	tf_fill.color = Color(0.35, 1.0, 0.6, 0.9)
	tf_fill.custom_minimum_size = Vector2(4, 8)
	tf_fill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	track.add_child(tf_fill)

	cost_label = _mk_label(top, 11, Color(0.7, 0.9, 0.8), false)

func _mk_label(parent: Control, size: int, col: Color, big: bool) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if big:
		l.add_theme_constant_override("outline_size", 5)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	parent.add_child(l)
	return l

func _refresh_hud() -> void:
	if day_label == null:
		return
	day_label.text = "Day %d" % day
	tf_fill.custom_minimum_size.x = maxf(terraform() * 274.0, 4.0)
	stage_label.text = "%s   ·   Bloom Stage %d" % [_stage_name(), bloom_stage]
	if not planted:
		cost_label.text = "find dry ground and plant your Heart Seed"
	elif bloom_stage >= MAX_STAGE:
		cost_label.text = "the island is whole"
	else:
		cost_label.text = "next spread: %s" % _cost_text(_spread_cost(bloom_stage))

func _stage_name() -> String:
	if not planted:
		return "Barren"
	if bloom_stage < 2:
		return "Awakening"
	if bloom_stage < 4:
		return "Greening"
	if bloom_stage < 7:
		return "Flourishing"
	return "Verdant"
