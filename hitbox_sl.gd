extends Area2D

var hit_targets := {}
var swing_active := false


func _ready():
	monitoring = true
	monitorable = true


func start_swing():
	hit_targets.clear()
	swing_active = true

	# 🔥 FORCE physics re-evaluation
	monitoring = false
	await get_tree().process_frame
	monitoring = true


func end_swing():
	swing_active = false


func _physics_process(delta):

	if not swing_active:
		return

	# 🔥 SAFETY GUARD
	if not monitoring:
		return

	for area in get_overlapping_areas():

		if not area.is_in_group("enemy_hurtbox"):
			continue

		if hit_targets.has(area):
			continue

		hit_targets[area] = true

		if area.has_method("_on_hit_received"):
			area._on_hit_received(self)

		print("Hit landed:", area.name)
