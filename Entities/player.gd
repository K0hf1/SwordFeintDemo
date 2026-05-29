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
# Fraction of knockback velocity retained each physics tick during hitstun.
# 0.82 at 60 Hz ≈ 30-frame half-life, giving a snappy-but-readable slide.
# Keep this value deterministic across all peers (no delta scaling).
@export var knockback_decay: float         = 0.82

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var _anim:   AnimatedSprite2D = $Body
@onready var _combat: Node             = $CombatController
@onready var _health: Node             = $PlayerHealth

# ── Input provider ────────────────────────────────────────────────────────────
# Typed as base Object so both LocalInputProvider and NullInputProvider fit.
# All providers must implement build_snapshot(tick, pos, viewport) → InputSnapshot.
var _input_provider: Object = null

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


# ── Position sync ─────────────────────────────────────────────────────────────
# The authority peer (whoever controls this player) broadcasts its position
# every physics frame. The remote peer receives it and snaps to it.
#
# This is the simplest possible sync — no interpolation, no lag compensation.
# It will feel slightly stuttery over real network latency but is correct and
# easy to upgrade to interpolation later without changing the RPC signature.
#
# "any_peer" + "call_remote" means: any peer may send this UP TO the server
# (in Godot 4 ENet, RPCs from clients go to server unless relayed). For a
# true peer-to-peer broadcast we call rpc() which sends to all connected peers.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func sync_position(pos: Vector2) -> void:
	# Only apply if we are NOT the authority for this player — we trust the
	# sender's position, not our local simulation for remote players.
	if not is_multiplayer_authority():
		global_position = pos


# ── Animation sync ────────────────────────────────────────────────────────────
# The authority broadcasts the animation name each frame so the remote peer
# displays the correct sprite even though it runs NullInputProvider (no local
# input → no local animation decisions). Sent unreliable_ordered so a stale
# frame never overwrites a fresher one.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func sync_animation(anim_name: String) -> void:
	if not is_multiplayer_authority():
		if _anim.animation != anim_name:
			_anim.play(anim_name)


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
	# The provider assigned at spawn time IS the authority gate:
	#   is_multiplayer_authority() == true  → LocalInputProvider  (reads keyboard)
	#   is_multiplayer_authority() == false → NullInputProvider   (returns zeros)
	# Both implement the same build_snapshot() interface so this block never
	# needs to branch on authority itself. When input-sync RPC is added, swap
	# NullInputProvider for RemoteInputProvider in ArenaMultiplayer — here
	# stays unchanged.
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
	elif _combat.get_state() == _combat.CombatState.HITSTUN:
		# Player is in hitstun — slide out the stored knockback impulse.
		# All other combat states (STARTUP, ACTIVE, RECOVERY, PARRYING) keep
		# the player planted at zero velocity.
		_tick_hitstun_movement()
	else:
		velocity = Vector2.ZERO
		move_and_slide()

	# 6. Animation
	_update_animation(input)

	# 7. Broadcast position + animation to all other peers.
	# Only the authority for this player sends — remotes just receive.
	# unreliable_ordered means dropped packets are skipped, not queued,
	# so stale frames never pile up behind a fresher one.
	if is_multiplayer_authority() and multiplayer.has_multiplayer_peer():
		rpc("sync_position", global_position)
		rpc("sync_animation", _anim.animation)


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

	# Defensive: if elapsed is somehow negative (e.g. clock was desynced and
	# then corrected backward) or unreasonably large, abort the dash cleanly
	# rather than glide forever.
	if elapsed < 0 or elapsed > dash_frames + 4:
		_dash_active               = false
		_dash_cooldown_until       = current_tick + dash_cooldown_frames
		_dash_attack_lockout_until = current_tick + dash_attack_lockout_frames
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if elapsed < dash_frames:
		velocity = _dash_dir * dash_force
		move_and_slide()
	else:
		_dash_active               = false
		_dash_cooldown_until       = current_tick + dash_cooldown_frames
		_dash_attack_lockout_until = current_tick + dash_attack_lockout_frames
		velocity = Vector2.ZERO


# ── Hitstun movement ──────────────────────────────────────────────────────────
# Called every physics tick while combat_state == HITSTUN.
# Reads the stored knockback impulse from CombatController, applies it as
# this frame's velocity, then decays it by a fixed multiplier and writes it
# back so next frame is a little slower.
#
# ── Why fixed-multiplier decay (not delta-scaled)? ────────────────────────────
# delta varies slightly frame-to-frame due to OS scheduling, making delta-based
# decay non-deterministic across two machines. A per-tick constant multiplier
# produces the exact same velocity sequence on every peer given the same initial
# knockback_vector — which is itself deterministic because it's computed from
# AttackData constants and position at hit time.
func _tick_hitstun_movement() -> void:
	var kb: Vector2 = _combat.get_knockback_velocity()
	if kb == Vector2.ZERO:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	velocity = kb
	move_and_slide()

	# Decay for next tick. Stop entirely below 1 px/tick to avoid
	# perpetual micro-sliding that never fully resolves.
	var decayed: Vector2 = kb * knockback_decay
	if decayed.length() < 1.0:
		decayed = Vector2.ZERO
	_combat.set_knockback_velocity(decayed)


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
