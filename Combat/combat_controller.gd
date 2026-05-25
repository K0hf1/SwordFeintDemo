# combat_controller.gd
# Authoritative combat state machine. Child of Player.
#
# ── OWNS ──────────────────────────────────────────────────────────────────────
#   Combat state, tick progression, frame data, hit registration,
#   RPS resolution (light/heavy/parry/guard), weapon switch routing,
#   ultimate input routing.
#
# ── DOES NOT OWN ──────────────────────────────────────────────────────────────
#   Movement, rendering, input collection, combo chain tracking.
#
# ── RPS SYSTEM ────────────────────────────────────────────────────────────────
#   HEAVY beats LIGHT:
#     If this player is in an ARMORED (heavy) ACTIVE state and a light hitbox
#     overlaps our hurtbox, the light hit is suppressed — the heavy lands.
#     Implemented in on_hit_incoming() which hurtbox.gd calls on us.
#
#   PARRY beats HEAVY:
#     When parry_pressed fires and state permits, Parry.begin_parry() opens a window.
#     Incoming HitData is routed through Parry.on_hit_incoming() first.
#     If parried, the hit is suppressed and damage is reflected.
#
#   LIGHT beats PARRY:
#     Parry.on_hit_incoming() returns false for light attacks — they land normally.
#
#   GUARD (Shift held):
#     Reduces damage and blocks combo credit on hits that land.
#     Does NOT stop the hit from registering — it modifies the outcome.
#     Player moves at walk speed while guarding.
#
# ── SCENE SETUP ───────────────────────────────────────────────────────────────
#   Player
#     ├── CombatController   ← this script
#     ├── ComboTracker
#     ├── Parry
#     └── WeaponHolder
#           └── Sword
#               ├── LightAttack / HitboxSL
#               └── HeavyAttack / HitboxSH
#
extends Node

# ── State ─────────────────────────────────────────────────────────────────────
enum CombatState { IDLE, STARTUP, ACTIVE, RECOVERY, HITSTUN, PARRYING }

var combat_state: CombatState = CombatState.IDLE
var tick_counter: int = 0

# ── Current attack ────────────────────────────────────────────────────────────
var current_attack: AttackData = null
var hit_this_swing: Dictionary = {}

# ── Weapon state ──────────────────────────────────────────────────────────────
var active_weapon_id: String = "sword"

# ── Guard state ───────────────────────────────────────────────────────────────
# Mirrors input.guard_held each tick. Readable by player.gd for movement speed.
var is_guarding: bool = false

# Damage multiplier applied to hits received while guarding.
const GUARD_DAMAGE_MULTIPLIER: float = 0.35

# ── Attack library ────────────────────────────────────────────────────────────
var attacks: Dictionary = {}

# ── Node references ───────────────────────────────────────────────────────────
@onready var _sword:    Node2D           = $"../WeaponHolder/Sword"
@onready var _anim:     AnimatedSprite2D = $"../Body"
@onready var _combo:    Node             = $"../ComboTracker"
@onready var _parry:    Node             = $"../Parry"
@onready var _player:   CharacterBody2D  = get_parent()
@onready var _hurtbox:  PlayerHurtbox    = $"../Hurtbox"

# Active hitbox reference — swapped per attack type
var _active_hitbox: Area2D = null


