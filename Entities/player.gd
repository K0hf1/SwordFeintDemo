# player.gd
# Physics orchestrator and state host.
#
# ── Input provider ────────────────────────────────────────────────────────────
# Direct Input.* polling has been removed entirely.
# Player receives input through a provider assigned at spawn time.
# Call set_input_provider(LocalInputProvider.new(profile)) before the first tick.
# For future network players, pass a RemoteInputProvider — Player.gd is identical.
#
# ── Death freeze ──────────────────────────────────────────────────────────────
# When PlayerHealth.is_dead becomes true (HP <= 0), _physics_process returns
# immediately after zeroing velocity. No movement, no combat ticks, no input.
# The death flash and queue_free are handled entirely by PlayerHealth.
#
# ── Shared tick clock ─────────────────────────────────────────────────────────
# The old local `_tick` counter has been removed. All tick reads now go through
# GameClock.tick — the authoritative shared counter (see game_clock.gd).
# Both players on the same machine (local play) read the same value within a
# frame because GameClock._physics_process runs before Player (process_priority
# -10). In multiplayer, the host advances GameClock via RPC so clients also
# share the same counter, making frame data (startup_end_tick, etc.) meaningful
# on every peer.
#
# ── P1 can't move left when P2 holds Shift (guard) + Arrow keys ──────────────
# This is keyboard ghosting: a hardware/OS limitation on same-machine play.
# When multiple keys are held simultaneously, some key matrices block additional
# keys from registering. Shift + Arrow + A is a common ghosting triplet.
# THIS IS NOT A BUG IN THIS CODE. It will NOT occur in peer-to-peer networking
# because each player polls their own machine's keyboard independently.
# Workarounds for local play only:
#   - Remap P2 guard to a non-modifier key (e.g. Numpad 0)
#   - Use gamepads for one or both players
#
# ── Responsibilities ─────────────────────────────────────────────────────────
#   - Physics / movement / dash
#   - Forwarding InputSnapshot to CombatController each tick
#   - Animation
#   - Hosting child systems (CombatController, ComboTracker, Parry, etc.)
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
@onready var _health: Node             = $PlayerHealth

# ── Input provider ────────────────────────────────────────────────────────────
var _input_provider: LocalInputProvider = null

# ── State ─────────────────────────────────────────────────────────────────────
var last_dir_vector:    Vector2 = Vector2.DOWN
var last_aim_direction: Vector2 = Vector2.DOWN

# NOTE: there is no local _tick here. Use GameClock.tick everywhere.

var _dash_active:              bool = false
var _dash_tick_start:          int  = -999
var _dash_dir:                 Vector2 = Vector2.ZERO
var _dash_cooldown_until:      int  = -999
var _dash_attack_lockout_until:int  = -999


# ── Setup ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	# MOTION_MODE_FLOATING prevents move_and_slide from projecting collision
	# normals onto velocity, which would cause a stationary player to be dragged
	# sideways when another player's CharacterBody2D resolution fires.
	motion_mode = MOTION_MODE_FLOATING

func set_input_provider(provider) -> void:
	_input_provider = provider


# ── Main tick ─────────────────────────────────────────────────────────────────
func _physics_process(_delta: float) -> void:
	# ── Dead freeze ───────────────────────────────────────────────────────────
	# Once HP reaches zero, PlayerHealth sets is_dead = true. We stop all
	# processing immediately — no input, no combat, no movement — and zero out
	# velocity so the body doesn't coast. PlayerHealth handles the visual death
	# sequence and queue_free in its own coroutine.
	if _health != null and (_health as PlayerHealth).is_dead:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	# GameClock.tick is the shared authoritative counter (advanced by GameClock
	# autoload before this node runs). Do NOT increment a local counter here.
	var current_tick: int = GameClock.tick

	# 1. Build InputSnapshot
	var input: InputSnapshot
	if _input_provider != null:
		input = _input_provider.build_snapshot(current_tick, global_position, get_viewport())
	else:
		input = InputSnapshot.new()
		input.tick = current_tick

	# 2. Aim direction
	last_aim_direction = input.aim_direction

	# 3. Dash — guard suppresses dash
	if not input.guard_held:
		_handle_dash_input(input)

	# 4. Combat tick
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
	var current_tick: int = GameClock.tick
	if _dash_active or current_tick < _dash_cooldown_until or _combat.is_busy():
		return
	_dash_active     = true
	_dash_tick_start = current_tick
	_dash_dir        = last_dir_vector if last_dir_vector != Vector2.ZERO else Vector2.DOWN


func _tick_dash() -> void:
	var current_tick: int = GameClock.tick
	var elapsed := current_tick - _dash_tick_start
	if elapsed < dash_frames:
		velocity = _dash_dir * dash_force
		move_and_slide()
	else:
		_dash_active               = false
		_dash_cooldown_until       = current_tick + dash_cooldown_frames
		_dash_attack_lockout_until = current_tick + dash_attack_lockout_frames
		velocity = Vector2.ZERO


func _is_dash_attack_locked() -> bool:
	return GameClock.tick < _dash_attack_lockout_until


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
