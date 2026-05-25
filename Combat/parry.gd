# parry.gd
# Weapon-agnostic parry system. Attach as a child Node of Player.
# The parry is ALWAYS available regardless of which weapon is held.
#
# ── HOW PARRY WORKS ──────────────────────────────────────────────────────────
#   1. Player presses C (parry_pressed in InputSnapshot).
#   2. CombatController calls parry.begin_parry() — starts the parry window.
#   3. During the parry window, if a HEAVY attack HitData arrives via
#      on_hit_incoming(), the hit is intercepted:
#        - hit.was_parried is set to true on the HitData so the attacker's
#          _query_hits() suppresses combo credit and the HIT log.
#        - The attacker receives their own damage reflected back.
#        - This player takes NO damage and NO hitstun.
#        - parry_success is emitted — CombatController records an H in the
#          PARRIER'S ComboTracker (not the attacker's).
#        - The parry window closes immediately after a successful parry.
#   4. If the window expires with no heavy hitting, parry ends normally.
#   5. LIGHT attacks are NOT parriable — parry is ignored by light (RPS rule).
#      A light attack during the parry window lands normally.
#
# ── COMBO CREDIT ON PARRY ────────────────────────────────────────────────────
#   A successful parry counts as a HEAVY hit in the PARRIER's combo chain.
#   CombatController._on_parry_success() calls _combo.record_parry_hit() which
#   records an AttackData with attack_type = "heavy".
#   All normal combo rules apply (including the ult-held block).
#
# ── FUTURE-PROOFING: PER-WEAPON PARRY EFFECTS ────────────────────────────────
#   The visual/audio feedback when a parry succeeds is routed through
#   _play_parry_effect(weapon_id), which reads from _parry_effects dictionary.
#   To add a per-weapon effect, register an effect node under this node and
#   add an entry to _parry_effects in _ready(). The core parry logic never changes.
#
extends Node

# How long the parry window stays open (in physics ticks at 60Hz).
# 12 ticks ≈ 200ms — tight but learnable. Tune to taste.
const PARRY_WINDOW_FRAMES: int = 12

# Cooldown between parry attempts (seconds). Prevents spam.
const PARRY_COOLDOWN_SECONDS: float = 2.5

# ── State ─────────────────────────────────────────────────────────────────────
var _is_active:       bool = false
var _window_end_tick: int  = 0

var _cooldown_remaining: float = 0.0   # counts down in _process; >0 means on cooldown

# ── Per-weapon effect registry ────────────────────────────────────────────────
var _parry_effects: Dictionary = {}

# ── Signals ───────────────────────────────────────────────────────────────────

# Emitted when a parry window opens.
signal parry_started()

# Emitted when a heavy attack is successfully parried.
# attacker: the node that threw the heavy.  reflected_damage: what they receive.
# parrier_combo: the ComboTracker of the parrying player (for H credit).
signal parry_success(attacker: Node2D, reflected_damage: float, parrier_combo: Node)

# Emitted when the parry window closes without intercepting anything.
signal parry_whiff()


func _ready() -> void:
	pass


