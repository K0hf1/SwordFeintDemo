extends Area2D

# Tracks which enemies were already hit in this swing
var hit_targets: Dictionary = {}

var swing_active := false


func _ready():
	monitoring = true
	monitorable = true


# Called by weapon system
func start_swing():
	hit_targets.clear()
	swing_active = true


func end_swing():
	swing_active = false
	# DO NOT disable monitoring (keeps overlap stable)


func is_swing_active() -> bool:
	return swing_active


func _physics_process(delta):

	if not swing_active:
		return

	# Continuously evaluate overlaps
	for area in get_overlapping_areas():

		if not area.is_in_group("enemy_hurtbox"):
			continue

		# prevent multi-hit spam on SAME target per swing
		if hit_targets.has(area):
			continue

		hit_targets[area] = true

		# optional safety check (hurtbox must accept swing)
		if area.has_method("_on_hit_received"):
			area._on_hit_received(self)

		print("Hit landed:", area.name)
