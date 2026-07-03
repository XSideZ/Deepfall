extends Control
## DeepFall main menu: Play (world manager, Subnautica-style), Editor, Settings.

const GAME_SCENE := "res://scenes/LevelEditor.tscn"
const MENU_CFG := "user://menu.cfg"

var home_center: CenterContainer
var home_box: VBoxContainer
var play_center: CenterContainer
var play_panel: PanelContainer
var settings_center: CenterContainer
var settings_panel: PanelContainer
var worlds_list: VBoxContainer
var new_name: LineEdit

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.05, 0.045)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# CenterContainer fills the screen and centres whatever child it holds — this is
	# what actually keeps the menu centred at any resolution (raw anchors don't).
	home_center = CenterContainer.new()
	home_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(home_center)

	home_box = VBoxContainer.new()
	home_box.add_theme_constant_override("separation", 14)
	home_center.add_child(home_box)

	var title := Label.new()
	title.text = "D E E P F A L L"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
	home_box.add_child(title)
	var sub := Label.new()
	sub.text = "bring a dead world back to life"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", Color(0.42, 0.62, 0.52))
	home_box.add_child(sub)
	home_box.add_child(_spacer(18))

	home_box.add_child(_menu_btn("Play", _show_play))
	home_box.add_child(_menu_btn("Editor", _launch_editor))
	home_box.add_child(_menu_btn("Settings", _show_settings))
	home_box.add_child(_menu_btn("Quit", func(): get_tree().quit()))

	_build_play_panel()
	_build_settings_panel()
	_apply_saved_settings()

func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _menu_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 46)
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(cb)
	return b

func _launch_editor() -> void:
	Session.mode = "editor"
	Session.world_dir = ""
	get_tree().change_scene_to_file(GAME_SCENE)

# --- Play: the world manager -------------------------------------------------------

func _build_play_panel() -> void:
	play_center = CenterContainer.new()
	play_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	play_center.visible = false
	add_child(play_center)
	play_panel = PanelContainer.new()
	play_center.add_child(play_panel)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(560, 420)
	v.add_theme_constant_override("separation", 10)
	play_panel.add_child(v)

	var head := Label.new()
	head.text = "YOUR WORLDS"
	head.add_theme_font_size_override("font_size", 22)
	head.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
	v.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	worlds_list = VBoxContainer.new()
	worlds_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	worlds_list.add_theme_constant_override("separation", 6)
	scroll.add_child(worlds_list)

	v.add_child(HSeparator.new())
	var nl := Label.new()
	nl.text = "NEW WORLD"
	nl.add_theme_color_override("font_color", Color(0.45, 0.75, 0.6))
	v.add_child(nl)
	new_name = LineEdit.new()
	new_name.placeholder_text = "World name..."
	v.add_child(new_name)
	var sizes := HBoxContainer.new()
	sizes.add_theme_constant_override("separation", 8)
	v.add_child(sizes)
	for s in ["Small", "Medium", "Large", "Huge"]:
		var sb := Button.new()
		sb.text = s
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.pressed.connect(_create_world.bind(s))
		sizes.add_child(sb)

	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_show_home)
	v.add_child(back)

func _show_home() -> void:
	play_center.visible = false
	settings_center.visible = false
	home_center.visible = true

func _show_play() -> void:
	home_center.visible = false
	settings_center.visible = false
	play_center.visible = true
	_refresh_worlds()

func _refresh_worlds() -> void:
	for c in worlds_list.get_children():
		c.queue_free()
	var worlds: Array = Session.list_worlds()
	if worlds.is_empty():
		var none := Label.new()
		none.text = "no worlds yet — create one below"
		none.add_theme_color_override("font_color", Color(0.45, 0.55, 0.5))
		worlds_list.add_child(none)
	for w in worlds:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		worlds_list.add_child(row)
		var info := Label.new()
		info.text = "%s   ·   %s  ·  Day %d  ·  bloom %d%%" % [
			String(w.get("name", "?")), String(w.get("size", "?")),
			int(w.get("day", 1)), int(float(w.get("terraform", 0.0)) * 100.0)]
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var pb := Button.new()
		pb.text = "Play"
		pb.pressed.connect(_play_world.bind(String(w.dir)))
		row.add_child(pb)
		var db := Button.new()
		db.text = "✕"
		db.tooltip_text = "Delete world (double-click)"
		db.pressed.connect(_confirm_delete.bind(db, String(w.dir)))
		row.add_child(db)

func _confirm_delete(btn: Button, dir: String) -> void:
	if btn.text == "✕":
		btn.text = "sure?"
		await get_tree().create_timer(2.0).timeout
		if is_instance_valid(btn):
			btn.text = "✕"
	else:
		Session.delete_world(dir)
		_refresh_worlds()

func _create_world(size_label: String) -> void:
	var wname := new_name.text.strip_edges()
	if wname == "":
		wname = "New world"
	var dir: String = Session.create_world(wname, size_label)
	_play_world(dir)

func _play_world(dir: String) -> void:
	Session.mode = "game"
	Session.world_dir = dir
	Session.meta = Session.load_meta(dir)
	Session.meta["last_played"] = Time.get_unix_time_from_system()
	Session.save_meta(dir, Session.meta)
	get_tree().change_scene_to_file(GAME_SCENE)

# --- settings -----------------------------------------------------------------------

func _build_settings_panel() -> void:
	settings_center = CenterContainer.new()
	settings_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_center.visible = false
	add_child(settings_center)
	settings_panel = PanelContainer.new()
	settings_center.add_child(settings_panel)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(420, 0)
	v.add_theme_constant_override("separation", 12)
	settings_panel.add_child(v)
	var head := Label.new()
	head.text = "SETTINGS"
	head.add_theme_font_size_override("font_size", 22)
	head.add_theme_color_override("font_color", Color(0.55, 1.0, 0.75))
	v.add_child(head)

	var fs := CheckButton.new()
	fs.text = "Fullscreen"
	fs.button_pressed = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	fs.toggled.connect(func(on: bool):
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)
		_save_setting("fullscreen", on))
	v.add_child(fs)

	var vl := Label.new()
	vl.text = "Volume"
	v.add_child(vl)
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.05
	vol.value = db_to_linear(AudioServer.get_bus_volume_db(0))
	vol.value_changed.connect(func(val: float):
		AudioServer.set_bus_volume_db(0, linear_to_db(maxf(val, 0.001)))
		_save_setting("volume", val))
	v.add_child(vol)

	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_show_home)
	v.add_child(back)

func _show_settings() -> void:
	home_center.visible = false
	play_center.visible = false
	settings_center.visible = true

func _save_setting(key: String, val) -> void:
	var cfg := ConfigFile.new()
	cfg.load(MENU_CFG)
	cfg.set_value("s", key, val)
	cfg.save(MENU_CFG)

func _apply_saved_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(MENU_CFG) != OK:
		return
	if bool(cfg.get_value("s", "fullscreen", false)):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	var vol := float(cfg.get_value("s", "volume", 1.0))
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(vol, 0.001)))
