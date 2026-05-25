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
#
#   PARRY beats HEAVY:
#     When parry_pressed fires and state permits, Parry.begin_parry() opens a window.
#     Incoming HitData is routed through Parry.on_hit_incoming() first.
#     If parried, hit.was_parried is set true on the HitData object, the hit is
#     suppressed for this player, damage is reflected, and the PARRIER gets H combo credit.
#     The ATTACKER's _query_hits() detects was_parried == true and skips record_hit().
#
#   LIGHT beats PARRY:
#     Parry.on_hit_incoming() returns false for light attacks — they land normally.
#
#   GUARD (Shift held):
#     Reduces damage and blocks combo credit on hits that land.
#     Does NOT stop the hit from registering — it modifies the outcome.
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
var is_guarding: bool = false
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
@onready var _health:   PlayerHealth     = $"../PlayerHealth"

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
	var sword_heavy := AttackData.new()
	sword_heavy.attack_id           = "sword_heavy"
	sword_heavy.weapon_id           = "sword"
	sword_heavy.attack_type         = "heavy"
	sword_heavy.startup_frames      = 22
	sword_heavy.active_frames       = 3
	sword_heavy.recovery_frames     = 18
	sword_heavy.damage              = 18.0
	sword_heavy.knockback_force     = 350.0
	sword_heavy.knockback_angle_deg = 15.0
	sword_heavy.hitstun_frames      = 20
	sword_heavy.is_armored          = true
	attacks["sword_heavy"] = sword_heavy

	_hurtbox.hit_received.connect(_on_hit_incoming)

	# Wire parry signals once here — NOT in _enter_parrying().
	# Connecting inside _enter_parrying() was safe only as long as begin_parry()
	# always succeeded. When it returns false (cooldown), the state was already
	# set to PARRYING with no window open and no whiff signal ever firing —
	# permanently freezing the player. Wiring here avoids the conditional entirely.
	_parry.parry_whiff.connect(_on_parry_ended)
	_parry.parry_success.connect(_on_parry_success)

	_get_hitbox("light").monitoring = false
	_get_hitbox("heavy").monitoring = false


# ── Main tick ─────────────────────────────────────────────────────────────────
func tick(input: InputSnapshot, dash_attack_locked: bool = false) -> void:
	tick_counter += 1

	is_guarding = input.guard_held

	if input.weapon_switch_pressed and combat_state != CombatState.HITSTUN:
		_handle_weapon_switch()

	if input.ultimate_pressed and combat_state == CombatState.IDLE:
		_combo.try_cast_ultimate(active_weapon_id)

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
	print("[Combat] [%s] Weapon switched → '%s'" % [_player.name, active_weapon_id])


func _get_next_weapon_id() -> String:
	var pool: Array[String] = ["sword"]
	var idx := pool.find(active_weapon_id)
	return pool[(idx + 1) % pool.size()]


# ── State machine ─────────────────────────────────────────────────────────────
func _process_combat_state(input: InputSnapshot, dash_attack_locked: bool = false) -> void:
	match combat_state:

		CombatState.IDLE:
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
			pass


# ── State transitions ─────────────────────────────────────────────────────────
func _begin_attack(data: AttackData) -> void:
	current_attack = data
	current_attack.compute_ticks(tick_counter)
	hit_this_swing.clear()
	combat_state = CombatState.STARTUP

	_active_hitbox = _get_hitbox(data.attack_type)
	_active_hitbox.monitoring = false

	_sword.execute_attack(data, _player.last_aim_direction)
	_anim.play("idle_" + _dir_suffix(_player.last_dir_vector))

	print("[Combat] [%s] STARTUP — %s  startup_end:%d  active_end:%d  recovery_end:%d"
		% [_player.name, data.attack_id, data.startup_end_tick, data.active_end_tick, data.recovery_end_tick])


func _enter_active() -> void:
	combat_state = CombatState.ACTIVE
	if _active_hitbox:
		_active_hitbox.monitoring = true
	print("[Combat] [%s] ACTIVE — tick:%d  armored:%s" % [_player.name, tick_counter, str(current_attack.is_armored)])


