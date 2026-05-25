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

@onready var light_anim:  AnimatedSprite2D = $LightAttack
@onready var heavy_anim:  AnimatedSprite2D = $HeavyAttack
@onready var light_hitbox: Area2D = $LightAttack/HitboxSL
@onready var heavy_hitbox: Area2D = $HeavyAttack/HitboxSH   # was wrongly $LightAttack/HitboxSH


func _ready() -> void:
	visible = false
	light_anim.visible  = false
	heavy_anim.visible  = false
	light_hitbox.monitoring = false
	heavy_hitbox.monitoring = false


# Called by CombatController._begin_attack().
# Aims the weapon and plays the correct animation for the given AttackData.
# Only the relevant attack branch is made visible — the other is hidden,
# so debug collision shapes never overlap.
func execute_attack(data: AttackData, aim_dir: Vector2) -> void:
	visible = true

	if aim_dir != Vector2.ZERO:
		rotation = aim_dir.angle() - deg_to_rad(90.0)

	match data.attack_type:
		"light":
			heavy_anim.visible = false   # hide heavy branch + its collision shape
			light_anim.visible = true
			light_anim.flip_h  = !light_anim.flip_h
			light_anim.play("sword_light")
		"heavy":
			light_anim.visible = false   # hide light branch + its collision shape
			heavy_anim.visible = true
			heavy_anim.play("sword_heavy")


# Called by CombatController._enter_idle().
# Resets both branches so no collision shape is ever visible at rest.
func reset() -> void:
	visible            = false
	light_anim.visible = false
	heavy_anim.visible = false
