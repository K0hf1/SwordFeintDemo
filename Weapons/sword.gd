# sword.gd  (REFACTORED)
# The Sword is now a pure executor. It does not own combat state.
# It does not decide when attacks are allowed.
# It does not run timers or coroutines.
#
# CombatController calls execute_attack() and the sword:
#   - Aims toward the target direction
#   - Plays the visual animation
#   - That's it.
#
# HitboxSL is a passive sensor — its monitoring flag is controlled by CombatController.
#
extends Node2D

@onready var anim: AnimatedSprite2D = $LightAttack
@onready var hitbox: Area2D = $LightAttack/HitboxSL


func _ready() -> void:
	visible = false
	hitbox.monitoring = false


# Called by CombatController._begin_attack()
# aim_dir is the world-space direction from player toward the attack target (e.g. mouse).
func execute_attack(data: AttackData, aim_dir: Vector2) -> void:
	visible = true

	# Aim the weapon toward the attack direction
	if aim_dir != Vector2.ZERO:
		rotation = aim_dir.angle() - deg_to_rad(90.0)

	# Alternate horizontal flip for visual variety on repeated attacks
	anim.flip_h = !anim.flip_h

	# Play the attack animation — visual only, does not affect game state
	anim.play("sword_light")
