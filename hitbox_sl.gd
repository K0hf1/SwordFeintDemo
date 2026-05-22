extends Area2D

var has_hit := false
var swing_active := false  # Explicit flag — the ground truth for whether this swing is live


func _ready():
	monitoring = false
	monitorable = false
	area_entered.connect(_on_area_entered)


# Called by is_swing_active() — hurtbox.gd queries this to reject ghost signals
func is_swing_active() -> bool:
	return swing_active


func start_swing():
	has_hit = false
	swing_active = true
	set_deferred("monitorable", true)
	set_deferred("monitoring", true)


func end_swing():
	swing_active = false          # Mark dead immediately — synchronous, no deferral
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	# has_hit intentionally NOT reset here (see previous notes)


func _on_area_entered(area):

	# Reject if swing is no longer active (catches internally queued signals)
	if not swing_active:
		return

	if has_hit:
		return

	if area.is_in_group("enemy_hurtbox"):
		has_hit = true
		swing_active = false      # Kill swing immediately on first hit
		print("Hit landed")
		set_deferred("monitoring", false)
		set_deferred("monitorable", false)
