# input_buffer.gd
# Reads Input.* each physics tick and writes to InputSnapshot.
# Attach as a child Node of Player, named "InputBuffer".
#
# Input Map (Project Settings → Input Map):
#   "light_attack"   → Left Mouse Button
#   "heavy_attack"   → Right Mouse Button
#   "dash"           → Left Shift
#   "guard"          → Left Shift   (same key — dash=just_pressed, guard=is_pressed)
#   "parry"          → C
#   "weapon_switch"  → Tab
#   "ultimate"       → R
#
extends Node

var current: InputSnapshot = InputSnapshot.new()


func capture_tick(tick_number: int, player_global_pos: Vector2) -> void:
	var snap := InputSnapshot.new()
	snap.tick = tick_number

	# Movement
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_W): dir.y -= 1
	if Input.is_key_pressed(KEY_S): dir.y += 1
	snap.move_direction = dir.normalized() if dir != Vector2.ZERO else Vector2.ZERO

	# Aim toward mouse
	var mouse_world := get_viewport().get_canvas_transform().affine_inverse() \
		* get_viewport().get_mouse_position()
	var to_mouse := mouse_world - player_global_pos
	snap.aim_direction = to_mouse.normalized() if to_mouse.length() > 1.0 else Vector2.DOWN

	# just_pressed actions (single-frame edge)
	snap.light_attack_pressed  = Input.is_action_just_pressed("light_attack")
	snap.heavy_attack_pressed  = Input.is_action_just_pressed("heavy_attack")
	snap.dash_pressed          = Input.is_action_just_pressed("dash")
	snap.parry_pressed         = Input.is_action_just_pressed("parry")
	snap.weapon_switch_pressed = Input.is_action_just_pressed("weapon_switch")
	snap.ultimate_pressed      = Input.is_action_just_pressed("ultimate")

	# Held action (true every frame the key is down)
	snap.guard_held = Input.is_action_pressed("guard")

	current = snap


# Networking path
func receive_snapshot(data: Dictionary) -> void:
	current = InputSnapshot.deserialize(data)
