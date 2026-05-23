# combat_controller.gd
# The authoritative combat state machine. Attach as a child of Player.
#
# Owns: combat state, tick progression, frame data, hit registration,
#       routing of weapon_switch and ultimate inputs to the right subsystems.
# Does NOT own: movement, rendering, input collection, combo chain logic.
#
# WEAPON SWITCHING:
#   When input.weapon_switch_pressed fires, _handle_weapon_switch() is called.
#   It notifies ComboTracker (chain cleared, ultimates preserved) and swaps the
#   active weapon reference. Extend _handle_weapon_switch() when more weapons
#   are added.
#
# ULTIMATE CASTING:
#   When input.ultimate_pressed fires, CombatController asks ComboTracker to
#   try_cast_ultimate() for the current weapon. ComboTracker handles the slot
#   lookup and emits the signals. Actual ability execution goes in ComboTracker
#   or a dedicated UltimateSystem node in a future iteration.
#
# DAMAGE:
#   Always flat from AttackData. Never modified by combo state or chain position.
#
# Node setup:
#   Player
#     ├── CombatController   ← this script
#     └── ComboTracker       ← sibling, owns chain + ultimate slots
#
extends Node

# ── State ─────────────────────────────────────────────────────────────────────
enum CombatState { IDLE, STARTUP, ACTIVE, RECOVERY, HITSTUN }

var combat_state: CombatState = CombatState.IDLE
var tick_counter: int = 0

# ── Current attack ────────────────────────────────────────────────────────────
var current_attack: AttackData = null
var hit_this_swing: Dictionary = {}   # { hurtbox_node: true } per-swing dedup

# ── Weapon state ──────────────────────────────────────────────────────────────
# active_weapon_id tracks which weapon is currently held.
# Used to scope attack selection and ultimate casting.
# Extend this when a second weapon is added.
var active_weapon_id: String = "sword"

# ── Attack library ────────────────────────────────────────────────────────────
# Keyed by attack_id. Add additional weapon attacks here (or load from .tres).
var attacks: Dictionary = {}

# ── Node references ───────────────────────────────────────────────────────────
@onready var _hitbox: Area2D            = $"../WeaponHolder/Sword/LightAttack/HitboxSL"
@onready var _sword: Node2D             = $"../WeaponHolder/Sword"
@onready var _anim: AnimatedSprite2D    = $"../Body"
@onready var _combo: Node               = $"../ComboTracker"
@onready var _player: CharacterBody2D   = get_parent()


func _ready() -> void:
	# ── Default attack data ───────────────────────────────────────────────────
	# Damage is FLAT — every sword light attack deals 10.0 regardless of chain.
	# weapon_id and attack_type are used by ComboTracker to build combo keys.

	var sword_light := AttackData.new()
	sword_light.attack_id           = "sword_light"
	sword_light.weapon_id           = "sword"
	sword_light.attack_type         = "light"
	sword_light.startup_frames      = 10
	sword_light.active_frames       = 1
	sword_light.recovery_frames     = 10
	sword_light.damage              = 10.0
	sword_light.knockback_force     = 220.0
	sword_light.knockback_angle_deg = 35.0
	sword_light.hitstun_frames      = 12
	attacks["sword_light"] = sword_light

	# Future weapons — add entries here. Example:
	#   var bow_light := AttackData.new()
	#   bow_light.attack_id   = "bow_light"
	#   bow_light.weapon_id   = "bow"
	#   bow_light.attack_type = "light"
	#   bow_light.damage      = 7.0
	#   attacks["bow_light"]  = bow_light

	_hitbox.monitoring = false


# ── Main tick ─────────────────────────────────────────────────────────────────
func tick(input: InputSnapshot, dash_attack_locked: bool = false) -> void:
	tick_counter += 1

	# Weapon switch is checked first — it can interrupt everything except hitstun.
	if input.weapon_switch_pressed and combat_state != CombatState.HITSTUN:
		_handle_weapon_switch()

	# Ultimate cast — only allowed when IDLE (no attack in progress).
	# Attempting it mid-combo does nothing; the slot stays ready.
	if input.ultimate_pressed and combat_state == CombatState.IDLE:
		_combo.try_cast_ultimate(active_weapon_id)

	_process_combat_state(input, dash_attack_locked)


# ── Public queries ────────────────────────────────────────────────────────────

func can_move() -> bool:
	return combat_state == CombatState.IDLE

func is_busy() -> bool:
	return combat_state != CombatState.IDLE

func get_state() -> CombatState:
	return combat_state


# ── Weapon switch ─────────────────────────────────────────────────────────────
# Called when input.weapon_switch_pressed fires.
# Clears the combo chain (earned ultimates are preserved in ComboTracker).
# Extend the match block when more weapons are added.

func _handle_weapon_switch() -> void:
	# TODO: cycle through available weapons when more are added.
	# For now with only the sword this is a no-op in terms of visual change,
	# but the chain-clear still fires correctly for future use.
	var next_weapon_id: String = _get_next_weapon_id()
	if next_weapon_id == active_weapon_id:
		return  # only one weapon in the pool — nothing to switch to yet

	active_weapon_id = next_weapon_id
	_combo.weapon_switched(active_weapon_id)

	# TODO: hide current weapon node, show next weapon node.
	print("[Combat] Weapon switched → '%s'" % active_weapon_id)


