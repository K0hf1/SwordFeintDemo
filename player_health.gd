# player_health.gd
# Attach to: Player → PlayerHealth (Node)
#
# Owns the player's HP. Listens to Hurtbox.hit_received AFTER CombatController
# has already resolved RPS (parry / armor / guard). By the time this fires,
# effective_damage has been calculated and hitstun has been entered — this node
# only needs to track the number.
#
# ── Why separate from CombatController? ──────────────────────────────────────
# CombatController owns combat STATE (startup/active/recovery/hitstun/parry).
# Health is persistent data that outlives any single attack exchange.
# Keeping them separate means UI, save data, and death logic never touch
# the combat state machine.
#
# ── Signal chain (incoming hit) ──────────────────────────────────────────────
#   Enemy hitbox overlaps Player Hurtbox
#     → attacker CombatController emits Hurtbox.hit_received(hit)
#       → CombatController._on_hit_incoming(hit)   [RPS resolve, hitstun]
#         → PlayerHealth._on_hit_incoming(hit)      [HP subtract, death check]
#
# ── Scene placement ───────────────────────────────────────────────────────────
#   Player (CharacterBody2D)
#     ├── Hurtbox (Area2D + PlayerHurtbox script)
#     └── PlayerHealth (Node)  ← this script
#
extends Node
class_name PlayerHealth

@export var max_hp: float = 100.0

var hp: float = max_hp

# Guard multiplier must match CombatController.GUARD_DAMAGE_MULTIPLIER.
# Duplicated here so PlayerHealth can compute the correct effective damage
# independently — change both if you tune the value.
const GUARD_DAMAGE_MULTIPLIER: float = 0.35

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var _hurtbox:  PlayerHurtbox = $"../Hurtbox"
@onready var _combat:   Node          = $"../CombatController"

# ── Signals ───────────────────────────────────────────────────────────────────
signal health_changed(new_hp: float, max_hp: float)
signal player_died()


func _ready() -> void:
	hp = max_hp
	_hurtbox.hit_received.connect(_on_hit_incoming)


# ── Incoming hit ──────────────────────────────────────────────────────────────
# Called AFTER CombatController has resolved parry / armor / guard and entered
# hitstun. This handler only needs to subtract HP.
#
# NOTE: Guard damage reduction is applied here to keep health authoritative.
# CombatController.is_guarding is read directly so we don't need a parameter.
func _on_hit_incoming(hit: HitData) -> void:
	# Parry check — if CombatController already returned early (parried),
	# this signal was never emitted, so no guard needed here.

	# Skip reflected hits that were already handled by the parry reflect path
	# (they are emitted on the ATTACKER's hurtbox, not the player's — but just in case).
	if hit.is_reflected:
		return

	var effective_damage := hit.damage
	if _combat.is_guarding:
		effective_damage *= GUARD_DAMAGE_MULTIPLIER

	hp -= effective_damage
	hp  = max(hp, 0.0)

	print("[PlayerHealth] HP: %.1f / %.1f  (took %.1f from %s)"
		% [hp, max_hp, effective_damage, hit.attacker.name])

	health_changed.emit(hp, max_hp)

	if hp <= 0.0:
		_on_died()


# ── Death ─────────────────────────────────────────────────────────────────────
func _on_died() -> void:
	print("[PlayerHealth] Player defeated.")
	player_died.emit()
	# TODO: trigger death animation, respawn, game-over screen, etc.


# ── Public queries ────────────────────────────────────────────────────────────
func get_hp() -> float:
	return hp

func get_max_hp() -> float:
	return max_hp

func is_alive() -> bool:
	return hp > 0.0

func heal(amount: float) -> void:
	hp = min(hp + amount, max_hp)
	health_changed.emit(hp, max_hp)
