extends CharacterBody3D
## First-person controller with normal downward gravity (underground, no gravity flip).
##
## Controls: WASD move, mouse look, Space jump (or ascend while flying), Shift sprint,
## Ctrl descend (flying), F toggle fly, 1-9 / wheel select block, hold LMB break,
## hold RMB place.

@export var speed := 6.0
@export var sprint_mult := 1.8
@export var jump_velocity := 8.0
@export var gravity := 24.0
@export var fly_speed := 11.0
@export var mouse_sensitivity := 0.0025
@export var reach := 8.0
@export var edit_interval := 0.12   # seconds between repeated breaks/places while held

var _camera: Camera3D
var _world: VoxelWorld
var _hotbar: Node
var _yaw := 0.0
var _pitch := 0.0

var _flying := false
var _break_held := false
var _place_held := false
var _edit_cd := 0.0


func _ready() -> void:
	_camera = $Camera3D
	_world = get_tree().get_first_node_in_group("voxel_world")
	_hotbar = get_tree().get_first_node_in_group("hotbar")
	if _world != null and _world.spawn_position != Vector3.ZERO:
		global_position = _world.spawn_position
	_yaw = rotation.y
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
		rotation = Vector3(0.0, _yaw, 0.0)        # body yaws
		_camera.rotation = Vector3(_pitch, 0.0, 0.0)  # camera pitches
		return

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		_flying = not _flying
		velocity = Vector3.ZERO
		return

	if event is InputEventMouseButton:
		# A click while the cursor is free just recaptures it.
		if event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			_break_held = event.pressed
			if event.pressed:
				_edit(true)
				_edit_cd = edit_interval
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_place_held = event.pressed
			if event.pressed:
				_edit(false)
				_edit_cd = edit_interval


func _physics_process(delta: float) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# Movement is relative to where we're facing (yaw only; pitch is camera-only).
	var move := global_transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)
	move.y = 0.0
	var sprinting := Input.is_key_pressed(KEY_SHIFT)

	if _flying:
		_fly(move, sprinting)
	else:
		_walk(delta, move, sprinting)

	_handle_held_edits(delta)


func _walk(delta: float, move: Vector3, sprinting: bool) -> void:
	var spd := speed * (sprint_mult if sprinting else 1.0)

	if is_on_floor():
		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_velocity
	else:
		velocity.y -= gravity * delta

	if move.length() > 0.001:
		var h := move.normalized() * spd
		velocity.x = h.x
		velocity.z = h.z
	else:
		velocity.x = move_toward(velocity.x, 0.0, spd)
		velocity.z = move_toward(velocity.z, 0.0, spd)

	move_and_slide()


func _fly(move: Vector3, sprinting: bool) -> void:
	var spd := fly_speed * (sprint_mult if sprinting else 1.0)
	var dir := move
	if Input.is_action_pressed("jump"):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		dir += Vector3.DOWN
	velocity = dir.normalized() * spd if dir.length() > 0.001 else Vector3.ZERO
	move_and_slide()


func _handle_held_edits(delta: float) -> void:
	_edit_cd -= delta
	if _edit_cd > 0.0:
		return
	if _break_held:
		_edit(true)
		_edit_cd = edit_interval
	elif _place_held:
		_edit(false)
		_edit_cd = edit_interval


## breaking = true removes the hit voxel; false places the selected block against the face.
func _edit(breaking: bool) -> void:
	if _world == null:
		return
	var from := _camera.global_position
	var to := from - _camera.global_transform.basis.z * reach
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return

	var nudge: Vector3 = hit.normal * 0.5
	var target: Vector3 = (hit.position - nudge) if breaking else (hit.position + nudge)
	var vx := int(floor(target.x))
	var vy := int(floor(target.y))
	var vz := int(floor(target.z))

	var id := Blocks.AIR
	if not breaking:
		# Resolve lazily: the hotbar joins its group in its own _ready(), which runs
		# after the Player's, so it isn't available yet at our _ready().
		if _hotbar == null:
			_hotbar = get_tree().get_first_node_in_group("hotbar")
		id = _hotbar.get_block() if _hotbar != null else Blocks.STONE
	_world.set_voxel(vx, vy, vz, id)
