# player.gd  (REFACTORED)
# Player is the physics orchestrator. It:
#   1. Captures input via InputBuffer
#   2. Delegates combat simulation to CombatController
#   3. Handles movement and dash (tick-based)
#   4. Drives animation based on state (never the other way around)
#
# WEAPON SWITCHING:
#   When the player switches weapons, call combat.notify_weapon_switched(new_id).
#   This clears the combo chain in ComboTracker. The actual weapon-swap UI/logic
#   is not yet implemented — the stub below shows where it goes.
#
# Scene node setup:
#   Player (CharacterBody2D)
#     ├── Body (AnimatedSprite2D)
#     ├── Hurtbox (Area2D)
#     ├── InputBuffer (Node)
#     ├── CombatController (Node)
#     ├── ComboTracker (Node)          ← NEW — add to scene tree
#     └── WeaponHolder (Node2D)
#           └── Sword (Node2D)
#               └── LightAttack (AnimatedSprite2D)
#                     └── HitboxSL (Area2D)

extends CharacterBody2D

@export var speed := 150.0
@export var dash_force := 500.0

# Dash timing — in ticks (60 ticks = 1 second)
@export var dash_frames := 6
@export var dash_cooldown_frames := 30
@export var dash_attack_lockout_frames := 20

@onready var anim: AnimatedSprite2D = $Body
@onready var input_buffer: Node     = $InputBuffer
@onready var combat: Node           = $CombatController
# ComboTracker is not read directly by player — CombatController references it.
# It is listed here as documentation of the required scene tree.

# Direction state — readable by CombatController for attack orientation
var last_dir_vector: Vector2 = Vector2.DOWN
var last_aim_direction: Vector2 = Vector2.DOWN

# Tick counter
var tick: int = 0

# Dash state (tick-based, no await)
var dash_active: bool = false
var dash_tick_start: int = -999
var dash_dir: Vector2 = Vector2.ZERO

var dash_cooldown_until: int       = -999
var dash_attack_lockout_until: int = -999


func _physics_process(_delta: float) -> void:
	tick += 1

	# 1. Capture this tick's input
	input_buffer.capture_tick(tick, global_position)
	var input: InputSnapshot = input_buffer.current

	# 2. Update aim direction from snapshot
	last_aim_direction = input.aim_direction

	# 3. Handle dash trigger
	_handle_dash_input(input)

	# 4. Advance combat simulation
	combat.tick(input, _is_dash_attack_locked())

	# 5. Apply movement
	if dash_active:
		_tick_dash()
	elif combat.can_move():
		_handle_movement(input)
	else:
		velocity = Vector2.ZERO
		move_and_slide()

	# 6. Drive animation from state
	_update_animation(input)

	# 7. Weapon switch input (STUB — implement when weapon system is added)
	# _handle_weapon_switch_input(input)


# ── Weapon switching (STUB) ───────────────────────────────────────────────────
# Uncomment and expand when the weapon system is implemented.
# Calling combat.notify_weapon_switched() is what clears the combo chain.
#
# func _handle_weapon_switch_input(input: InputSnapshot) -> void:
#     if input.weapon_next_pressed:
#         active_weapon_id = _get_next_weapon()
#         combat.notify_weapon_switched(active_weapon_id)
#         # ... hide/show weapon nodes ...


# ── Dash ──────────────────────────────────────────────────────────────────────

func _handle_dash_input(input: InputSnapshot) -> void:
	if not input.dash_pressed:
		return
	if dash_active:
		return
	if tick < dash_cooldown_until:
		return
	if combat.is_busy():
		return

	dash_active = true
	dash_tick_start = tick
	dash_dir = last_dir_vector if last_dir_vector != Vector2.ZERO else Vector2.DOWN


func _tick_dash() -> void:
	var elapsed_ticks := tick - dash_tick_start

	if elapsed_ticks < dash_frames:
		velocity = dash_dir * dash_force
		move_and_slide()
	else:
		dash_active = false
		dash_cooldown_until       = tick + dash_cooldown_frames
		dash_attack_lockout_until = tick + dash_attack_lockout_frames
		velocity = Vector2.ZERO


func _is_dash_attack_locked() -> bool:
	return tick < dash_attack_lockout_until


# ── Movement ──────────────────────────────────────────────────────────────────

func _handle_movement(input: InputSnapshot) -> void:
	if input.move_direction != Vector2.ZERO:
		last_dir_vector = input.move_direction

	velocity = input.move_direction * speed
	move_and_slide()


# ── Animation (follows state, never drives it) ────────────────────────────────

func _update_animation(input: InputSnapshot) -> void:
	if combat.is_busy() or dash_active:
		return

	var dir := input.move_direction
	if dir != Vector2.ZERO:
		last_dir_vector = dir
		if abs(dir.x) > abs(dir.y):
			anim.play("run_right" if dir.x > 0 else "run_left")
		else:
			anim.play("run_down" if dir.y > 0 else "run_up")
	else:
		anim.play(_idle_anim())


func _idle_anim() -> String:
	if abs(last_dir_vector.x) > abs(last_dir_vector.y):
		return "idle_right" if last_dir_vector.x > 0 else "idle_left"
	return "idle_down" if last_dir_vector.y > 0 else "idle_up"
