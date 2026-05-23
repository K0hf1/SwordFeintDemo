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
const CHAIN_LENGTH:         int   = 3
const INVALID_COMBO:        String = "LLL"
const CHAIN_EXPIRY_SECONDS: float  = 3.5   # resets on every confirmed hit
const ULT_EXPIRY_SECONDS:   float  = 3.5   # starts when ult slot is earned; independent

# ── Chain state ───────────────────────────────────────────────────────────────
var _chain: Array[String] = []
var _chain_weapon_id: String = ""

# ── Ultimate slots ────────────────────────────────────────────────────────────
# "weapon_id:COMBO_KEY" → true
# Persists across weapon switches.
# While ANY slot is held, record_hit() is BLOCKED — no new chains can start.
# Cleared by: Tab (weapon_switched), R (try_cast_ultimate), or ult timer expiry.
var _ultimate_slots: Dictionary = {}

# ── Chain timer ───────────────────────────────────────────────────────────────
# Resets to 0 on every confirmed hit.
# When it crosses CHAIN_EXPIRY_SECONDS the in-progress chain clears.
var _chain_timer:         float = 0.0
var _chain_timer_running: bool  = false

# ── Ultimate hold timer ───────────────────────────────────────────────────────
# Starts fresh when an ultimate slot is earned. Independent of chain timer.
# When it crosses ULT_EXPIRY_SECONDS the held ult expires without being cast.
var _ult_timer:         float = 0.0
var _ult_timer_running: bool  = false


# ── Signals ───────────────────────────────────────────────────────────────────
signal ultimate_ready(weapon_id: String, combo_key: String)
signal ultimate_cast(weapon_id: String, combo_key: String)
signal chain_updated(current_chain: Array)
signal chain_cleared()
signal combo_expired()   # fired when the expiry timer elapses


# ── Timer tick ────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	# Chain timer — clears in-progress chain on inactivity
	if _chain_timer_running:
		_chain_timer += delta
		if _chain_timer >= CHAIN_EXPIRY_SECONDS:
			_on_chain_expiry()

	# Ult hold timer — clears held ultimate independently of chain activity
	if _ult_timer_running:
		_ult_timer += delta
		if _ult_timer >= ULT_EXPIRY_SECONDS:
			_on_ult_expiry()


# ── Public API ────────────────────────────────────────────────────────────────

# Called by CombatController._query_hits() on a confirmed, unguarded hit.
func record_hit(attack: AttackData) -> void:
	# BLOCK new combos while an ultimate is held.
	# Player must cast (R) or clear (Tab) before building a new chain.
	if not _ultimate_slots.is_empty():
		print("[Combo] Hit ignored — ultimate held. Cast (R) or switch weapons (Tab) to clear.")
		return

	# Weapon mismatch guard — safety net for edge cases
	if _chain_weapon_id != "" and attack.weapon_id != _chain_weapon_id:
		_reset_chain()

	_chain_weapon_id = attack.weapon_id

	# Every confirmed hit resets the chain timer — keeps the string alive
	_reset_chain_timer()

	var token: String = "L" if attack.attack_type == "light" else "H"
	_chain.append(token)
	chain_updated.emit(_chain.duplicate())

	print("[Combo] Hit — weapon:%s  type:%s  chain:%s"
		% [attack.weapon_id, token, _chain_as_string()])

	if _chain.size() >= CHAIN_LENGTH:
		_evaluate_chain()


# Called when the player switches weapons (Tab).
# Clears in-progress chain AND held ultimate slots — Tab is the "clear ult" escape.
func weapon_switched(new_weapon_id: String) -> void:
	var had_ult := not _ultimate_slots.is_empty()
	if _chain.size() > 0 or _chain_weapon_id != "" or had_ult:
		print("[Combo] Weapon switch → '%s' — chain + ult slots cleared." % new_weapon_id)
		_reset_chain()
		_ultimate_slots.clear()
		_stop_ult_timer()
		combo_expired.emit()


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

			# Stop ult timer — slot consumed
			_stop_ult_timer()
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
		_stop_chain_timer()
		return

	var slot_key: String = weapon + ":" + key
	_ultimate_slots[slot_key] = true

	# Chain is consumed — stop chain timer, start fresh ult hold timer
	_reset_chain()
	_stop_chain_timer()
	_reset_ult_timer()

	print("[Combo] *** ULTIMATE READY *** — weapon:%s  combo:%s  (press R to unleash, %.1fs window)"
		% [weapon, key, ULT_EXPIRY_SECONDS])
	ultimate_ready.emit(weapon, key)


func _on_chain_expiry() -> void:
	print("[Combo] Chain timer expired — in-progress chain cleared.")
	_reset_chain()
	_stop_chain_timer()
	chain_cleared.emit()


func _on_ult_expiry() -> void:
	print("[Combo] Ultimate hold timer expired — ult slot cleared without casting.")
	_ultimate_slots.clear()
	_stop_ult_timer()
	combo_expired.emit()


func _reset_chain() -> void:
	_chain.clear()
	_chain_weapon_id = ""
	chain_cleared.emit()


func _reset_chain_timer() -> void:
	_chain_timer         = 0.0
	_chain_timer_running = true


func _stop_chain_timer() -> void:
	_chain_timer         = 0.0
	_chain_timer_running = false


func _reset_ult_timer() -> void:
	_ult_timer         = 0.0
	_ult_timer_running = true


func _stop_ult_timer() -> void:
	_ult_timer         = 0.0
	_ult_timer_running = false


func _chain_as_string() -> String:
	var s: String = ""
	for token in _chain:
		s += token
	return s
