# combo_tracker.gd
# Tracks hit-confirmed combo chains and manages ultimate slot readiness.
# Attach as a child Node of Player (sibling to CombatController).
#
# ── DESIGN RULES ──────────────────────────────────────────────────────────────
#
#   1. Only CONFIRMED HITS on unguarded targets advance the chain.
#      Whiffed attacks and hits on guarded targets do NOT count.
#      CombatController calls record_hit() only after both conditions pass.
#      Successfully parried attacks are NOT counted as hits for the attacker.
#
#   2. Successful parries count as HEAVY hits in the PARRIER's chain.
#      CombatController._on_parry_success() calls record_parry_hit() which
#      injects an H token. All normal combo rules apply (including ult-held block).
#
#   3. The chain is per-weapon and weapon-scoped.
#      The first hit locks the chain to that weapon_id.
#      weapon_switched() clears the chain (ultimates are preserved).
#
#   4. "LLL" (light light light) is NOT a valid combo — no ultimate awarded.
#      All other 7 permutations of L/H across 3 hits are valid.
#
#   5. EXPIRY TIMER — 3.5 seconds.
#      If the player has not landed a hit in 3.5 seconds, the chain clears.
#      The timer resets on every confirmed hit AND when an ultimate slot is earned.
#      Earned but uncast ultimate slots also expire after 3.5 seconds of inactivity.
#      Casting an ultimate resets the timer and clears that slot.
#
#   6. Damage is NEVER modified here.
#
# ── VALID COMBO KEYS ──────────────────────────────────────────────────────────
#   LLH  LHL  LHH  HLL  HLH  HHL  HHH   (7 total, LLL excluded)
#   Ultimate slot key format: "weapon_id:COMBO_KEY"  e.g. "sword:LLH"
#
extends Node

# ── Configuration ─────────────────────────────────────────────────────────────
const CHAIN_LENGTH:   int = 3
const INVALID_COMBO:  String = "LLL"

# Expiry durations in physics ticks (60 Hz).
# 210 ticks = 3.5 s — identical feel to the old float constants, now deterministic.
const CHAIN_EXPIRY_TICKS: int = 210
const ULT_EXPIRY_TICKS:   int = 210

# ── Chain state ───────────────────────────────────────────────────────────────
var _chain: Array[String] = []
var _chain_weapon_id: String = ""

# ── Ultimate slots ────────────────────────────────────────────────────────────
var _ultimate_slots: Dictionary = {}

# ── Chain timer ───────────────────────────────────────────────────────────────
# Absolute tick at which the chain expires. 0 means the timer is stopped.
var _chain_expiry_tick: int = 0

# ── Ultimate hold timer ───────────────────────────────────────────────────────
# Absolute tick at which the held ultimate expires. 0 means the timer is stopped.
var _ult_expiry_tick: int = 0


# ── Signals ───────────────────────────────────────────────────────────────────
signal ultimate_ready(weapon_id: String, combo_key: String)
signal ultimate_cast(weapon_id: String, combo_key: String)
signal chain_updated(current_chain: Array)
signal chain_cleared()
signal combo_expired()


# ── Timer tick ────────────────────────────────────────────────────────────────
# Runs in the same physics step as CombatController.tick() and GameClock.
# Comparing absolute deadlines against GameClock.tick is fully deterministic —
# both peers compute the same expiry tick from the same input tick.
func _physics_process(_delta: float) -> void:
	var t: int = GameClock.tick
	if _chain_expiry_tick > 0 and t >= _chain_expiry_tick:
		_on_chain_expiry()
	if _ult_expiry_tick > 0 and t >= _ult_expiry_tick:
		_on_ult_expiry()


# ── Public API ────────────────────────────────────────────────────────────────

# Called by CombatController._query_hits() on a confirmed, unguarded, non-parried hit.
func record_hit(attack: AttackData) -> void:
	_record_token(
		"L" if attack.attack_type == "light" else "H",
		attack.weapon_id
	)


# Called by CombatController._on_parry_success() to award H combo credit to the parrier.
# weapon_id: the parrier's active weapon at the time of the parry.
func record_parry_hit(weapon_id: String) -> void:
	var player_name: String = get_parent().name if get_parent() else "?"
	print("[Combo] [%s] Parry registered as Heavy hit — weapon:%s" % [player_name, weapon_id])
	_record_token("H", weapon_id)


