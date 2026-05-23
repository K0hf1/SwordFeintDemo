# player.gd  (REFACTORED)
# Player is now a physics orchestrator. It:
#   1. Captures input via InputBuffer
#   2. Delegates combat simulation to CombatController
#   3. Handles movement and dash (tick-based)
#   4. Drives animation based on state (never the other way around)
#
# Removed: is_attacking flag, await create_timer(), direct weapon calls,
#          light_attack() coroutine, direct Input.* reads in gameplay logic.
#
# Scene node setup:
#   Player (CharacterBody2D)
#     ├── Body (AnimatedSprite2D)
#     ├── Hurtbox (Area2D)
#     ├── InputBuffer (Node)          ← new
#     ├── CombatController (Node)     ← new
#     └── WeaponHolder (Node2D)
#           └── Sword (Node2D)
#               └── LightAttack (AnimatedSprite2D)
#                     └── HitboxSL (Area2D)

extends CharacterBody2D

@export var speed := 150.0
@export var dash_force := 350.0         # pixels/sec during dash (replaces distance/duration)
@export var dash_frames := 6            # how many ticks the dash lasts (at 60Hz ≈ 100ms)
@export var dash_lockout_frames := 12   # ticks after dash before attacking is allowed

@onready var anim: AnimatedSprite2D = $Body
@onready var input_buffer: Node     = $InputBuffer
@onready var combat: Node           = $CombatController

# Direction state — readable by CombatController for attack orientation
var last_dir_vector: Vector2 = Vector2.DOWN
var last_aim_direction: Vector2 = Vector2.DOWN

# Tick counter — shared with CombatController (pass in as argument)
var tick: int = 0

# Dash state (tick-based, no await)
var dash_active: bool = false
var dash_tick_start: int = -999
var dash_dir: Vector2 = Vector2.ZERO
var dash_lockout_until: int = -999


func _physics_process(_delta: float) -> void:
	tick += 1

	# 1. Capture this tick's input
	input_buffer.capture_tick(tick, global_position)
	var input: InputSnapshot = input_buffer.current

	# 2. Update aim direction from snapshot
	last_aim_direction = input.aim_direction

	# 3. Handle dash trigger (checked before combat tick so combat can see lockout state)
	_handle_dash_input(input)

	# 4. Advance combat simulation (state machine, hit detection, frame counters)
	combat.tick(input)

	# 5. Apply movement (only when combat allows it)
	if dash_active:
		_tick_dash()
	elif combat.can_move():
		_handle_movement(input)
	else:
		velocity = Vector2.ZERO
		move_and_slide()

	# 6. Drive animation from state (never the other way around)
	_update_animation(input)


# ── Dash (tick-based) ────────────────────────────────────────────────────────

func _handle_dash_input(input: InputSnapshot) -> void:
	if not input.dash_pressed:
		return
	if dash_active:
		return
	if tick < dash_lockout_until:
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
		dash_lockout_until = tick + dash_lockout_frames
		velocity = Vector2.ZERO


# ── Movement ─────────────────────────────────────────────────────────────────

func _handle_movement(input: InputSnapshot) -> void:
	if input.move_direction != Vector2.ZERO:
		last_dir_vector = input.move_direction

	velocity = input.move_direction * speed
	move_and_slide()


# ── Animation (follows state, never drives it) ───────────────────────────────

func _update_animation(input: InputSnapshot) -> void:
	# CombatController drives attack animations inside itself (startup/active/recovery)
	# Player only drives movement animations when IDLE
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