func _enter_recovery() -> void:
	combat_state = CombatState.RECOVERY
	if _active_hitbox:
		_active_hitbox.monitoring = false
	print("[Combat] [%s] RECOVERY — tick:%d" % [_player.name, tick_counter])


func _enter_idle() -> void:
	combat_state = CombatState.IDLE
	if _active_hitbox:
		_active_hitbox.monitoring = false
	hit_this_swing.clear()
	current_attack = null
	_active_hitbox = null
	_sword.visible = false
	print("[Combat] [%s] IDLE — tick:%d" % [_player.name, tick_counter])


func _enter_parrying() -> void:
	# Only enter PARRYING state if the window actually opens.
	# begin_parry() returns false when on cooldown or already active.
	# Setting combat_state = PARRYING without an open window means parry_whiff
	# never fires, _on_parry_ended never runs, and the player freezes permanently.
	if not _parry.begin_parry(tick_counter):
		return   # on cooldown — stay in IDLE, do nothing
	combat_state = CombatState.PARRYING
	print("[Combat] [%s] PARRYING — tick:%d" % [_player.name, tick_counter])


func _on_parry_ended() -> void:
	if combat_state == CombatState.PARRYING:
		_enter_idle()


# parry_success now carries parrier_combo so we can award H credit here.
func _on_parry_success(_attacker: Node2D, _reflected_damage: float, parrier_combo: Node) -> void:
	if combat_state == CombatState.PARRYING:
		# Award Heavy hit credit to the parrier's combo chain.
		# All normal combo rules apply (ult-held block, chain expiry, etc.)
		if parrier_combo != null:
			parrier_combo.record_parry_hit(active_weapon_id)
		_enter_idle()


# ── Hit registration (outgoing — this player's hitbox hitting enemies) ─────────
func _query_hits() -> void:
	if _active_hitbox == null:
		return

	for area in _active_hitbox.get_overlapping_areas():
		if not area.is_in_group("hurtbox"):
			continue
		if area.get_parent() == _player:
			continue
		if hit_this_swing.has(area):
			continue

		hit_this_swing[area] = true

		var hit := _build_hit_data(area)
		if area.has_signal("hit_received"):
			area.emit_signal("hit_received", hit)

		# ── Check if the hit was parried ──────────────────────────────────────
		# Parry.on_hit_incoming() sets hit.was_parried = true when it intercepts.
		# If parried: skip combo credit and the HIT log entirely — the parrier
		# handles their own combo credit via record_parry_hit() in _on_parry_success().
		if hit.was_parried:
			print("[Combat] [%s] HIT PARRIED by %s — no combo credit awarded to attacker."
				% [_player.name, area.get_parent().name])
			continue

		# ── Normal hit path ───────────────────────────────────────────────────
		var target_combat: Node = _get_combat_controller(area.get_parent())
		var target_guarded: bool = target_combat != null and target_combat.is_guarding

		if not target_guarded:
			_combo.record_hit(current_attack)
			print("[Combat] [%s] HIT — target:%s  dmg:%.1f  chain:%d/3  ult_ready:%s"
				% [_player.name, area.get_parent().name, hit.damage,
				   _combo.get_chain_length(),
				   str(_combo.has_ultimate_ready(active_weapon_id))])
		else:
			print("[Combat] [%s] HIT (GUARDED) — target:%s  dmg:%.1f  no combo credit"
				% [_player.name, area.get_parent().name, hit.damage * GUARD_DAMAGE_MULTIPLIER])


func _build_hit_data(target_hurtbox: Area2D) -> HitData:
	var hit         := HitData.new()
	hit.attacker     = _player
	hit.attack_id    = current_attack.attack_id
	hit.attack_type  = current_attack.attack_type
	hit.damage       = current_attack.damage
	hit.hitstun_frames = current_attack.hitstun_frames
	hit.is_reflected = false

	var to_target  := (target_hurtbox.global_position - _player.global_position).normalized()
	var angle_rad  := deg_to_rad(current_attack.knockback_angle_deg)
	var kb_dir     := Vector2(to_target.x, -abs(sin(angle_rad))).normalized()
	hit.knockback_vector = kb_dir * current_attack.knockback_force

	return hit


