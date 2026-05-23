# combo_tracker.gd
# Tracks the hit-confirmed combo chain for a single player.
# Attach as a child Node of Player (sibling to CombatController).
#
# KEY RULES (read before modifying):
#
#   1. Only CONFIRMED HITS advance the chain.
#      Button presses that whiff do NOT count. CombatController calls
#      record_hit() only when _query_hits() finds a live hurtbox.
#
#   2. The chain is per-weapon.
#      Switching weapons resets the chain entirely via weapon_switched().
#      chain entries are strings like "light" or "heavy" (attack_type field
#      on AttackData).
#
#   3. Damage is NEVER modified here.
#      This class only records what happened. Damage lives on AttackData.
#
#   4. Chain cap is MAX_CHAIN_LENGTH hits.
#      At 3 hits the chain is "full". Hitting a 4th resets and starts fresh
#      from that hit. Adjust MAX_CHAIN_LENGTH to change combo length.
#
#   5. Ultimate generation (NOT YET IMPLEMENTED).
#      When a complete combo is detected (check_combo_complete() returns true),
#      the owning system should bind an ultimate to a key. That is a future
#      feature — this class only exposes the data needed for it.
#
# Scene setup:
#   Player
#     └── ComboTracker   ← this script (Node, no physics)
#
extends Node

# ── Configuration ─────────────────────────────────────────────────────────────
# Maximum number of hits in one combo chain.
# For the demo: light → light → heavy = 3.
const MAX_CHAIN_LENGTH: int = 3

# ── State ─────────────────────────────────────────────────────────────────────
# The confirmed hit chain. Entries are attack_type strings ("light", "heavy").
# Example mid-combo: ["light", "light"]
# Example full combo: ["light", "light", "heavy"]
var chain: Array[String] = []

# Which weapon's attacks are currently being tracked.
# Empty string = no weapon locked in yet (first hit sets it).
var active_weapon_id: String = ""

# Emitted when a full combo sequence is completed (chain.size() == MAX_CHAIN_LENGTH).
# Connect this in whatever system will handle ultimate generation.
# hit_chain is a copy of the completed chain array.
signal combo_completed(hit_chain: Array)

# Emitted whenever the chain changes (for UI updates).
signal chain_updated(current_chain: Array)

# Emitted when the chain is cleared (weapon switch, combo complete, idle timeout).
signal chain_cleared()


# ── Public API — called by CombatController ───────────────────────────────────

# Call this when a hit is confirmed against an enemy (not on whiff).
# attack: the AttackData whose hitbox connected.
func record_hit(attack: AttackData) -> void:
	# If this hit is from a different weapon than what started the current chain,
	# that means a weapon switch happened mid-swing. Clear and start fresh.
	# (weapon_switched() should already have been called on the actual switch,
	#  but this is a safety guard for edge cases.)
	if active_weapon_id != "" and attack.weapon_id != active_weapon_id:
		_reset_chain()

	# Lock chain to this weapon
	active_weapon_id = attack.weapon_id

	# Add to chain
	chain.append(attack.attack_type)
	chain_updated.emit(chain.duplicate())

	print("[Combo] Hit confirmed — weapon:%s  type:%s  chain:%s"
		% [attack.weapon_id, attack.attack_type, str(chain)])

	# Check for completed combo
	if chain.size() >= MAX_CHAIN_LENGTH:
		_on_combo_complete()


# Call this when the player switches weapons.
# Immediately invalidates the current chain regardless of state.
func weapon_switched(new_weapon_id: String) -> void:
	if chain.size() > 0 or active_weapon_id != "":
		print("[Combo] Weapon switched to '%s' — chain cleared." % new_weapon_id)
		_reset_chain()
	active_weapon_id = new_weapon_id


# Call this when the player goes idle without completing a combo
# (e.g. stopped attacking for too long). Optional — for now CombatController
# does not call this; the chain persists until weapon switch or completion.
# Hook this up to a timeout timer in the future if you want combo decay.
func reset_on_idle() -> void:
	if chain.size() > 0:
		print("[Combo] Idle reset — chain cleared.")
		_reset_chain()


# Returns true if the chain just completed (useful for one-shot checks).
# Does NOT clear the chain — _on_combo_complete() does that after emitting.
func is_complete() -> bool:
	return chain.size() >= MAX_CHAIN_LENGTH


# Returns a read-only snapshot of the current chain.
func get_chain() -> Array:
	return chain.duplicate()


# Returns how many hits are in the current chain.
func get_chain_length() -> int:
	return chain.size()


# ── Internal ──────────────────────────────────────────────────────────────────

func _on_combo_complete() -> void:
	var completed := chain.duplicate()
	print("[Combo] COMBO COMPLETE — chain:%s  weapon:%s  (ultimate slot ready — not yet implemented)"
		% [str(completed), active_weapon_id])
	combo_completed.emit(completed)
	_reset_chain()


func _reset_chain() -> void:
	chain.clear()
	active_weapon_id = ""
	chain_cleared.emit()
