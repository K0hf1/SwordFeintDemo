extends Area2D

# This flag is SET by the hitbox that lands a hit, and CLEARED after a grace period.
# It prevents ghost signals from a just-disabled hitbox still triggering damage.
var can_be_hit := true
var hit_cooldown := 0.1  # should be >= sword attack_interval to avoid double-dipping


func _ready():
	print("Hurtbox ready")
	area_entered.connect(_on_area_entered)


func _on_area_entered(area):

	# Guard 1: ignore if we're already in hit-cooldown
	if not can_be_hit:
		return

	# Guard 2: only care about the player's attack hitbox group
	if not area.is_in_group("player_attack"):
		return

	# Guard 3: only register if the hitbox itself considers this swing active
	# This kills ghost hits from a hitbox that just turned off but queued a signal
	if area.has_method("is_swing_active") and not area.is_swing_active():
		return

	can_be_hit = false
	print("Dummy hit!")

	# Re-enable after cooldown
	await get_tree().create_timer(hit_cooldown).timeout
	can_be_hit = true