func _ready() -> void:
	# ── Sword Light ───────────────────────────────────────────────────────────
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
	sword_light.is_armored          = false
	attacks["sword_light"] = sword_light

	# ── Sword Heavy (stab) ────────────────────────────────────────────────────
	# Longer startup (wind-up), fewer active frames (precise thrust),
	# moderate recovery. is_armored = true — crushes any incoming light attack.
	var sword_heavy := AttackData.new()
	sword_heavy.attack_id           = "sword_heavy"
	sword_heavy.weapon_id           = "sword"
	sword_heavy.attack_type         = "heavy"
	sword_heavy.startup_frames      = 22   # ~367ms wind-up — punishable if read
	sword_heavy.active_frames       = 3
	sword_heavy.recovery_frames     = 18
	sword_heavy.damage              = 18.0
	sword_heavy.knockback_force     = 350.0
	sword_heavy.knockback_angle_deg = 15.0  # low angle — stab pushes horizontal
	sword_heavy.hitstun_frames      = 20
	sword_heavy.is_armored          = true  # CRUSHES light attacks
	attacks["sword_heavy"] = sword_heavy

	# Future weapons: add here or load from .tres
	# e.g. attacks["bow_light"] = ...

	# Connect hurtbox signal so incoming hits route through our RPS resolver
	_hurtbox.hit_received.connect(_on_hit_incoming)

	# Hitboxes start inactive — _active_hitbox is nil until an attack begins
	_get_hitbox("light").monitoring = false
	_get_hitbox("heavy").monitoring = false


# ── Main tick ─────────────────────────────────────────────────────────────────
func tick(input: InputSnapshot, dash_attack_locked: bool = false) -> void:
	tick_counter += 1

	# Update guard state from input — readable by player.gd for speed scaling
	is_guarding = input.guard_held

	# Weapon switch — any state except HITSTUN
	if input.weapon_switch_pressed and combat_state != CombatState.HITSTUN:
		_handle_weapon_switch()

	# Ultimate — IDLE only (slot stays ready if busy)
	if input.ultimate_pressed and combat_state == CombatState.IDLE:
		_combo.try_cast_ultimate(active_weapon_id)

	# Advance parry window if one is open
	if _parry.is_active():
		_parry.tick_parry_window(tick_counter)

	_process_combat_state(input, dash_attack_locked)


# ── Public queries ─────────────────────────────────────────────────────────────
func can_move() -> bool:
	return combat_state == CombatState.IDLE

func is_busy() -> bool:
	return combat_state != CombatState.IDLE

func get_state() -> CombatState:
	return combat_state


# ── Weapon switch ─────────────────────────────────────────────────────────────
func _handle_weapon_switch() -> void:
	var next: String = _get_next_weapon_id()
	if next == active_weapon_id:
		return
	active_weapon_id = next
	_combo.weapon_switched(active_weapon_id)
	# TODO: hide/show weapon visual nodes
	print("[Combat] Weapon switched → '%s'" % active_weapon_id)


func _get_next_weapon_id() -> String:
	var pool: Array[String] = ["sword"]   # add "bow" etc. here
	var idx := pool.find(active_weapon_id)
	return pool[(idx + 1) % pool.size()]


# ── State machine ─────────────────────────────────────────────────────────────
func _process_combat_state(input: InputSnapshot, dash_attack_locked: bool = false) -> void:
	match combat_state:

		CombatState.IDLE:
			# Parry takes priority over attack inputs
			if input.parry_pressed:
				_enter_parrying()
			elif input.heavy_attack_pressed and not dash_attack_locked:
				_begin_attack(attacks[active_weapon_id + "_heavy"])
			elif input.light_attack_pressed and not dash_attack_locked:
				_begin_attack(attacks[active_weapon_id + "_light"])

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

		CombatState.PARRYING:
			# Parry window is ticked above in the main tick() function.
			# When the window closes (success or whiff) the Parry node emits
			# its signal. We listen via _on_parry_ended() connected in _ready().
			# Nothing else to do here per-tick.
			pass


# ── State transitions ─────────────────────────────────────────────────────────
func _begin_attack(data: AttackData) -> void:
	current_attack = data
	current_attack.compute_ticks(tick_counter)
	hit_this_swing.clear()
	combat_state = CombatState.STARTUP

	_active_hitbox = _get_hitbox(data.attack_type)
	_active_hitbox.monitoring = false   # ensure clean start

	_sword.execute_attack(data, _player.last_aim_direction)
	_anim.play("idle_" + _dir_suffix(_player.last_dir_vector))

	print("[Combat] STARTUP — %s  startup_end:%d  active_end:%d  recovery_end:%d"
		% [data.attack_id, data.startup_end_tick, data.active_end_tick, data.recovery_end_tick])


