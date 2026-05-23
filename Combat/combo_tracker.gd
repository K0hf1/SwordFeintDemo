# combo_tracker.gd
# Tracks hit-confirmed combo chains and manages ultimate slot readiness.
# Attach as a child Node of Player (sibling to CombatController).
#
# ── DESIGN RULES ──────────────────────────────────────────────────────────────
#
#   1. Only CONFIRMED HITS advance the chain.
#      Whiffed attacks (no hurtbox contact) do nothing. CombatController calls
#      record_hit() only from inside _query_hits() after overlap is confirmed.
#
#   2. The chain is per-weapon and weapon-scoped.
#      The first hit locks the chain to that weapon_id. weapon_switched() resets
#      everything. A hit from a different weapon_id mid-chain also force-resets.
#
#   3. "light light light" IS NOT a valid combo. It is excluded by design.
#      All other 3-hit permutations of light/heavy ARE valid (7 total).
#      Completing LLL clears the chain with no ultimate reward.
#
#   4. Damage is NEVER modified here. This class is read-only relative to stats.
#
#   5. Ultimate readiness is per-weapon, per-combo-key.
#      Completing "light heavy heavy" on the sword marks SWORD:LHH as ready.
#      Switching to the bow does not consume or clear the sword ultimate.
#      Pressing R (ultimate_pressed in InputSnapshot) casts the ready ultimate
#      for the currently active weapon, if one exists.
#
# ── ULTIMATE SLOT KEYS ────────────────────────────────────────────────────────
#   Each combo produces a key like "sword:LLH" or "bow:HHH".
#   The 7 valid combos per weapon:
#     LLH  LHL  LHH  HLL  HLH  HHL  HHH
#   "LLL" is intentionally absent — no ultimate is awarded for it.
#
# ── SCENE SETUP ───────────────────────────────────────────────────────────────
#   Player
#     ├── CombatController
#     └── ComboTracker   ← this script (plain Node, no physics)
#
extends Node

# ── Configuration ─────────────────────────────────────────────────────────────
const CHAIN_LENGTH: int = 3

# The one chain that grants no ultimate. All others do.
const INVALID_COMBO: String = "LLL"

# ── Chain state ───────────────────────────────────────────────────────────────
# Confirmed-hit chain for the current weapon. Entries: "L" or "H".
var _chain: Array[String] = []

# weapon_id that owns the current chain. "" = no chain in progress.
var _chain_weapon_id: String = ""

# ── Ultimate slots ────────────────────────────────────────────────────────────
# Maps "weapon_id:COMBO_KEY" → true when that ultimate is ready to cast.
# Example: { "sword:LLH": true, "sword:HHH": true }
# Persists across weapon switches — earning an ultimate with the sword while
# holding the bow does not erase it (and vice versa).
var _ultimate_slots: Dictionary = {}

# ── Signals ───────────────────────────────────────────────────────────────────

# Fired when a 3-hit valid combo completes and its ultimate slot becomes ready.
# weapon_id: which weapon earned it.   combo_key: e.g. "LLH"
signal ultimate_ready(weapon_id: String, combo_key: String)

# Fired when the player successfully casts an ultimate.
signal ultimate_cast(weapon_id: String, combo_key: String)

# Fired whenever the in-progress chain changes (for HUD updates).
# current_chain is a copy of _chain.
signal chain_updated(current_chain: Array)

# Fired when the chain resets for any reason.
signal chain_cleared()


# ── Public API — called by CombatController ───────────────────────────────────

# Called by CombatController._query_hits() when a hit is confirmed on an enemy.
# This is the ONLY code path that advances the chain.
func record_hit(attack: AttackData) -> void:
	# Weapon-switch guard: if mid-chain and a different weapon's hit slips through,
	# reset and start fresh from this hit. weapon_switched() should have already
	# been called, but this is a safety net.
	if _chain_weapon_id != "" and attack.weapon_id != _chain_weapon_id:
		_reset_chain()

	_chain_weapon_id = attack.weapon_id

	# Encode attack type as single character for compact combo keys
	var token: String = "L" if attack.attack_type == "light" else "H"
	_chain.append(token)
	chain_updated.emit(_chain.duplicate())

	print("[Combo] Hit — weapon:%s  type:%s  chain:%s"
		% [attack.weapon_id, token, _chain_as_string()])

	if _chain.size() >= CHAIN_LENGTH:
		_evaluate_chain()


# Called from player.gd when the weapon_switch input fires.
# Clears any in-progress chain. Does NOT clear earned ultimate slots.
func weapon_switched(new_weapon_id: String) -> void:
	if _chain.size() > 0 or _chain_weapon_id != "":
		print("[Combo] Weapon switch → '%s' — chain cleared (ultimates preserved)."
			% new_weapon_id)
		_reset_chain()
	# Note: _chain_weapon_id will be set by the next record_hit() call.
	# We don't pre-set it here — the new weapon may not attack immediately.


# Called from CombatController when the player presses the ultimate key (R).
# active_weapon_id: the weapon currently held by the player.
# Returns true if an ultimate was cast, false if none was ready.
func try_cast_ultimate(active_weapon_id: String) -> bool:
	# Find the first ready ultimate slot for this weapon.
	# (In practice there will usually be at most one, but the system supports
	#  earning multiple before casting.)
	for slot_key in _ultimate_slots.keys():
		if slot_key.begins_with(active_weapon_id + ":"):
			var combo_key: String = slot_key.split(":")[1]
			_ultimate_slots.erase(slot_key)

			print("[Combo] *** ULTIMATE UNLEASHED *** — weapon:%s  combo:%s"
				% [active_weapon_id, combo_key])
			ultimate_cast.emit(active_weapon_id, combo_key)

			# TODO: trigger the actual ultimate ability here in a future iteration.
			# e.g. get_parent().execute_ultimate(active_weapon_id, combo_key)
			return true

	print("[Combo] No ultimate ready for weapon '%s'." % active_weapon_id)
	return false


# Returns true if there is at least one ready ultimate for the given weapon.
func has_ultimate_ready(weapon_id: String) -> bool:
	for slot_key in _ultimate_slots.keys():
		if slot_key.begins_with(weapon_id + ":"):
			return true
	return false


# Returns a copy of the current in-progress chain tokens (for HUD).
func get_chain() -> Array:
	return _chain.duplicate()

func get_chain_length() -> int:
	return _chain.size()


# ── Internal ──────────────────────────────────────────────────────────────────

func _evaluate_chain() -> void:
	var key: String = _chain_as_string()       # e.g. "LLH"
	var weapon: String = _chain_weapon_id

	if key == INVALID_COMBO:
		# LLL — no ultimate, just clear silently
		print("[Combo] Chain '%s' on '%s' — no ultimate (LLL is not a valid combo)."
			% [key, weapon])
		_reset_chain()
		return

	# Valid combo — mark ultimate slot as ready
	var slot_key: String = weapon + ":" + key
	_ultimate_slots[slot_key] = true

	print("[Combo] *** ULTIMATE READY *** — weapon:%s  combo:%s  (press R to unleash)"
		% [weapon, key])
	ultimate_ready.emit(weapon, key)

	_reset_chain()


func _reset_chain() -> void:
	_chain.clear()
	_chain_weapon_id = ""
	chain_cleared.emit()


# Joins the chain array into a compact string like "LLH" for key lookups.
func _chain_as_string() -> String:
	var s: String = ""
	for token in _chain:
		s += token
	return s
