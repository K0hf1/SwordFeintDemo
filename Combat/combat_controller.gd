# combat_controller.gd
# The authoritative combat state machine. Attach as a child of Player.
#
# Owns: combat state, tick progression, frame data, hit registration.
# Does NOT own: movement, rendering, input collection, or combo chain logic.
#
# COMBO DESIGN:
#   - Damage is always flat from AttackData — never modified by combo state.
#   - Only confirmed hits (hitbox overlaps enemy hurtbox) are forwarded to ComboTracker.
#   - Whiffed attacks (no contact) do NOT advance the chain.
#   - Weapon switching (call notify_weapon_switched()) clears the chain via ComboTracker.
#
# Node setup:
#   Player
#     ├── CombatController   ← this script
#     └── ComboTracker       ← sibling, handles chain recording
#
# Requires these @onready paths to match your scene tree:
#   @onready var _hitbox  = $"../WeaponHolder/Sword/LightAttack/HitboxSL"
#   @onready var _sword   = $"../WeaponHolder/Sword"
#   @onready var _anim    = $"../Body"
#   @onready var _combo   = $"../ComboTracker"
#
extends Node

# ── State ─────────────────────────────────────────────────────────────────────
enum CombatState { IDLE, STARTUP, ACTIVE, RECOVERY, HITSTUN }

var combat_state: CombatState = CombatState.IDLE
var tick_counter: int = 0          # monotonically increasing, never reset

# ── Current attack ────────────────────────────────────────────────────────────
var current_attack: AttackData = null
var hit_this_swing: Dictionary = {}   # { hurtbox_node: true } — per-swing dedup registry

# ── Attack library ────────────────────────────────────────────────────────────
# Keyed by attack_id string. Add more weapons by adding more entries here,
# or (preferred) load them from .tres resources via @export.
# @export var attack_sword_light: AttackData
var attacks: Dictionary = {}

# ── Node references (adjust paths to match your scene tree) ──────────────────
@onready var _hitbox: Area2D            = $"../WeaponHolder/Sword/LightAttack/HitboxSL"
@onready var _sword: Node2D             = $"../WeaponHolder/Sword"
@onready var _anim: AnimatedSprite2D    = $"../Body"
@onready var _combo: Node               = $"../ComboTracker"
@onready var _player: CharacterBody2D   = get_parent()


func _ready() -> void:
	# ── Build default attack data ─────────────────────────────────────────────
	# Replace with .tres @exports when ready. This keeps the game runnable
	# without any Inspector wiring.
	#
	# DAMAGE IS FLAT. There is no "light2" with reduced damage.
	# Every sword light attack deals the same damage regardless of chain position.
	# The combo chain records what hit — it does not change what hits cost.

	var sword_light := AttackData.new()
	sword_light.attack_id          = "sword_light"
	sword_light.weapon_id          = "sword"
	sword_light.attack_type        = "light"
	sword_light.startup_frames     = 10
	sword_light.active_frames      = 1
	sword_light.recovery_frames    = 10
	sword_light.damage             = 10.0   # FLAT — never changes
	sword_light.knockback_force    = 220.0
	sword_light.knockback_angle_deg = 35.0
	sword_light.hitstun_frames     = 12
	attacks["sword_light"] = sword_light

	# Future weapons: add their attacks here with appropriate weapon_id values.
	# e.g.
	#   var bow_light := AttackData.new()
	#   bow_light.attack_id   = "bow_light"
	#   bow_light.weapon_id   = "bow"
	#   bow_light.attack_type = "light"
	#   bow_light.damage      = 7.0
	#   attacks["bow_light"]  = bow_light

	# Hitbox starts inactive
	_hitbox.monitoring = false


# ── Main tick — called by player._physics_process each frame ──────────────────
func tick(input: InputSnapshot, dash_attack_locked: bool = false) -> void:
	tick_counter += 1
	_process_combat_state(input, dash_attack_locked)


# ── Public queries for player.gd ──────────────────────────────────────────────

func can_move() -> bool:
	return combat_state == CombatState.IDLE

func is_busy() -> bool:
	return combat_state != CombatState.IDLE

func get_state() -> CombatState:
	return combat_state


