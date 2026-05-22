extends Area2D

func _ready():
	print("Hurtbox ready")
	monitoring = true
	monitorable = true


# Called by hitbox OR can be ignored if using signals
func _on_hit_received(hitbox):

	# Safety check: ensure hitbox is valid
	if hitbox == null:
		return

	# Optional: verify swing is active
	if hitbox.has_method("is_swing_active") and not hitbox.is_swing_active():
		return

	print("Dummy hit!")