func _process(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta
		if _cooldown_remaining <= 0.0:
			_cooldown_remaining = 0.0
			var player_name: String = get_parent().name if get_parent() else "?"
			print("[Parry] [%s] Cooldown expired — parry available." % player_name)


# ── Public API ────────────────────────────────────────────────────────────────

func begin_parry(tick_now: int) -> bool:
	if _is_active:
		return false
	if _cooldown_remaining > 0.0:
		var player_name: String = get_parent().name if get_parent() else "?"
		print("[Parry] [%s] On cooldown — %.2fs remaining." % [player_name, _cooldown_remaining])
		return false
	_is_active       = true
	_window_end_tick = tick_now + PARRY_WINDOW_FRAMES
	var player_name: String = get_parent().name if get_parent() else "?"
	print("[Parry] [%s] Window opened — ends at tick %d" % [player_name, _window_end_tick])
	parry_started.emit()
	return true


func tick_parry_window(tick_now: int) -> bool:
	if not _is_active:
		return false
	if tick_now >= _window_end_tick:
		_close_window(false)
		return false
	return true


# Called by CombatController when an incoming HitData arrives during the parry window.
# Sets hit.was_parried = true on success so the attacker's _query_hits() can detect it.
#
# Returns true  → hit was parried. Caller should SKIP applying the hit to this player.
# Returns false → hit was NOT parried (light attack — parry doesn't stop light).
func on_hit_incoming(hit: HitData, active_weapon_id: String) -> bool:
	if not _is_active:
		return false

	if hit.attack_type != "heavy":
		var player_name: String = get_parent().name if get_parent() else "?"
		print("[Parry] [%s] Light attack during parry window — parry ignored (RPS: light beats parry)." % player_name)
		return false

	if hit.is_reflected:
		var player_name: String = get_parent().name if get_parent() else "?"
		print("[Parry] [%s] Reflected hit during parry window — not re-reflected." % player_name)
		return false

	# ── Successful parry ─────────────────────────────────────────────────────
	# Mark the original HitData so the attacker's _query_hits() knows not to
	# award combo credit or log a HIT for this swing.
	hit.was_parried = true

	var player_name: String = get_parent().name if get_parent() else "?"
	print("[Parry] [%s] *** PARRY SUCCESS *** — reflected %.1f damage back to %s"
		% [player_name, hit.damage, hit.attacker.name])

	_reflect_damage(hit, active_weapon_id)
	_play_parry_effect(active_weapon_id)
	_close_window(true)
	return true


# ── Internal ──────────────────────────────────────────────────────────────────

func _reflect_damage(original_hit: HitData, active_weapon_id: String) -> void:
	var reflected := HitData.new()
	reflected.attacker        = get_parent()
	reflected.attack_id       = "parry_reflect_" + active_weapon_id
	reflected.attack_type     = "heavy"
	reflected.damage          = original_hit.damage
	reflected.hitstun_frames  = original_hit.hitstun_frames
	reflected.is_reflected    = true
	var parent_node := get_parent() as Node2D
	var push_dir: Vector2 = (original_hit.attacker.global_position - parent_node.global_position).normalized()
	reflected.knockback_vector = push_dir * original_hit.knockback_vector.length()

	var attacker_hurtbox: Area2D = _find_hurtbox(original_hit.attacker)
	if attacker_hurtbox != null:
		attacker_hurtbox.hit_received.emit(reflected)
		# Pass the parrier's ComboTracker so CombatController can award H credit
		var parrier_combo: Node = get_parent().get_node_or_null("ComboTracker")
		parry_success.emit(original_hit.attacker, reflected.damage, parrier_combo)
	else:
		push_warning("[Parry] Could not find hurtbox on attacker '%s' to reflect damage."
			% original_hit.attacker.name)


func _find_hurtbox(target: Node) -> Area2D:
	for child in target.get_children():
		if child is Area2D and child.is_in_group("hurtbox"):
			return child
	return null


func _play_parry_effect(weapon_id: String) -> void:
	if _parry_effects.has(weapon_id):
		_parry_effects[weapon_id].play_effect()
	else:
		var player_name: String = get_parent().name if get_parent() else "?"
		print("[Parry] [%s] No effect registered for weapon '%s' — skipping visual." % [player_name, weapon_id])


func _close_window(was_success: bool) -> void:
	_is_active          = false
	_cooldown_remaining = PARRY_COOLDOWN_SECONDS
	var player_name: String = get_parent().name if get_parent() else "?"
	if was_success:
		print("[Parry] [%s] Window closed (SUCCESS) — cooldown %.1fs." % [player_name, PARRY_COOLDOWN_SECONDS])
	else:
		print("[Parry] [%s] Window closed (whiff) — cooldown %.1fs." % [player_name, PARRY_COOLDOWN_SECONDS])
		parry_whiff.emit()


# ── Convenience queries ───────────────────────────────────────────────────────
func is_active() -> bool:
	return _is_active

func is_on_cooldown() -> bool:
	return _cooldown_remaining > 0.0

func get_cooldown_remaining() -> float:
	return _cooldown_remaining
