# player.gd
# Physics orchestrator and state host.
#
# ── What changed from the original ───────────────────────────────────────────
# Direct Input.* polling has been removed entirely.
# Player now receives input through a provider object assigned at spawn time.
# Call set_input_provider(LocalInputProvider.new(profile)) before the first tick.
# For future network players, pass a RemoteInputProvider instead — Player.gd
# is identical in both cases.
#
# ── Responsibilities ─────────────────────────────────────────────────────────
#   - Physics / movement / dash
#   - Forwarding InputSnapshot to CombatController each tick
#   - Animation
#   - Hosting child systems (CombatController, ComboTracker, Parry, etc.)
#
# ── Does NOT own ─────────────────────────────────────────────────────────────
#   - Input polling (LocalInputProvider / RemoteInputProvider)
#   - Combat state machine (CombatController)
#   - Combo chain (ComboTracker)
#   - Health (PlayerHealth)
#
# ── Scene node setup ──────────────────────────────────────────────────────────
#   Player (CharacterBody2D)         ← this script
#     ├── CollisionShape2D
#     ├── Body             (AnimatedSprite2D)
#     ├── InputBuffer      (Node — kept for receive_snapshot() networking path)
#     ├── CombatController (Node)
#     ├── ComboTracker     (Node)
#     ├── Parry            (Node)
#     ├── Hurtbox          (Area2D + PlayerHurtbox script)
#     │     └── CollisionShape2D
#     ├── WeaponDisplay    (Node2D)
#     │     └── SwordIcon
#     └── WeaponHolder     (Node2D)
#           └── Sword (Node2D)
#               ├── LightAttack (AnimatedSprite2D)
#               │     └── HitboxSL (Area2D)
#               └── HeavyAttack (AnimatedSprite2D)
#                     └── HitboxSH (Area2D)
#
extends CharacterBody2D

# ── Tuning ────────────────────────────────────────────────────────────────────
@export var speed: float                   = 150.0
@export var walk_speed_multiplier: float   = 0.45
@export var dash_force: float              = 500.0
@export var dash_frames: int               = 6
@export var dash_cooldown_frames: int      = 30
@export var dash_attack_lockout_frames:int = 20

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var _anim:   AnimatedSprite2D = $Body
@onready var _combat: Node             = $CombatController

# ── Input provider ────────────────────────────────────────────────────────────
# Set before first tick via set_input_provider().
# Null-safe: if never set, player produces a blank InputSnapshot every tick
# (stays still, no actions). Useful for testing and spectator slots.
var _input_provider: LocalInputProvider = null   # typed for autocompletion;
												  # duck-typed at runtime so
												  # RemoteInputProvider works too

# ── State ─────────────────────────────────────────────────────────────────────
var last_dir_vector:    Vector2 = Vector2.DOWN
var last_aim_direction: Vector2 = Vector2.DOWN

var _tick: int = 0

var _dash_active:              bool = false
var _dash_tick_start:          int  = -999
var _dash_dir:                 Vector2 = Vector2.ZERO
var _dash_cooldown_until:      int  = -999
var _dash_attack_lockout_until:int  = -999


# ── Setup ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	# MOTION_MODE_FLOATING: move_and_slide does not compute a "floor" normal.
	# In GROUNDED mode (default), when two players collide, Godot projects the
	# collision normal onto both bodies' velocities. A player standing still gets
	# an implicit leftward or rightward push from the resolution — this is what
	# caused P1 to be unable to move left when P2 was guarding nearby.
	# FLOATING mode resolves collisions as pure separation vectors with no axis
	# projection, so a stationary player is never dragged by a moving one.
	motion_mode = MOTION_MODE_FLOATING

# Called by ArenaTest (or any spawner) immediately after add_child().
# Must be called before the first _physics_process tick.
func set_input_provider(provider) -> void:
	_input_provider = provider


# ── Main tick ─────────────────────────────────────────────────────────────────
func _physics_process(_delta: float) -> void:
	_tick += 1

	# 1. Build this tick's InputSnapshot from the provider.
	#    LocalInputProvider reads keyboard/mouse.
	#    RemoteInputProvider returns the last received network snapshot.
	#    If no provider is set, use a blank snapshot (no inputs).
	var input: InputSnapshot
	if _input_provider != null:
		input = _input_provider.build_snapshot(_tick, global_position, get_viewport())
	else:
		input = InputSnapshot.new()
		input.tick = _tick

	# 2. Aim direction (read by CombatController for sword orientation)
	last_aim_direction = input.aim_direction

	# 3. Dash — guard suppresses dash
	if not input.guard_held:
		_handle_dash_input(input)

	# 4. Combat tick (weapon switch, parry, ultimate, attacks)
	_combat.tick(input, _is_dash_attack_locked())

	# 5. Movement
	if _dash_active:
		_tick_dash()
	elif _combat.can_move():
		_handle_movement(input)
	else:
		velocity = Vector2.ZERO
		move_and_slide()

	# 6. Animation
	_update_animation(input)


# ── Dash ──────────────────────────────────────────────────────────────────────
func _handle_dash_input(input: InputSnapshot) -> void:
	if not input.dash_pressed:
		return
	if _dash_active or _tick < _dash_cooldown_until or _combat.is_busy():
		return
	_dash_active     = true
	_dash_tick_start = _tick
	_dash_dir        = last_dir_vector if last_dir_vector != Vector2.ZERO else Vector2.DOWN


func _tick_dash() -> void:
	var elapsed := _tick - _dash_tick_start
	if elapsed < dash_frames:
		velocity = _dash_dir * dash_force
		move_and_slide()
	else:
		_dash_active               = false
		_dash_cooldown_until       = _tick + dash_cooldown_frames
		_dash_attack_lockout_until = _tick + dash_attack_lockout_frames
		velocity = Vector2.ZERO


func _is_dash_attack_locked() -> bool:
	return _tick < _dash_attack_lockout_until


# ── Movement ──────────────────────────────────────────────────────────────────
func _handle_movement(input: InputSnapshot) -> void:
	if input.move_direction != Vector2.ZERO:
		last_dir_vector = input.move_direction

	var effective_speed := speed
	if input.guard_held:
		effective_speed = speed * walk_speed_multiplier

	velocity = input.move_direction * effective_speed
	move_and_slide()


# ── Animation ─────────────────────────────────────────────────────────────────
func _update_animation(input: InputSnapshot) -> void:
	if _combat.is_busy() or _dash_active:
		return

	var dir := input.move_direction
	if dir != Vector2.ZERO:
		last_dir_vector = dir
		if abs(dir.x) > abs(dir.y):
			_anim.play("run_right" if dir.x > 0 else "run_left")
		else:
			_anim.play("run_down" if dir.y > 0 else "run_up")
	else:
		_anim.play(_idle_anim())


func _idle_anim() -> String:
	if abs(last_dir_vector.x) > abs(last_dir_vector.y):
		return "idle_right" if last_dir_vector.x > 0 else "idle_left"
	return "idle_down" if last_dir_vector.y > 0 else "idle_up"
