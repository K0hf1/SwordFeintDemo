# parry.gd
# Weapon-agnostic parry system. Attach as a child Node of Player.
# The parry is ALWAYS available regardless of which weapon is held.
#
# ── HOW PARRY WORKS ──────────────────────────────────────────────────────────
#   1. Player presses C (parry_pressed in InputSnapshot).
#   2. CombatController calls parry.begin_parry() — starts the parry window.
#   3. During the parry window, if a HEAVY attack HitData arrives via
#      on_hit_incoming(), the hit is intercepted:
#        - The attacker receives their own damage reflected back.
#        - This player takes NO damage and NO hitstun.
#        - The parry window closes immediately after a successful parry.
#   4. If the window expires with no heavy hitting, parry ends normally.
#   5. LIGHT attacks are NOT parriable — parry is ignored by light (RPS rule).
#      A light attack during the parry window lands normally.
#
# ── FUTURE-PROOFING: PER-WEAPON PARRY EFFECTS ────────────────────────────────
#   The visual/audio feedback when a parry succeeds is routed through
#   _play_parry_effect(weapon_id), which reads from _parry_effects dictionary.
#   To add a per-weapon effect, register an effect node under this node and
#   add an entry to _parry_effects in _ready(). The core parry logic never changes.
#
#   Example effect node tree:
#     Parry (Node)                   ← this script
#       ├── ParryVFX_Sword (Node2D)  ← sword-specific visual (reflect sparkle, etc.)
#       └── ParryVFX_Bow   (Node2D)  ← bow-specific visual (arrow deflect, etc.)
#
# ── SCENE SETUP ───────────────────────────────────────────────────────────────
#   Player
#     ├── CombatController
#     ├── ComboTracker
#     └── Parry              ← this script (plain Node)
#           └── (effect children added per weapon as needed)
#
extends Node

# How long the parry window stays open (in physics ticks at 60Hz).
# 12 ticks ≈ 200ms — tight but learnable. Tune to taste.
const PARRY_WINDOW_FRAMES: int = 12

# Cooldown between parry attempts (seconds). Prevents spam.
# At 60Hz: 1.5s = 90 ticks, but we track this in real time via _process
# so it works regardless of physics tick rate.
const PARRY_COOLDOWN_SECONDS: float = 2.5

# ── State ─────────────────────────────────────────────────────────────────────
var _is_active:       bool = false
var _window_end_tick: int  = 0

var _cooldown_remaining: float = 0.0   # counts down in _process; >0 means on cooldown

# ── Per-weapon effect registry ────────────────────────────────────────────────
# Maps weapon_id → child Node that has a play_effect() method.
# Register entries in _ready() as weapon effect nodes are added.
# If no entry exists for a weapon, a default visual plays (or nothing, gracefully).
var _parry_effects: Dictionary = {}

# ── Signals ───────────────────────────────────────────────────────────────────

# Emitted when a parry window opens.
signal parry_started()

# Emitted when a heavy attack is successfully parried.
# attacker: the node that threw the heavy.  reflected_damage: what they receive.
signal parry_success(attacker: Node2D, reflected_damage: float)

# Emitted when the parry window closes without intercepting anything.
signal parry_whiff()


func _ready() -> void:
	# Register per-weapon parry effect nodes here as they are built.
	# Example (uncomment when nodes exist):
	#   _parry_effects["sword"] = $ParryVFX_Sword
	#   _parry_effects["bow"]   = $ParryVFX_Bow
	pass


