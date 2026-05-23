# hitbox_sl.gd  (REFACTORED)
# HitboxSL is now a fully passive sensor.
# It has no _physics_process, no coroutines, no direct method calls.
#
# Its ONLY job:
#   - Exist as an Area2D with a CollisionShape2D
#   - Report get_overlapping_areas() when queried
#
# CombatController controls:
#   - When monitoring is true (during ACTIVE frames)
#   - When to call get_overlapping_areas()
#   - What to do with the results
#
# The old monitoring=false/await/monitoring=true hack is gone because
# CombatController sets monitoring=true exactly on the tick active frames begin,
# and the physics engine evaluates overlaps on the next tick — deterministically.
#
extends Area2D


func _ready() -> void:
	monitoring  = false   # CombatController activates this
	monitorable = true    # enemies can detect us if needed