# ── Weapon switch notification ────────────────────────────────────────────────
# Call this from player.gd whenever the player switches active weapons.
# This forwards to ComboTracker so the chain is cleared immediately.
#
# Example (in player.gd):
#   combat.notify_weapon_switched("bow")
#
func notify_weapon_switched(new_weapon_id: String) -> void:
	_combo.weapon_switched(new_weapon_id)
	# Additional per-controller cleanup if needed (e.g. hide current weapon visuals)
	print("[Combat] Weapon switched to '%s' — notified ComboTracker." % new_weapon_id)


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
			# NOTE: There is no combo cancel window here anymore.
			# The old system allowed pressing attack during recovery to chain into
			# "light2" with reduced damage — that was wrong per the design spec.
			# Combos are tracked by hit confirmation only, not by cancel windows.
			# Recovery simply runs its full duration and returns to IDLE.
			if tick_counter >= current_attack.recovery_end_tick:
				_enter_idle()

		CombatState.HITSTUN:
			if tick_counter >= _hitstun_end_tick:
				_enter_idle()


# ── State transitions ──────────────────────────────────────────────────────────

func _begin_attack(data: AttackData) -> void:
	current_attack = data
	current_attack.compute_ticks(tick_counter)
	hit_this_swing.clear()
	combat_state = CombatState.STARTUP

	# Tell the weapon executor to aim and start its visual
	_sword.execute_attack(data, _player.last_aim_direction)

	# Drive body animation (follows state, does not affect it)
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


# ── Hit registration (called each ACTIVE tick) ────────────────────────────────

func _query_hits() -> void:
	for area in _hitbox.get_overlapping_areas():
		if not area.is_in_group("enemy_hurtbox"):
			continue
		if hit_this_swing.has(area):
			continue  # already hit this target this swing — per-swing dedup

		hit_this_swing[area] = true

		# Build and emit the hit event
		var hit := _build_hit_data(area)
		area.hit_received.emit(hit)

		# Record this confirmed hit in the combo chain.
		# This is the ONLY place combo chain advances — on a confirmed hit, not on press.
		_combo.record_hit(current_attack)

		print("[Combat] HIT — target:%s  damage:%.1f  chain_length:%d"
			% [area.get_parent().name, hit.damage, _combo.get_chain_length()])


func _build_hit_data(target_hurtbox: Area2D) -> HitData:
	var hit := HitData.new()
	hit.attacker       = _player
	hit.attack_id      = current_attack.attack_id
	# Damage comes directly from AttackData — never modified by combo state.
	hit.damage         = current_attack.damage
	hit.hitstun_frames = current_attack.hitstun_frames

	# Knockback: direction from attacker to target, tilted upward by angle
	var to_target  := (target_hurtbox.global_position - _player.global_position).normalized()
	var angle_rad  := deg_to_rad(current_attack.knockback_angle_deg)
	var kb_dir     := Vector2(to_target.x, -abs(sin(angle_rad))).normalized()
	hit.knockback_vector = kb_dir * current_attack.knockback_force

	return hit


# ── Hitstun entry (called by health/damage system when this player is hit) ────

var _hitstun_end_tick: int = 0

func enter_hitstun(frames: int) -> void:
	combat_state = CombatState.HITSTUN
	_hitbox.monitoring = false
	_hitstun_end_tick = tick_counter + frames
	hit_this_swing.clear()
	print("[Combat] HITSTUN for %d frames" % frames)


# ── Attack selection ──────────────────────────────────────────────────────────
# Selects the correct AttackData for the active weapon and input state.
# Currently only the sword is implemented; add weapon routing here when
# additional weapons are added.

func _select_attack(_input: InputSnapshot) -> AttackData:
	# TODO: when weapon switching is added, read the active weapon_id from
	# the player and return the matching attack entry.
	# e.g.:
	#   match player.active_weapon_id:
	#       "sword": return attacks["sword_light"]
	#       "bow":   return attacks["bow_light"]
	return attacks["sword_light"]


# ── Helpers ───────────────────────────────────────────────────────────────────

func _dir_suffix(dir: Vector2) -> String:
	if abs(dir.x) > abs(dir.y):
		return "right" if dir.x > 0 else "left"
	return "down" if dir.y > 0 else "up"
