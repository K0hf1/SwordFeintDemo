# player_health.gd
# Attach to: Player → PlayerHealth (Node)
#
# Owns the player's HP. Listens to Hurtbox.hit_received AFTER CombatController
# has already resolved RPS (parry / armor / guard). By the time this fires,
# effective_damage has been calculated and hitstun has been entered — this node
# only needs to track the number.
#
# ── Death & Respawn ───────────────────────────────────────────────────────────
# When HP reaches zero, player_died is emitted and _is_dead is set. The player
# node plays a death flash then is removed. ArenaTest respawns after 2 seconds.
#
# ── Hit flash ─────────────────────────────────────────────────────────────────
# Normal hits:    white overbright flash on THIS player (the one taking damage).
# Parry reflects: white overbright flash on the ATTACKER (hit.attacker).
#                 Reflected HitData has is_reflected = true. HP and hitstun are
#                 still applied to the attacker via the normal path — the flash
#                 just targets hit.attacker's Body sprite instead of ours.
#
extends Node
class_name PlayerHealth

@export var max_hp: float = 150.0

var hp: float = max_hp

# Set true the moment HP hits zero. Read by player.gd to freeze all input/physics.
var is_dead: bool = false

const GUARD_DAMAGE_MULTIPLIER: float = 0.35

# ── Node refs ─────────────────────────────────────────────────────────────────
# _hurtbox ref removed — PlayerHealth no longer subscribes to hit_received.
@onready var _combat:   Node             = $"../CombatController"
@onready var _anim:     AnimatedSprite2D = $"../Body"

# ── Signals ───────────────────────────────────────────────────────────────────
signal health_changed(new_hp: float, max_hp: float)
signal player_died()


func _ready() -> void:
	hp = max_hp
	# DO NOT connect to _hurtbox.hit_received here.
	# PlayerHealth no longer subscribes to the signal directly.
	# CombatController is the sole subscriber and calls apply_hit() only after
	# full RPS resolution (parry / armor / guard). This guarantees PlayerHealth
	# never receives a hit that was suppressed by parry.


# ── Incoming hit ──────────────────────────────────────────────────────────────
# Called by CombatController AFTER full RPS resolution (parry/armor/guard).
# This method only runs when the hit has been confirmed as valid — it never
# needs to check was_parried or suppress anything itself.
#
# flash_reflected: pass true when this is a reflected hit so we flash the
# attacker's sprite instead of our own.
func apply_hit(hit: HitData, flash_reflected: bool = false) -> void:
	var flash_target: AnimatedSprite2D
	if flash_reflected:
		flash_target = _get_anim_of(hit.attacker)
	else:
		flash_target = _anim

	var effective_damage := hit.damage
	if _combat.is_guarding:
		effective_damage *= GUARD_DAMAGE_MULTIPLIER

	hp -= effective_damage
	hp  = max(hp, 0.0)

	var player_name: String = get_parent().name if get_parent() else "?"
	print("[PlayerHealth] [%s] HP: %.1f / %.1f  (took %.1f from %s)"
		% [player_name, hp, max_hp, effective_damage, hit.attacker.name])

	health_changed.emit(hp, max_hp)

	if flash_target != null:
		_flash_hit(flash_target)

	if hp <= 0.0:
		_on_died()


# ── Hit flash ─────────────────────────────────────────────────────────────────
func _flash_hit(target_anim: AnimatedSprite2D) -> void:
	target_anim.modulate = Color.WHITE * 3.0
	await get_tree().create_timer(0.08).timeout
	if is_instance_valid(target_anim):
		target_anim.modulate = Color.WHITE


# Returns the AnimatedSprite2D named "Body" on the given player node, or null.
func _get_anim_of(player_node: Node) -> AnimatedSprite2D:
	if player_node == null:
		return null
	return player_node.get_node_or_null("Body") as AnimatedSprite2D


# ── Death ─────────────────────────────────────────────────────────────────────
func _on_died() -> void:
	if is_dead:
		return   # guard against double-trigger
	is_dead = true

	var player_name: String = get_parent().name if get_parent() else "?"
	print("[PlayerHealth] [%s] Defeated — removing from scene." % player_name)
	player_died.emit()
	_death_flash_and_remove()


func _death_flash_and_remove() -> void:
	# Flash red three times then free the player node.
	for i in 3:
		if not is_instance_valid(_anim):
			return
		_anim.modulate = Color(1.0, 0.2, 0.2, 1.0)
		await get_tree().create_timer(0.1).timeout
		if not is_instance_valid(_anim):
			return
		_anim.modulate = Color.TRANSPARENT
		await get_tree().create_timer(0.1).timeout
	if is_instance_valid(get_parent()):
		get_parent().queue_free()


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
