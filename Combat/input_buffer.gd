# input_buffer.gd
# Reads Input.* each physics tick and writes to InputSnapshot.
# The rest of the game reads from `current`, never from Input.* directly.
# Attach as a child Node of Player, named "InputBuffer".
#
# Input Map requirements (Project Settings → Input Map):
#   "light_attack"   → Left Mouse Button (or preferred key)
#   "dash"           → Shift (or preferred key)
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

	# Aim toward mouse (local player only)
	var mouse_world := get_viewport().get_canvas_transform().affine_inverse() \
		* get_viewport().get_mouse_position()
	var to_mouse := mouse_world - player_global_pos
	snap.aim_direction = to_mouse.normalized() if to_mouse.length() > 1.0 else Vector2.DOWN

	# just_pressed actions — must be captured here, not downstream
	snap.light_attack_pressed  = Input.is_action_just_pressed("light_attack")
	snap.dash_pressed          = Input.is_action_just_pressed("dash")
	snap.weapon_switch_pressed = Input.is_action_just_pressed("weapon_switch")
	snap.ultimate_pressed      = Input.is_action_just_pressed("ultimate")

	current = snap


# ── Networking path (implement when adding listen-server multiplayer) ─────────
func receive_snapshot(data: Dictionary) -> void:
	current = InputSnapshot.deserialize(data)
