extends Area2D

var has_hit := false

func _ready():
	monitoring = false          # Always start disabled
	monitorable = false
	area_entered.connect(_on_area_entered)

func start_swing():
	has_hit = false             # Reset only at swing START, never at end
	set_deferred("monitorable", true)
	set_deferred("monitoring", true)

func end_swing():
	# Disable detection — use set_deferred so physics state is clean
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	# NOTE: has_hit intentionally NOT reset here.
	# Resetting here is what causes ghost hits — a lingering overlap
	# re-triggers area_entered the moment monitoring flips back on next swing.

func _on_area_entered(area):
	if has_hit:
		return

	if area.is_in_group("enemy_hurtbox"):
		has_hit = true
		print("Hit landed")
		# Immediately disable so no further overlaps register this swing
		set_deferred("monitoring", false)
		set_deferred("monitorable", false)
