extends Camera3D
class_name EditorCamera

## Free-fly editor camera. Hold RIGHT mouse to look, WASD to move,
## Q/E to drop/rise, hold SHIFT to move faster.

@export var speed := 36.0
@export var fast_multiplier := 5.0
@export var mouse_sensitivity := 0.0028

var _looking := false
var _yaw := 0.0
var _pitch := 0.0

func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x

func is_looking() -> bool:
	return _looking

## Re-sync internal yaw/pitch after the camera is repositioned externally
## (e.g. returning from test mode), so the next RMB-look doesn't snap.
func sync_from_rotation() -> void:
	_yaw = rotation.y
	_pitch = rotation.x

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_looking = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and _looking:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)

func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	var b := global_transform.basis
	if Input.is_key_pressed(KEY_W): dir -= b.z
	if Input.is_key_pressed(KEY_S): dir += b.z
	if Input.is_key_pressed(KEY_A): dir -= b.x
	if Input.is_key_pressed(KEY_D): dir += b.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir -= Vector3.UP
	if dir != Vector3.ZERO:
		var s := speed
		if Input.is_key_pressed(KEY_SHIFT):
			s *= fast_multiplier
		global_position += dir.normalized() * s * delta
