extends Node2D

@onready var anim = $LightAttack
@onready var hitbox = $LightAttack/HitboxSL

var can_attack = true
var attack_interval = 0.25

var facing_right = true


func attack_light():

	if not can_attack:
		return

	can_attack = false

	# AIM toward mouse
	look_at(get_global_mouse_position())
	rotation -= deg_to_rad(90)

	# Visual flip alternates each swing
	facing_right = !facing_right
	anim.flip_h = facing_right

	# Start hitbox — resets has_hit and enables monitoring via set_deferred
	hitbox.start_swing()

	print("⚔️Light Attack!⚔️")
	anim.play("sword_light")

	# Active frames — hitbox is live for this window only
	await get_tree().create_timer(0.1).timeout

	# End hitbox — disables monitoring, preserves has_hit until next swing
	hitbox.end_swing()

	# Attack cooldown before next swing is allowed
	await get_tree().create_timer(attack_interval).timeout

	can_attack = true
