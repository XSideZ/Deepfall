extends Node
## THE TIDAL NOMAD. You spawn on the lowest shores of a living island. Day after
## day, rainstorms push the tide higher — drowning the biome you called home and
## forcing you upward: beach -> forest -> desert -> forest 2 -> snow peaks.
## Storms are FORECAST so you have time to pack up. The tide partially recedes
## after each storm, but every storm ratchets the waterline permanently higher.
## Submerged biomes become dive zones (their underwater life rescatters).

var editor                       # LevelEditor
var day := 1
var _phase_prev := 0.0

# --- the tide ---
var tide_base := 0.0             # the level the water recedes to (ratchets up)
var _rain_target := 0.0          # level the current storm is pushing toward
const RAIN_RISE := 0.045         # m/s while raining (slow, watchable)
const RECEDE := 0.012            # m/s between storms
const KEEP_FRACTION := 0.55      # how much of each storm's rise becomes permanent

# --- weather ---
# 0 none | 1 warning | 2 raining
var weather_state := 0
var storm_kind := 0              # 0 drizzle, 1 medium, 2 heavy
var _next_storm_t := 120.0       # countdown to the next forecast
var _warning_t := 0.0
const WARNING_TIME := 45.0
const STORM_NAMES := ["Drizzle", "Rainstorm", "Heavy storm"]

# compat stubs (editor hooks from the bloom era)
var has_seed := true             # home planting is always allowed now
var planted := false

var hud: Control
var day_label: Label
var tide_label: Label
var warn_label: Label

func setup(ed) -> void:
	editor = ed
	day = int(Session.meta.get("day", 1))
	var grid := int(Session.meta.get("grid", 512))

	await editor.generate_world_for_game(int(Session.meta.get("seed", 12345)), grid, 0.0)

	# starting water: just below the forest band -> only beaches + forest 1 walkable
	var amp: float = editor._terrain_amplitude()
	var start_water: float = amp * 0.06   # below the T0 shore table
	tide_base = float(Session.meta.get("tide_base", start_water))
	editor.water_level = float(Session.meta.get("water_now", tide_base))
	editor.set_game_water(editor.water_level)
	_next_storm_t = randf_range(100.0, 190.0)

	# fresh worlds begin at daybreak so you get a full day of light
	if not FileAccess.file_exists(Session.world_dir + "/world.json"):
		editor.day_phase = 0.05

	# the world is fully ALIVE from day one — full lush scatter
	await editor._scatter_resources()

	_build_hud()
	editor.spawn_player_lowest()
	if editor.rain_timer:
		editor.rain_timer.stop()   # weather belongs to the tide system now

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

	_update_weather_cycle(delta)
	_update_tide(delta)
	_refresh_hud()

# --- weather cycle: forecast -> warning -> storm -> recede -------------------------

func _update_weather_cycle(delta: float) -> void:
	match weather_state:
		0:   # clear skies: count down to the next forecast
			_next_storm_t -= delta
			if _next_storm_t <= 0.0:
				_forecast_storm()
		1:   # warning issued: time to pack up
			_warning_t -= delta
			if _warning_t <= 0.0:
				_begin_storm()
		2:   # raining until the tide reaches the storm's target
			if editor.water_level >= _rain_target - 0.05:
				_end_storm()

func _forecast_storm() -> void:
	var roll := randf()
	storm_kind = 0 if roll < 0.5 else (1 if roll < 0.85 else 2)
	weather_state = 1
	_warning_t = WARNING_TIME
	_rain_target = _storm_target(storm_kind)
	var rise: float = _rain_target - editor.water_level
	editor.flash_msg("⚠  %s approaching — tide will rise ~%.0fm. Pack up!" % [STORM_NAMES[storm_kind], maxf(rise, 0.0)])
	if editor.audio:
		editor.audio.play("chime", 0.0, -4.0)

## Storm targets in BIOME BANDS: drizzle = halfway to the next band boundary,
## medium = just over it, heavy = 1.5 bands. Capped below the snow line so the
## peaks only drown after many, many natural storms.
func _storm_target(kind: int) -> float:
	var amp: float = editor._terrain_amplitude()
	var bands: Array = [amp * 0.30, amp * 0.52, amp * 0.74]   # forest->desert->forest2->snow
	var w: float = editor.water_level
	var nxt: float = bands[bands.size() - 1] + 4.0
	var after: float = nxt
	for i in bands.size():
		if w < bands[i]:
			nxt = bands[i]
			after = bands[i + 1] if i + 1 < bands.size() else bands[i] + (bands[i] - (bands[i - 1] if i > 0 else 0.0))
			break
	var t: float = w
	match kind:
		0: t = w + (nxt - w) * 0.5            # teaser: halfway up the cliff
		1: t = nxt + amp * 0.05               # beaches you ONTO the next terrace
		2: t = nxt + (after - nxt) * 0.5      # drowns the terrace deep
	return minf(t, amp * 0.80)   # snow summits stay the last refuge