func _process(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta
		if _cooldown_remaining < 0.0:
			_cooldown_remaining = 0.0
			print("[Parry] Cooldown expired — parry available.")


# ── Public API ────────────────────────────────────────────────────────────────

# Called by CombatController when parry input fires and state permits.
# tick_now: the current tick_counter from CombatController.
func begin_parry(tick_now: int) -> bool:
	if _is_active:
		return false   # already in a parry window, ignore re-press
	if _cooldown_remaining > 0.0:
		print("[Parry] On cooldown — %.2fs remaining." % _cooldown_remaining)
		return false
	_is_active       = true
	_window_end_tick = tick_now + PARRY_WINDOW_FRAMES
	print("[Parry] Window opened — ends at tick %d" % _window_end_tick)
	parry_started.emit()
	return true


# Called by CombatController each tick while a parry window is open.
# tick_now: current tick. Returns true if the window is still alive.
func tick_parry_window(tick_now: int) -> bool:
	if not _is_active:
		return false
	if tick_now >= _window_end_tick:
		_close_window(false)   # expired without catching anything
		return false
	return true


# Called by CombatController when an incoming HitData arrives during the parry window.
# This is the RPS interception point.
#
# Returns true  → hit was parried. Caller should SKIP applying the hit to this player.
# Returns false → hit was NOT parried (light attack — parry doesn't stop light).
#
# active_weapon_id: the weapon this player currently holds, for routing effect visuals.
func on_hit_incoming(hit: HitData, active_weapon_id: String) -> bool:
	if not _is_active:
		return false

	# PARRY RULE: parry only intercepts HEAVY attacks.
	# Light attacks ignore parry — they land normally even during the parry window.
	if hit.attack_type != "heavy":
		print("[Parry] Light attack during parry window — parry ignored (RPS: light beats parry).")
		return false

	# Do not parry a reflected hit — prevents infinite reflection loops.
	if hit.is_reflected:
		print("[Parry] Reflected hit during parry window — not re-reflected.")
		return false

	# ── Successful parry ─────────────────────────────────────────────────────
	print("[Parry] *** PARRY SUCCESS *** — reflected %.1f damage back to %s"
		% [hit.damage, hit.attacker.name])

	_reflect_damage(hit, active_weapon_id)
	_play_parry_effect(active_weapon_id)
	_close_window(true)
	return true   # tell caller to suppress this hit


# ── Internal ──────────────────────────────────────────────────────────────────

func _reflect_damage(original_hit: HitData, active_weapon_id: String) -> void:
	# Build a reflected HitData aimed back at the original attacker.
	var reflected := HitData.new()
	reflected.attacker        = get_parent()           # the parrying player is now the "attacker"
	reflected.attack_id       = "parry_reflect_" + active_weapon_id
	reflected.attack_type     = "heavy"                # reflected hits count as heavy for RPS
	reflected.damage          = original_hit.damage    # same damage — reflected 1:1
	reflected.hitstun_frames  = original_hit.hitstun_frames
	reflected.is_reflected    = true                   # CRITICAL — prevents re-reflection
	# Knockback: push the original attacker away from this player
	var parent_node := get_parent() as Node2D
	var push_dir: Vector2 = (original_hit.attacker.global_position - parent_node.global_position).normalized()
	reflected.knockback_vector = push_dir * original_hit.knockback_vector.length()

	# Deliver to the attacker's hurtbox.
	# We look for a child Area2D in the "enemy_hurtbox" group on the attacker.
	var attacker_hurtbox: Area2D = _find_hurtbox(original_hit.attacker)
	if attacker_hurtbox != null:
		attacker_hurtbox.hit_received.emit(reflected)
		parry_success.emit(original_hit.attacker, reflected.damage)
	else:
		push_warning("[Parry] Could not find hurtbox on attacker '%s' to reflect damage."
			% original_hit.attacker.name)


func _find_hurtbox(target: Node) -> Area2D:
	# Walk direct children of the target looking for an Area2D in enemy_hurtbox group.
	for child in target.get_children():
		if child is Area2D and child.is_in_group("enemy_hurtbox"):
			return child
	return null


func _play_parry_effect(weapon_id: String) -> void:
	if _parry_effects.has(weapon_id):
		_parry_effects[weapon_id].play_effect()
	else:
		# Default fallback — no effect node registered yet. Add one per weapon
		# as the art/animation is built. This path is intentionally silent.
		print("[Parry] No effect registered for weapon '%s' — skipping visual." % weapon_id)


func _close_window(was_success: bool) -> void:
	_is_active          = false
	_cooldown_remaining = PARRY_COOLDOWN_SECONDS
	if was_success:
		print("[Parry] Window closed (SUCCESS) — cooldown %.1fs." % PARRY_COOLDOWN_SECONDS)
	else:
		print("[Parry] Window closed (whiff) — cooldown %.1fs." % PARRY_COOLDOWN_SECONDS)
		parry_whiff.emit()


# ── Convenience queries (called by CombatController) ─────────────────────────
func is_active() -> bool:
	return _is_active

func is_on_cooldown() -> bool:
	return _cooldown_remaining > 0.0

func get_cooldown_remaining() -> float:
	return _cooldown_remaining
