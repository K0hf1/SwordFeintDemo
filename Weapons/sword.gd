# sword.gd
# The Sword is a pure visual executor for both its attacks.
# It does not own combat state, timers, or RPS logic.
# CombatController calls execute_attack() and the sword aims + plays the animation.
#
# Scene:
#   Sword (Node2D)                ← this script
#     ├── LightAttack (AnimatedSprite2D)
#     │     └── HitboxSL (Area2D)
#     └── HeavyAttack (AnimatedSprite2D)
#           └── HitboxSH (Area2D)
#
extends Node2D

@onready var light_anim: AnimatedSprite2D = $LightAttack
@onready var heavy_anim: AnimatedSprite2D = $HeavyAttack
@onready var light_hitbox: Area2D = $LightAttack/HitboxSL
@onready var heavy_hitbox: Area2D = $HeavyAttack/HitboxSH


func _ready() -> void:
	visible = false
	light_hitbox.monitoring = false
	heavy_hitbox.monitoring = false


# Called by CombatController._begin_attack().
# Aims the weapon and plays the correct animation for the given AttackData.
func execute_attack(data: AttackData, aim_dir: Vector2) -> void:
	visible = true

	if aim_dir != Vector2.ZERO:
		rotation = aim_dir.angle() - deg_to_rad(90.0)

	match data.attack_type:
		"light":
			light_anim.flip_h = !light_anim.flip_h
			light_anim.play("sword_light")
		"heavy":
			# Stab — no flip needed; the stab is directional toward aim
			heavy_anim.play("sword_heavy")
