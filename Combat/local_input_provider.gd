# local_input_provider.gd
# Reads physical input (keyboard / mouse) each physics tick and returns
# an InputSnapshot. Driven by an InputProfile so Player A and Player B
# can share the same Player scene with different key bindings.
#
# ── Multiplayer safety ────────────────────────────────────────────────────────
# This class is the ONLY place that touches Input.* and Viewport mouse position.
# CombatController, ComboTracker, Parry — none of them poll input directly.
# When adding network players, swap this out for a RemoteInputProvider that
# instead reads the latest snapshot received from the wire. Player.gd never
# knows the difference because it only calls provider.build_snapshot().
#
# ── Attach / instantiate ──────────────────────────────────────────────────────
# Do NOT add this as a scene child. It is created in code by ArenaTest
# (or whoever spawns the player) and assigned to Player via:
#
#   player.set_input_provider(LocalInputProvider.new(profile))
#
# This keeps the Player scene free of hardcoded provider type.
#
class_name LocalInputProvider

var _profile: InputProfile
var _last_aim: Vector2 = Vector2.DOWN   # cached when aim_mode = "fixed"


func _init(profile: InputProfile) -> void:
	_profile = profile


# ── Main entry point ──────────────────────────────────────────────────────────
# Called once per physics tick by Player._physics_process().
# player_global_pos is needed for mouse-aim calculation.
func build_snapshot(tick_number: int, player_global_pos: Vector2,
		viewport: Viewport) -> InputSnapshot:

	var snap := InputSnapshot.new()
	snap.tick = tick_number

	# ── Movement ──────────────────────────────────────────────────────────────
	var dir := Vector2.ZERO
	dir.x -= _read_key(_profile.move_left_action,  _profile.key_left,  viewport)
	dir.x += _read_key(_profile.move_right_action, _profile.key_right, viewport)
	dir.y -= _read_key(_profile.move_up_action,    _profile.key_up,    viewport)
	dir.y += _read_key(_profile.move_down_action,  _profile.key_down,  viewport)
	snap.move_direction = dir.normalized() if dir != Vector2.ZERO else Vector2.ZERO

	# ── Aim ───────────────────────────────────────────────────────────────────
	match _profile.aim_mode:
		"mouse":
			var mouse_world := viewport.get_canvas_transform().affine_inverse() \
				* viewport.get_mouse_position()
			var to_mouse := mouse_world - player_global_pos
			if to_mouse.length() > 1.0:
				_last_aim = to_mouse.normalized()
			snap.aim_direction = _last_aim
		"fixed":
			# Aim follows last movement direction — no mouse needed for P2
			if snap.move_direction != Vector2.ZERO:
				_last_aim = snap.move_direction
			snap.aim_direction = _last_aim
		_:
			snap.aim_direction = _last_aim

	# ── just_pressed actions ──────────────────────────────────────────────────
	snap.light_attack_pressed  = _just_pressed(_profile.light_attack_action)
	snap.heavy_attack_pressed  = _just_pressed(_profile.heavy_attack_action)
	snap.dash_pressed          = _just_pressed(_profile.dash_action)
	snap.parry_pressed         = _just_pressed(_profile.parry_action)
	snap.weapon_switch_pressed = _just_pressed(_profile.weapon_switch_action)
	snap.ultimate_pressed      = _just_pressed(_profile.ultimate_action)

	# ── held actions ──────────────────────────────────────────────────────────
	snap.guard_held = _is_held(_profile.guard_action)

	return snap


# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns 1.0 if the action or raw key is held, else 0.0.
# Action name takes priority over raw key when non-empty.
func _read_key(action: String, raw_key: Key, _viewport: Viewport) -> float:
	if action != "":
		return 1.0 if Input.is_action_pressed(action) else 0.0
	return 1.0 if Input.is_key_pressed(raw_key) else 0.0


func _just_pressed(action: String) -> bool:
	if action == "":
		return false
	return Input.is_action_just_pressed(action)


func _is_held(action: String) -> bool:
	if action == "":
		return false
	return Input.is_action_pressed(action)