func _begin_storm() -> void:
	weather_state = 2
	editor.start_rain_game()
	editor.rain_intensity = [0.25, 0.6, 1.0][storm_kind]
	editor.flash_msg("The %s hits — the water is rising" % STORM_NAMES[storm_kind].to_lower())

func _end_storm() -> void:
	weather_state = 0
	editor.stop_rain_game()
	# the ratchet: part of the rise becomes the new permanent waterline
	var prev := tide_base
	tide_base = maxf(tide_base, prev + (_rain_target - prev) * KEEP_FRACTION)
	_next_storm_t = randf_range(110.0, 220.0)
	editor.flash_msg("The storm passes. The tide will settle at %.0fm" % tide_base)
	# submerged land gets its underwater life; dry land rescatters above the new line
	editor.rescatter_after_tide()
	_save()

func _update_tide(delta: float) -> void:
	var w: float = editor.water_level
	if weather_state == 2:
		w = move_toward(w, _rain_target, RAIN_RISE * delta * (0.6 + 0.4 * editor.rain_intensity))
	else:
		w = move_toward(w, tide_base, RECEDE * delta)
	if absf(w - editor.water_level) > 0.0001:
		editor.set_game_water(w)

# --- editor hooks (kept for compatibility) ------------------------------------------

func on_planted(pos: Vector3) -> void:
	planted = true
	_save()

func game_try_interact(_ppos: Vector3) -> bool:
	return false

func game_update_interact(_ppos: Vector3) -> bool:
	return false

# --- resource respawn timers ---------------------------------------------------------

var _respawns: Array = []   # { pos: Vector3, type: String, t: float }

func on_resource_broke(pos: Vector3, type: String) -> void:
	var new_type := type
	if randf() < 0.5:
		new_type = ["Wood", "Stone", "Stone", "Biomass"][randi() % 4]
	_respawns.append({ "pos": pos, "type": new_type, "t": randf_range(45.0, 90.0) })

func _physics_process(delta: float) -> void:
	for i in range(_respawns.size() - 1, -1, -1):
		_respawns[i].t -= delta
		if _respawns[i].t <= 0.0:
			var r = _respawns[i]
			if editor and editor.resource_scatter:
				editor.resource_scatter.respawn_one(r.pos, r.type)
			_respawns.remove_at(i)

# --- persistence ---------------------------------------------------------------------

func _save() -> void:
	if Session.world_dir == "":
		return
	Session.meta["day"] = day
	Session.meta["tide_base"] = tide_base
	Session.meta["water_now"] = editor.water_level
	Session.meta["last_played"] = Time.get_unix_time_from_system()
	Session.save_meta(Session.world_dir, Session.meta)
	editor.save_world_to(Session.world_dir)

func save_now() -> void:
	_save()

# --- HUD -----------------------------------------------------------------------------

func _build_hud() -> void:
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	editor.test_layer.add_child(hud)

	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.position = Vector2(-160, 12)
	top.custom_minimum_size = Vector2(320, 0)
	top.add_theme_constant_override("separation", 3)
	hud.add_child(top)

	day_label = _mk_label(top, 22, Color(0.85, 1.0, 0.92), true)
	tide_label = _mk_label(top, 13, Color(0.55, 0.85, 1.0), false)
	warn_label = _mk_label(top, 16, Color(1.0, 0.75, 0.35), true)

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
	tide_label.text = "Tide  %.1fm" % editor.water_level
	match weather_state:
		1:
			warn_label.text = "⚠  %s in %ds — tide +%.0fm" % [STORM_NAMES[storm_kind], int(_warning_t), maxf(_rain_target - editor.water_level, 0.0)]
			warn_label.visible = fmod(Time.get_ticks_msec() / 1000.0, 0.9) < 0.65   # blink
		2:
			warn_label.visible = true
			warn_label.text = "%s — water rising (%.1fm -> %.0fm)" % [STORM_NAMES[storm_kind], editor.water_level, _rain_target]
		_:
			warn_label.visible = false
