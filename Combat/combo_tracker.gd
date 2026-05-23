# combo_tracker.gd
# Tracks hit-confirmed combo chains and manages ultimate slot readiness.
# Attach as a child Node of Player (sibling to CombatController).
#
# ── DESIGN RULES ──────────────────────────────────────────────────────────────
#
#   1. Only CONFIRMED HITS on unguarded targets advance the chain.
#      Whiffed attacks and hits on guarded targets do NOT count.
#      CombatController calls record_hit() only after both conditions pass.
#
#   2. The chain is per-weapon and weapon-scoped.
#      The first hit locks the chain to that weapon_id.
#      weapon_switched() clears the chain (ultimates are preserved).
#
#   3. "LLL" (light light light) is NOT a valid combo — no ultimate awarded.
#      All other 7 permutations of L/H across 3 hits are valid.
#
#   4. EXPIRY TIMER — 3.5 seconds.
#      If the player has not landed a hit in 3.5 seconds, the chain clears.
#      The timer resets on every confirmed hit AND when an ultimate slot is earned.
#      Earned but uncast ultimate slots also expire after 3.5 seconds of inactivity.
#      Casting an ultimate resets the timer and clears that slot.
#
#   5. Damage is NEVER modified here.
#
# ── VALID COMBO KEYS ──────────────────────────────────────────────────────────
#   LLH  LHL  LHH  HLL  HLH  HHL  HHH   (7 total, LLL excluded)
#   Ultimate slot key format: "weapon_id:COMBO_KEY"  e.g. "sword:LLH"
#
# ── SCENE SETUP ───────────────────────────────────────────────────────────────
#   Player
#     ├── CombatController
#     └── ComboTracker   ← this script (plain Node, no physics)
#
extends Node

# ── Configuration ─────────────────────────────────────────────────────────────
const CHAIN_LENGTH:    int   = 3
const INVALID_COMBO:   String = "LLL"
const EXPIRY_SECONDS:  float  = 3.5   # inactivity window before chain + slots clear

# ── Chain state ───────────────────────────────────────────────────────────────
var _chain: Array[String] = []
var _chain_weapon_id: String = ""

# ── Ultimate slots ────────────────────────────────────────────────────────────
# "weapon_id:COMBO_KEY" → true
# Persists across weapon switches.
var _ultimate_slots: Dictionary = {}

# ── Expiry timer ──────────────────────────────────────────────────────────────
# Tracks seconds since the last relevant activity (confirmed hit or ultimate earned).
# Counts up each _process() frame. Resets to 0.0 on activity. When it crosses
# EXPIRY_SECONDS, chain and all ultimate slots are cleared.
var _inactivity_timer: float = 0.0
var _timer_running: bool     = false   # only ticks when there's something to expire


# ── Signals ───────────────────────────────────────────────────────────────────
signal ultimate_ready(weapon_id: String, combo_key: String)
signal ultimate_cast(weapon_id: String, combo_key: String)
signal chain_updated(current_chain: Array)
signal chain_cleared()
signal combo_expired()   # fired when the expiry timer elapses


# ── Expiry tick ───────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not _timer_running:
		return

	_inactivity_timer += delta

	if _inactivity_timer >= EXPIRY_SECONDS:
		_on_expiry()


# ── Public API ────────────────────────────────────────────────────────────────

# Called by CombatController._query_hits() on a confirmed, unguarded hit.
func record_hit(attack: AttackData) -> void:
	# Weapon mismatch guard — safety net for edge cases
	if _chain_weapon_id != "" and attack.weapon_id != _chain_weapon_id:
		_reset_chain()

	_chain_weapon_id = attack.weapon_id
	_reset_inactivity_timer()   # any confirmed hit resets expiry

	var token: String = "L" if attack.attack_type == "light" else "H"
	_chain.append(token)
	chain_updated.emit(_chain.duplicate())

	print("[Combo] Hit — weapon:%s  type:%s  chain:%s"
		% [attack.weapon_id, token, _chain_as_string()])

	if _chain.size() >= CHAIN_LENGTH:
		_evaluate_chain()


# Called when the player switches weapons.
# Clears in-progress chain. Ultimate slots are preserved.
func weapon_switched(new_weapon_id: String) -> void:
	if _chain.size() > 0 or _chain_weapon_id != "":
		print("[Combo] Weapon switch → '%s' — chain cleared (ultimates preserved)."
			% new_weapon_id)
		_reset_chain()
	# Timer keeps running if ultimate slots exist


# Called by CombatController when the player presses R.
# Casts the first ready ultimate for the given weapon.
# Returns true if cast, false if nothing was ready.
func try_cast_ultimate(active_weapon_id: String) -> bool:
	for slot_key in _ultimate_slots.keys():
		if slot_key.begins_with(active_weapon_id + ":"):
			var combo_key: String = slot_key.split(":")[1]
			_ultimate_slots.erase(slot_key)

			print("[Combo] *** ULTIMATE UNLEASHED *** — weapon:%s  combo:%s"
				% [active_weapon_id, combo_key])
			ultimate_cast.emit(active_weapon_id, combo_key)

			# TODO: trigger actual ability execution in a future iteration.
			# e.g. get_parent().execute_ultimate(active_weapon_id, combo_key)

			# Casting resets the inactivity timer; if more slots exist they stay alive.
			# If no chain and no slots remain, timer will naturally expire or stop.
			if _ultimate_slots.is_empty() and _chain.is_empty():
				_stop_inactivity_timer()
			else:
				_reset_inactivity_timer()
			return true

	print("[Combo] No ultimate ready for weapon '%s'." % active_weapon_id)
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
	var key:    String = _chain_as_string()
	var weapon: String = _chain_weapon_id

	if key == INVALID_COMBO:
		print("[Combo] Chain '%s' on '%s' — no ultimate (LLL excluded by design)."
			% [key, weapon])
		_reset_chain()
		# Timer keeps running if ultimate slots exist; otherwise stop.
		if _ultimate_slots.is_empty():
			_stop_inactivity_timer()
		return

	var slot_key: String = weapon + ":" + key
	_ultimate_slots[slot_key] = true

	# Earning an ultimate resets the expiry window — it stays alive for another 3.5s.
	_reset_inactivity_timer()

	print("[Combo] *** ULTIMATE READY *** — weapon:%s  combo:%s  (press R to unleash)"
		% [weapon, key])
	ultimate_ready.emit(weapon, key)

	_reset_chain()


func _on_expiry() -> void:
	print("[Combo] Inactivity timeout — chain and all ultimate slots cleared.")
	_chain.clear()
	_chain_weapon_id = ""
	_ultimate_slots.clear()
	_stop_inactivity_timer()
	combo_expired.emit()
	chain_cleared.emit()


func _reset_chain() -> void:
	_chain.clear()
	_chain_weapon_id = ""
	chain_cleared.emit()


func _reset_inactivity_timer() -> void:
	_inactivity_timer = 0.0
	_timer_running    = true


func _stop_inactivity_timer() -> void:
	_inactivity_timer = 0.0
	_timer_running    = false


func _chain_as_string() -> String:
	var s: String = ""
	for token in _chain:
		s += token
	return s