func _get_next_weapon_id() -> String:
	# Weapon rotation order. Add entries here as weapons are implemented.
	var weapon_pool: Array[String] = ["sword"]  # add "bow" here when ready
	var idx: int = weapon_pool.find(active_weapon_id)
	return weapon_pool[(idx + 1) % weapon_pool.size()]


# ── State machine ─────────────────────────────────────────────────────────────

func _process_combat_state(input: InputSnapshot, dash_attack_locked: bool = false) -> void:
	match combat_state:

		CombatState.IDLE:
			if input.light_attack_pressed and not dash_attack_locked:
				_begin_attack(_select_attack(input))

		CombatState.STARTUP:
			if tick_counter >= current_attack.startup_end_tick:
				_enter_active()

		CombatState.ACTIVE:
			_query_hits()
			if tick_counter >= current_attack.active_end_tick:
				_enter_recovery()

		CombatState.RECOVERY:
			if tick_counter >= current_attack.recovery_end_tick:
				_enter_idle()

		CombatState.HITSTUN:
			if tick_counter >= _hitstun_end_tick:
				_enter_idle()


# ── State transitions ─────────────────────────────────────────────────────────

func _begin_attack(data: AttackData) -> void:
	current_attack = data
	current_attack.compute_ticks(tick_counter)
	hit_this_swing.clear()
	combat_state = CombatState.STARTUP

	_sword.execute_attack(data, _player.last_aim_direction)
	_anim.play("idle_" + _dir_suffix(_player.last_dir_vector))

	print("[Combat] STARTUP — attack:%s  startup_end:%d  active_end:%d  recovery_end:%d"
		% [data.attack_id, data.startup_end_tick, data.active_end_tick, data.recovery_end_tick])


func _enter_active() -> void:
	combat_state = CombatState.ACTIVE
	_hitbox.monitoring = true
	print("[Combat] ACTIVE — tick:%d" % tick_counter)


func _enter_recovery() -> void:
	combat_state = CombatState.RECOVERY
	_hitbox.monitoring = false
	print("[Combat] RECOVERY — tick:%d" % tick_counter)


func _enter_idle() -> void:
	combat_state = CombatState.IDLE
	_hitbox.monitoring = false
	hit_this_swing.clear()
	current_attack = null
	_sword.visible = false
	print("[Combat] IDLE — tick:%d" % tick_counter)


# ── Hit registration ──────────────────────────────────────────────────────────

func _query_hits() -> void:
	for area in _hitbox.get_overlapping_areas():
		if not area.is_in_group("enemy_hurtbox"):
			continue
		if hit_this_swing.has(area):
			continue

		hit_this_swing[area] = true

		var hit := _build_hit_data(area)
		area.hit_received.emit(hit)

		# Forward confirmed hit to ComboTracker — this is the ONLY place the chain grows.
		_combo.record_hit(current_attack)

		print("[Combat] HIT — target:%s  dmg:%.1f  chain:%d/3  ultimate_ready:%s"
			% [area.get_parent().name, hit.damage,
			   _combo.get_chain_length(),
			   str(_combo.has_ultimate_ready(active_weapon_id))])


func _build_hit_data(target_hurtbox: Area2D) -> HitData:
	var hit := HitData.new()
	hit.attacker       = _player
	hit.attack_id      = current_attack.attack_id
	hit.damage         = current_attack.damage   # FLAT — never modified by combo
	hit.hitstun_frames = current_attack.hitstun_frames

	var to_target  := (target_hurtbox.global_position - _player.global_position).normalized()
	var angle_rad  := deg_to_rad(current_attack.knockback_angle_deg)
	var kb_dir     := Vector2(to_target.x, -abs(sin(angle_rad))).normalized()
	hit.knockback_vector = kb_dir * current_attack.knockback_force

	return hit


# ── Hitstun ───────────────────────────────────────────────────────────────────

var _hitstun_end_tick: int = 0

func enter_hitstun(frames: int) -> void:
	combat_state = CombatState.HITSTUN
	_hitbox.monitoring = false
	_hitstun_end_tick = tick_counter + frames
	hit_this_swing.clear()
	print("[Combat] HITSTUN for %d frames" % frames)


# ── Attack selection ──────────────────────────────────────────────────────────

func _select_attack(_input: InputSnapshot) -> AttackData:
	# Route to the correct attack based on active weapon.
	# Extend the match block when more weapons are added.
	match active_weapon_id:
		"sword":
			return attacks["sword_light"]
		# "bow":
		#     return attacks["bow_light"]
		_:
			return attacks["sword_light"]


# ── Helpers ───────────────────────────────────────────────────────────────────

func _dir_suffix(dir: Vector2) -> String:
	if abs(dir.x) > abs(dir.y):
		return "right" if dir.x > 0 else "left"
	return "down" if dir.y > 0 else "up"