func _enter_active() -> void:
	combat_state = CombatState.ACTIVE
	if _active_hitbox:
		_active_hitbox.monitoring = true
	print("[Combat] ACTIVE — tick:%d  armored:%s" % [tick_counter, str(current_attack.is_armored)])


func _enter_recovery() -> void:
	combat_state = CombatState.RECOVERY
	if _active_hitbox:
		_active_hitbox.monitoring = false
	print("[Combat] RECOVERY — tick:%d" % tick_counter)


func _enter_idle() -> void:
	combat_state = CombatState.IDLE
	if _active_hitbox:
		_active_hitbox.monitoring = false
	hit_this_swing.clear()
	current_attack = null
	_active_hitbox = null
	_sword.visible = false
	print("[Combat] IDLE — tick:%d" % tick_counter)


func _enter_parrying() -> void:
	combat_state = CombatState.PARRYING
	_parry.begin_parry(tick_counter)
	# Listen for parry window close so we return to IDLE
	if not _parry.parry_whiff.is_connected(_on_parry_ended):
		_parry.parry_whiff.connect(_on_parry_ended)
	if not _parry.parry_success.is_connected(_on_parry_success):
		_parry.parry_success.connect(_on_parry_success)
	print("[Combat] PARRYING — tick:%d" % tick_counter)


func _on_parry_ended() -> void:
	if combat_state == CombatState.PARRYING:
		_enter_idle()


func _on_parry_success(_attacker: Node2D, _reflected_damage: float) -> void:
	if combat_state == CombatState.PARRYING:
		_enter_idle()


# ── Hit registration (outgoing — this player's hitbox hitting enemies) ─────────
func _query_hits() -> void:
	if _active_hitbox == null:
		return

	for area in _active_hitbox.get_overlapping_areas():
		# Accept any hurtbox in the universal "hurtbox" group.
		# Self-hit guard: skip our own Hurtbox node (same CharacterBody2D parent).
		if not area.is_in_group("hurtbox"):
			continue
		if area.get_parent() == _player:
			continue
		if hit_this_swing.has(area):
			continue

		hit_this_swing[area] = true

		var hit := _build_hit_data(area)
		# area comes back as base Area2D from get_overlapping_areas().
		# hit_received is defined on Hurtbox and PlayerHurtbox, not Area2D.
		# We must call through the typed signal — use has_signal as a safety
		# net then emit via the node's own signal object.
		if area.has_signal("hit_received"):
			area.emit_signal("hit_received", hit)

		# Only record combo credit if the target is NOT guarded.
		# The hit still lands (reduced damage) but contributes nothing to the chain.
		var target_combat: Node = _get_combat_controller(area.get_parent())
		var target_guarded: bool = target_combat != null and target_combat.is_guarding

		if not target_guarded:
			_combo.record_hit(current_attack)
			print("[Combat] HIT — target:%s  dmg:%.1f  chain:%d/3  ult_ready:%s"
				% [area.get_parent().name, hit.damage,
				   _combo.get_chain_length(),
				   str(_combo.has_ultimate_ready(active_weapon_id))])
		else:
			print("[Combat] HIT (GUARDED) — target:%s  dmg:%.1f  no combo credit"
				% [area.get_parent().name, hit.damage * GUARD_DAMAGE_MULTIPLIER])


func _build_hit_data(target_hurtbox: Area2D) -> HitData:
	var hit         := HitData.new()
	hit.attacker     = _player
	hit.attack_id    = current_attack.attack_id
	hit.attack_type  = current_attack.attack_type
	hit.damage       = current_attack.damage       # FLAT — never modified by combo
	hit.hitstun_frames = current_attack.hitstun_frames
	hit.is_reflected = false

	var to_target  := (target_hurtbox.global_position - _player.global_position).normalized()
	var angle_rad  := deg_to_rad(current_attack.knockback_angle_deg)
	var kb_dir     := Vector2(to_target.x, -abs(sin(angle_rad))).normalized()
	hit.knockback_vector = kb_dir * current_attack.knockback_force

	return hit


