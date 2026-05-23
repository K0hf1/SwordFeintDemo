# input_buffer.gd
# Attach this as a child node of Player.
# Reads Input.* each physics tick and writes to InputSnapshot.
# The rest of the game reads from `current`, never from Input.* directly.
# This decoupling is the key step that makes networking possible later:
# swap out capture_tick() with a network-received snapshot and nothing else changes.
#
# Node setup: Add as Node child of Player, name it "InputBuffer"
#
extends Node

# The current tick's input. Read-only from outside this script.
var current: InputSnapshot = InputSnapshot.new()

# For local play, call this at the top of _physics_process.
# For networking (client side): still call this, then send `current.serialize()` to host.
# For networking (host side, remote player): call receive_snapshot() instead.
func capture_tick(tick_number: int, player_global_pos: Vector2) -> void:
	var snap := InputSnapshot.new()
	snap.tick = tick_number

	# Movement — raw directional input
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A): dir.x -= 1
	if Input.is_key_pressed(KEY_D): dir.x += 1
	if Input.is_key_pressed(KEY_W): dir.y -= 1
	if Input.is_key_pressed(KEY_S): dir.y += 1
	snap.move_direction = dir.normalized() if dir != Vector2.ZERO else Vector2.ZERO

	# Aim direction toward mouse (local player only)
	var mouse_world := get_viewport().get_canvas_transform().affine_inverse() * get_viewport().get_mouse_position()
	var to_mouse := (mouse_world - player_global_pos)
	snap.aim_direction = to_mouse.normalized() if to_mouse.length() > 1.0 else Vector2.DOWN

	# Actions — just_pressed semantics must be read here, not downstream
	snap.light_attack_pressed = Input.is_action_just_pressed("light_attack")
	snap.dash_pressed          = Input.is_action_just_pressed("dash")

	current = snap


# ---------------------------------------------------------------------------
# Networking path (implement when adding listen-server multiplayer)
# ---------------------------------------------------------------------------

# Called on host when a remote client's input packet arrives.
# The host feeds this into the remote player's CombatController instead
# of calling capture_tick().
func receive_snapshot(data: Dictionary) -> void:
	current = InputSnapshot.deserialize(data)
