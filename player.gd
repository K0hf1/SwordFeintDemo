# IMPORTANT: Change the root node type in the scene from Node2D to CharacterBody2D.
# In the Inspector, make sure:
#   - Collision Layer includes the "player" layer
#   - Collision Mask includes the "player" and "enemy" layers
# This is what makes move_and_slide() respect those collision bodies.

extends CharacterBody2D

@export var speed := 150
@export var dash_distance := 50
@export var dash_duration := 0.1
@export var dash_attack_lockout := 0.25

@onready var anim = $Body
@onready var weapon = $WeaponHolder/Sword

var is_dashing := false
var is_attacking := false
var dash_lockout_active := false

var last_dir_vector := Vector2.DOWN


func _ready():
	weapon.visible = false


func _physics_process(delta):
	# _physics_process instead of _process so move_and_slide() runs on the physics tick

	handle_input()

	if is_dashing:
		return

	if is_attacking:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	handle_movement(delta)


# --------------------
# Input
# --------------------
func handle_input():

	if Input.is_action_just_pressed("dash"):
		dash()
		return

	if Input.is_action_just_pressed("light_attack"):
		try_attack()


# --------------------
# ATTACK
# --------------------
func try_attack():

	if is_dashing or dash_lockout_active:
		return

	if not weapon.can_attack:
		return

	if is_attacking:
		return

	light_attack()


func light_attack():

	is_attacking = true
	velocity = Vector2.ZERO

	anim.play(get_idle_anim())

	weapon.visible = true
	weapon.attack_light()

	await get_tree().create_timer(weapon.attack_interval).timeout

	weapon.visible = false
	is_attacking = false


# --------------------
# DASH
# --------------------
func dash():

	if is_dashing:
		return

	is_dashing = true

	var dir = last_dir_vector
	if dir == Vector2.ZERO:
		dir = Vector2.DOWN

	var dash_velocity = dir.normalized() * (dash_distance / dash_duration)
	var elapsed := 0.0

	# Drive dash via velocity so CharacterBody2D collision still applies mid-dash
	while elapsed < dash_duration:
		velocity = dash_velocity
		move_and_slide()
		elapsed += get_physics_process_delta_time()
		await get_tree().physics_frame

	velocity = Vector2.ZERO
	is_dashing = false

	dash_lockout_active = true
	await get_tree().create_timer(dash_attack_lockout).timeout
	dash_lockout_active = false


# --------------------
# Movement
# --------------------
func handle_movement(delta):

	var dir = Vector2.ZERO

	if Input.is_key_pressed(KEY_A):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		dir.x += 1
	if Input.is_key_pressed(KEY_W):
		dir.y -= 1
	if Input.is_key_pressed(KEY_S):
		dir.y += 1

	if dir != Vector2.ZERO:
		last_dir_vector = dir.normalized()

	velocity = dir.normalized() * speed
	move_and_slide()

	update_direction_and_animation(dir)


# --------------------
# Direction + Animation
# --------------------
func update_direction_and_animation(dir):

	if is_attacking:
		return

	if dir != Vector2.ZERO:
		last_dir_vector = dir.normalized()

		if abs(dir.x) > abs(dir.y):
			anim.play("run_right" if dir.x > 0 else "run_left")
		else:
			anim.play("run_down" if dir.y > 0 else "run_up")
	else:
		anim.play(get_idle_anim())


# --------------------
# Helpers
# --------------------
func get_idle_anim():

	if abs(last_dir_vector.x) > abs(last_dir_vector.y):
		return "idle_right" if last_dir_vector.x > 0 else "idle_left"
	else:
		return "idle_down" if last_dir_vector.y > 0 else "idle_up"
