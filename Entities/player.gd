# player.gd
# Physics orchestrator. Captures input, delegates to CombatController,
# handles movement, dash, and guard speed scaling.
#
# Input Map (Project Settings → Input Map):
#   "light_attack"   → Left Mouse Button
#   "heavy_attack"   → Right Mouse Button
#   "dash"           → Left Shift      (just_pressed)
#   "guard"          → Left Shift      (is_pressed — same key, different query)
#   "parry"          → C
#   "weapon_switch"  → Tab
#   "ultimate"       → R
#
# GUARD + MOVEMENT:
#   While guard_held is true, movement speed is scaled to walk_speed_multiplier.
#   The player can still move freely — guard does not root them.
#   CombatController.is_guarding mirrors guard_held each tick for RPS resolution.
#
# Scene node setup:
#   Player (CharacterBody2D)
#     ├── CollisionShape2D
#     ├── Body             (AnimatedSprite2D)
#     ├── InputBuffer      (Node)
#     ├── CombatController (Node)
#     ├── ComboTracker     (Node)
#     ├── Parry            (Node)
#     ├── Hurtbox          (Area2D)
#     │     └── CollisionShape2D
#     ├── WeaponDisplay    (Node2D)
#     │     └── SwordIcon
#     └── WeaponHolder     (Node2D)
#           └── Sword      (Node2D)
#               ├── LightAttack (AnimatedSprite2D)
#               │     └── HitboxSL (Area2D)
#               │           └── CollisionShape2D
#               └── HeavyAttack (AnimatedSprite2D)
#                     └── HitboxSH (Area2D)
#                           └── CollisionShape2D
#
extends CharacterBody2D

@export var speed: float                  = 150.0
@export var walk_speed_multiplier: float  = 0.45   # guard walk = 45% of run speed
@export var dash_force: float             = 500.0

@export var dash_frames: int               = 6
@export var dash_cooldown_frames: int      = 30
@export var dash_attack_lockout_frames: int = 20

@onready var anim: AnimatedSprite2D = $Body
@onready var input_buffer: Node     = $InputBuffer
@onready var combat: Node           = $CombatController

var last_dir_vector: Vector2    = Vector2.DOWN
var last_aim_direction: Vector2 = Vector2.DOWN

var tick: int = 0

var dash_active: bool      = false
var dash_tick_start: int   = -999
var dash_dir: Vector2      = Vector2.ZERO

var dash_cooldown_until: int       = -999
var dash_attack_lockout_until: int = -999


func _physics_process(_delta: float) -> void:
	tick += 1

	# 1. Capture input
	input_buffer.capture_tick(tick, global_position)
	var input: InputSnapshot = input_buffer.current

	# 2. Aim direction
	last_aim_direction = input.aim_direction

	# 3. Dash — guard_held suppresses dash (can't dash while guarding)
	if not input.guard_held:
		_handle_dash_input(input)

	# 4. Combat tick (weapon switch, parry, ultimate, attacks all handled inside)
	combat.tick(input, _is_dash_attack_locked())

	# 5. Movement
	if dash_active:
		_tick_dash()
	elif combat.can_move():
		_handle_movement(input)
	else:
		velocity = Vector2.ZERO
		move_and_slide()

	# 6. Animation follows state
	_update_animation(input)


# ── Dash ──────────────────────────────────────────────────────────────────────
func _handle_dash_input(input: InputSnapshot) -> void:
	if not input.dash_pressed:
		return
	if dash_active or tick < dash_cooldown_until or combat.is_busy():
		return

	dash_active     = true
	dash_tick_start = tick
	dash_dir        = last_dir_vector if last_dir_vector != Vector2.ZERO else Vector2.DOWN


func _tick_dash() -> void:
	var elapsed := tick - dash_tick_start
	if elapsed < dash_frames:
		velocity = dash_dir * dash_force
		move_and_slide()
	else:
		dash_active               = false
		dash_cooldown_until       = tick + dash_cooldown_frames
		dash_attack_lockout_until = tick + dash_attack_lockout_frames
		velocity = Vector2.ZERO


func _is_dash_attack_locked() -> bool:
	return tick < dash_attack_lockout_until


# ── Movement ──────────────────────────────────────────────────────────────────
func _handle_movement(input: InputSnapshot) -> void:
	if input.move_direction != Vector2.ZERO:
		last_dir_vector = input.move_direction

	# Guard slows movement to walk speed
	var effective_speed := speed
	if input.guard_held:
		effective_speed = speed * walk_speed_multiplier

	velocity = input.move_direction * effective_speed
	move_and_slide()


# ── Animation ─────────────────────────────────────────────────────────────────
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