# ── Incoming hit resolver (connected to _hurtbox.hit_received) ────────────────
# CombatController is the SOLE subscriber to hit_received.
# It runs every RPS check in sequence. Only if ALL checks pass does it call
# _health.apply_hit() — PlayerHealth never sees suppressed hits.
#
# Execution order guarantee:
#   hit_received fires → this handler runs → RPS resolved → apply_hit() called
#   PlayerHealth.apply_hit() is a plain method call, NOT a signal subscriber,
#   so there is no race between two independent signal handlers.
func _on_hit_incoming(hit: HitData) -> void:
	# ── PARRY CHECK ───────────────────────────────────────────────────────────
	# Must be first. Parry sets hit.was_parried = true and reflects damage back.
	# Return immediately — no hitstun, no HP loss for the defender.
	if _parry.is_active():
		if _parry.on_hit_incoming(hit, active_weapon_id):
			return   # parried — fully suppressed, reflection already queued

	# ── ARMOR CHECK ───────────────────────────────────────────────────────────
	if combat_state == CombatState.ACTIVE \
	and current_attack != null \
	and current_attack.is_armored \
	and hit.attack_type == "light":
		print("[Combat] [%s] ARMOR — heavy crushes incoming light from '%s'" % [_player.name, hit.attacker.name])
		return

	# ── GUARD CHECK ───────────────────────────────────────────────────────────
	var effective_damage := hit.damage
	if is_guarding:
		effective_damage *= GUARD_DAMAGE_MULTIPLIER
		print("[Combat] [%s] GUARD — damage reduced to %.1f" % [_player.name, effective_damage])

	# ── APPLY HIT ────────────────────────────────────────────────────────────
	# All checks passed. Hitstun first, then health — order matches the log.
	enter_hitstun(hit.hitstun_frames)
	print("[Combat] [%s] TOOK HIT — atk:%s  dmg:%.1f  hitstun:%d"
		% [_player.name, hit.attack_id, effective_damage, hit.hitstun_frames])
	# Pass flash_reflected=true for parry reflections so PlayerHealth flashes
	# the original attacker's sprite, not the defender's.
	_health.apply_hit(hit, hit.is_reflected)


# ── Hitstun ───────────────────────────────────────────────────────────────────
var _hitstun_end_tick: int = 0

func enter_hitstun(frames: int) -> void:
	combat_state = CombatState.HITSTUN
	if _active_hitbox:
		_active_hitbox.monitoring = false
	_hitstun_end_tick = tick_counter + frames
	hit_this_swing.clear()
	print("[Combat] [%s] HITSTUN for %d frames" % [_player.name, frames])


# ── Attack selection ──────────────────────────────────────────────────────────
func _select_attack(input: InputSnapshot) -> AttackData:
	var type_key := "heavy" if input.heavy_attack_pressed else "light"
	var key := active_weapon_id + "_" + type_key
	return attacks.get(key, attacks[active_weapon_id + "_light"])


# ── Helpers ───────────────────────────────────────────────────────────────────

func _get_hitbox(attack_type: String) -> Area2D:
	match attack_type:
		"light":
			return _sword.get_node("LightAttack/HitboxSL")
		"heavy":
			return _sword.get_node("HeavyAttack/HitboxSH")
		_:
			return _sword.get_node("LightAttack/HitboxSL")


func _get_combat_controller(target: Node) -> Node:
	for child in target.get_children():
		if child.get_script() != null and child.name == "CombatController":
			return child
	return null


func _dir_suffix(dir: Vector2) -> String:
	if abs(dir.x) > abs(dir.y):
		return "right" if dir.x > 0 else "left"
	return "down" if dir.y > 0 else "up"