# ── Internal token recorder ───────────────────────────────────────────────────
func _record_token(token: String, weapon_id: String) -> void:
	var player_name: String = get_parent().name if get_parent() else "?"

	# BLOCK new combos while an ultimate is held.
	if not _ultimate_slots.is_empty():
		print("[Combo] [%s] Hit ignored — ultimate held. Cast (R) or switch weapons (Tab) to clear." % player_name)
		return

	# Weapon mismatch guard
	if _chain_weapon_id != "" and weapon_id != _chain_weapon_id:
		_reset_chain()

	_chain_weapon_id = weapon_id
	_reset_chain_timer()

	_chain.append(token)
	chain_updated.emit(_chain.duplicate())

	print("[Combo] [%s] Hit — weapon:%s  type:%s  chain:%s"
		% [player_name, weapon_id, token, _chain_as_string()])

	if _chain.size() >= CHAIN_LENGTH:
		_evaluate_chain()


# Called when the player switches weapons (Tab).
func weapon_switched(new_weapon_id: String) -> void:
	var player_name: String = get_parent().name if get_parent() else "?"
	var had_ult := not _ultimate_slots.is_empty()
	if _chain.size() > 0 or _chain_weapon_id != "" or had_ult:
		print("[Combo] [%s] Weapon switch → '%s' — chain + ult slots cleared." % [player_name, new_weapon_id])
		_reset_chain()
		_ultimate_slots.clear()
		_stop_ult_timer()
		combo_expired.emit()


func try_cast_ultimate(active_weapon_id: String) -> bool:
	var player_name: String = get_parent().name if get_parent() else "?"
	for slot_key in _ultimate_slots.keys():
		if slot_key.begins_with(active_weapon_id + ":"):
			var combo_key: String = slot_key.split(":")[1]
			_ultimate_slots.erase(slot_key)
			print("[Combo] [%s] *** ULTIMATE UNLEASHED *** — weapon:%s  combo:%s"
				% [player_name, active_weapon_id, combo_key])
			ultimate_cast.emit(active_weapon_id, combo_key)
			_stop_ult_timer()
			return true

	print("[Combo] [%s] No ultimate ready for weapon '%s'." % [player_name, active_weapon_id])
	return false


func has_ultimate_ready(weapon_id: String) -> bool:
	for slot_key in _ultimate_slots.keys():
		if slot_key.begins_with(weapon_id + ":"):
			return true
	return false

func get_chain() -> Array:
	return _chain.duplicate()

func get_chain_length() -> int:
	return _chain.size()


# ── Internal ──────────────────────────────────────────────────────────────────

func _evaluate_chain() -> void:
	var player_name: String = get_parent().name if get_parent() else "?"
	var key:    String = _chain_as_string()
	var weapon: String = _chain_weapon_id

	if key == INVALID_COMBO:
		print("[Combo] [%s] Chain '%s' on '%s' — no ultimate (LLL excluded by design)."
			% [player_name, key, weapon])
		_reset_chain()
		_stop_chain_timer()
		return

	var slot_key: String = weapon + ":" + key
	_ultimate_slots[slot_key] = true

	_reset_chain()
	_stop_chain_timer()
	_reset_ult_timer()

	print("[Combo] [%s] *** ULTIMATE READY *** — weapon:%s  combo:%s  (press R to unleash, %d-tick window)"
		% [player_name, weapon, key, ULT_EXPIRY_TICKS])
	ultimate_ready.emit(weapon, key)


func _on_chain_expiry() -> void:
	var player_name: String = get_parent().name if get_parent() else "?"
	print("[Combo] [%s] Chain timer expired — in-progress chain cleared." % player_name)
	_reset_chain()
	_stop_chain_timer()
	chain_cleared.emit()


func _on_ult_expiry() -> void:
	var player_name: String = get_parent().name if get_parent() else "?"
	print("[Combo] [%s] Ultimate hold timer expired — ult slot cleared without casting." % player_name)
	_ultimate_slots.clear()
	_stop_ult_timer()
	combo_expired.emit()


func _reset_chain() -> void:
	_chain.clear()
	_chain_weapon_id = ""
	chain_cleared.emit()


func _reset_chain_timer() -> void:
	_chain_expiry_tick = GameClock.tick + CHAIN_EXPIRY_TICKS


func _stop_chain_timer() -> void:
	_chain_expiry_tick = 0


func _reset_ult_timer() -> void:
	_ult_expiry_tick = GameClock.tick + ULT_EXPIRY_TICKS


func _stop_ult_timer() -> void:
	_ult_expiry_tick = 0


func _chain_as_string() -> String:
	var s: String = ""
	for token in _chain:
		s += token
	return s
