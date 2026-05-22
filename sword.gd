extends Node2D

@onready var anim = $LightAttack

var can_attack = true
var attack_interval = 0.3

var facing_right = true


func attack_light():

	# attack cooldown
	if not can_attack:
		return

	can_attack = false

	# ROTATE TOWARD CURSOR
	look_at(get_global_mouse_position())

	# sprite correction
	rotation -= deg_to_rad(90)

	# optional alternating flip
	facing_right = !facing_right
	anim.flip_h = facing_right

	print("Light Attack!")

	anim.play("sword_light")

	await get_tree().create_timer(attack_interval).timeout

	can_attack = true
