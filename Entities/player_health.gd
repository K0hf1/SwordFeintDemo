# player_health.gd
# Attach to: Player → PlayerHealth (Node)
#
# Owns the player's HP. Listens to Hurtbox.hit_received AFTER CombatController
# has already resolved RPS (parry / armor / guard). By the time this fires,
# effective_damage has been calculated and hitstun has been entered — this node
# only needs to track the number.
#
# ── Death & Respawn ───────────────────────────────────────────────────────────
# When HP reaches zero, the player emits player_died, then after a short flash
# the player node is removed from the scene. ArenaTest listens to player_died
# and schedules a respawn after 2 seconds.
#
extends Node
class_name PlayerHealth

@export var max_hp: float = 20.0

var hp: float = max_hp

const GUARD_DAMAGE_MULTIPLIER: float = 0.35

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var _hurtbox:  PlayerHurtbox    = $"../Hurtbox"
@onready var _combat:   Node             = $"../CombatController"
@onready var _anim:     AnimatedSprite2D = $"../Body"

# ── Signals ───────────────────────────────────────────────────────────────────
signal health_changed(new_hp: float, max_hp: float)
signal player_died()


func _ready() -> void:
	hp = max_hp
	_hurtbox.hit_received.connect(_on_hit_incoming)


# ── Incoming hit ──────────────────────────────────────────────────────────────
func _on_hit_incoming(hit: HitData) -> void:
	# Parried hits and reflected hits are never applied to this player's HP.
	if hit.is_reflected:
		return
	# was_parried means the parry system already suppressed this — skip.
	if hit.was_parried:
		return

	var effective_damage := hit.damage
	if _combat.is_guarding:
		effective_damage *= GUARD_DAMAGE_MULTIPLIER

	hp -= effective_damage
	hp  = max(hp, 0.0)

	var player_name: String = get_parent().name if get_parent() else "?"
	print("[PlayerHealth] [%s] HP: %.1f / %.1f  (took %.1f from %s)"
		% [player_name, hp, max_hp, effective_damage, hit.attacker.name])

	health_changed.emit(hp, max_hp)

	# Flash white to indicate damage — same as dummy.gd
	_flash_hit()

	if hp <= 0.0:
		_on_died()


# ── Hit flash ─────────────────────────────────────────────────────────────────
func _flash_hit() -> void:
	_anim.modulate = Color.WHITE * 3.0
	await get_tree().create_timer(0.08).timeout
	# Guard: player may have been freed during the await
	if is_instance_valid(_anim):
		_anim.modulate = Color.WHITE


# ── Death ─────────────────────────────────────────────────────────────────────
func _on_died() -> void:
	var player_name: String = get_parent().name if get_parent() else "?"
	print("[PlayerHealth] [%s] Defeated — removing from scene." % player_name)
	player_died.emit()
	# Brief death flash before removal
	_death_flash_and_remove()


func _death_flash_and_remove() -> void:
	# Flash rapidly three times then queue_free
	for i in 3:
		_anim.modulate = Color(1.0, 0.2, 0.2, 1.0)   # red tint
		await get_tree().create_timer(0.1).timeout
		if not is_instance_valid(_anim):
			return
		_anim.modulate = Color.TRANSPARENT
		await get_tree().create_timer(0.1).timeout
		if not is_instance_valid(get_parent()):
			return
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
