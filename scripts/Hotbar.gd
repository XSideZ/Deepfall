extends Control
## Bottom-centre hotbar: one slot per Blocks.HOTBAR entry, showing the block colour
## and slot number. Select with number keys 1-9 or the scroll wheel. The Player reads
## get_block() to know what to place.

const SLOT := 56
const PAD := 6
const IconShader := preload("res://shaders/block_icon.gdshader")

var _selected := 0
var _slots: Array[Panel] = []


func _ready() -> void:
	add_to_group("hotbar")
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	get_viewport().size_changed.connect(_layout)
	_layout()
	_refresh()


func get_block() -> int:
	return Blocks.HOTBAR[_selected]


func _build() -> void:
	for i in Blocks.HOTBAR.size():
		var id: int = Blocks.HOTBAR[i]
		var panel := Panel.new()
		panel.custom_minimum_size = Vector2(SLOT, SLOT)
		panel.size = Vector2(SLOT, SLOT)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var swatch := ColorRect.new()
		swatch.color = Blocks.color_for(id)
		swatch.anchor_right = 1.0
		swatch.anchor_bottom = 1.0
		swatch.offset_left = 7
		swatch.offset_top = 7
		swatch.offset_right = -7
		swatch.offset_bottom = -7
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := ShaderMaterial.new()
		mat.shader = IconShader
		var c := Blocks.color_for(id)
		mat.set_shader_parameter("block_color", Vector3(c.r, c.g, c.b))
		mat.set_shader_parameter("block_id", id)
		swatch.material = mat
		panel.add_child(swatch)

		var label := Label.new()
		label.text = str(i + 1)
		label.position = Vector2(5, 2)
		label.add_theme_font_size_override("font_size", 14)
		panel.add_child(label)

		add_child(panel)
		_slots.append(panel)


func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	var n := _slots.size()
	var total := n * SLOT + (n - 1) * PAD
	var x0 := (vp.x - total) * 0.5
	var y := vp.y - SLOT - 24.0
	for i in n:
		_slots[i].position = Vector2(x0 + i * (SLOT + PAD), y)


func _refresh() -> void:
	for i in _slots.size():
		_slots[i].add_theme_stylebox_override("panel", _make_style(i == _selected))


func _make_style(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.45)
	sb.set_corner_radius_all(4)
	sb.set_border_width_all(3 if selected else 1)
	sb.border_color = Color(1, 1, 1, 0.95) if selected else Color(1, 1, 1, 0.25)
	return sb


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			var idx: int = event.keycode - KEY_1
			if idx < _slots.size():
				_selected = idx
				_refresh()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_selected = (_selected + 1) % _slots.size()
			_refresh()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_selected = (_selected - 1 + _slots.size()) % _slots.size()
			_refresh()