# ── Incoming hit resolver (connected to _hurtbox.hit_received) ────────────────
# This is the RPS resolution point for hits landing ON this player.
func _on_hit_incoming(hit: HitData) -> void:
	# ── PARRY CHECK ───────────────────────────────────────────────────────────
	# Parry window is open: route through Parry node.
	# If it returns true, the hit is absorbed and reflected — suppress it.
	if _parry.is_active():
		if _parry.on_hit_incoming(hit, active_weapon_id):
			return   # parried — take no damage, no hitstun

	# ── ARMOR CHECK (heavy crushes light) ────────────────────────────────────
	# If WE are currently throwing a heavy (ACTIVE, is_armored) and a LIGHT hit arrives,
	# the light is crushed. Our heavy proceeds; we take nothing from the light.
	if combat_state == CombatState.ACTIVE \
	and current_attack != null \
	and current_attack.is_armored \
	and hit.attack_type == "light":
		print("[Combat] ARMOR — heavy crushes incoming light from '%s'" % hit.attacker.name)
		return   # light hit suppressed — heavy is uninterrupted

	# ── GUARD CHECK ───────────────────────────────────────────────────────────
	# Guard reduces damage and blocks combo credit on the attacker's side.
	# Combo credit is already blocked in _query_hits() on the attacker.
	# Here we just scale the damage before applying it.
	var effective_damage := hit.damage
	if is_guarding:
		effective_damage *= GUARD_DAMAGE_MULTIPLIER
		print("[Combat] GUARD — damage reduced to %.1f" % effective_damage)

	# ── APPLY HIT ────────────────────────────────────────────────────────────
	# Deliver damage to this player's health system.
	# For now, just enter hitstun. Hook up to a HealthComponent when ready.
	enter_hitstun(hit.hitstun_frames)

	# TODO: apply effective_damage to health component:
	# $HealthComponent.take_damage(effective_damage)
	print("[Combat] TOOK HIT — atk:%s  dmg:%.1f  hitstun:%d"
		% [hit.attack_id, effective_damage, hit.hitstun_frames])


# ── Hitstun ───────────────────────────────────────────────────────────────────
var _hitstun_end_tick: int = 0

func enter_hitstun(frames: int) -> void:
	combat_state = CombatState.HITSTUN
	if _active_hitbox:
		_active_hitbox.monitoring = false
	_hitstun_end_tick = tick_counter + frames
	hit_this_swing.clear()
	print("[Combat] HITSTUN for %d frames" % frames)


# ── Attack selection ──────────────────────────────────────────────────────────
func _select_attack(input: InputSnapshot) -> AttackData:
	var type_key := "heavy" if input.heavy_attack_pressed else "light"
	var key := active_weapon_id + "_" + type_key
	return attacks.get(key, attacks[active_weapon_id + "_light"])


# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns the hitbox node for the given attack type on the active weapon.
func _get_hitbox(attack_type: String) -> Area2D:
	match attack_type:
		"light":
			return _sword.get_node("LightAttack/HitboxSL")
		"heavy":
			return _sword.get_node("HeavyAttack/HitboxSH")
		_:
			return _sword.get_node("LightAttack/HitboxSL")


# Attempts to find a CombatController on the given node (for guard check).
# Returns null if the node has no CombatController (e.g. a dummy).
func _get_combat_controller(target: Node) -> Node:
	for child in target.get_children():
		if child.get_script() != null and child.name == "CombatController":
			return child
	return null


func _dir_suffix(dir: Vector2) -> String:
	if abs(dir.x) > abs(dir.y):
		return "right" if dir.x > 0 else "left"
	return "down" if dir.y > 0 else "up"
