extends Node2D

@export var speed := 150
@export var dash_distance := 50
@export var dash_duration := 0.1
@export var dash_attack_lockout := 0.25  # seconds after dash ends before attacking is allowed

@onready var anim = $Body
@onready var weapon = $WeaponHolder/Sword

var is_dashing := false
var is_attacking := false
var dash_lockout_active := false

var last_dir_vector := Vector2.DOWN


func _ready():
	# Hide the sword/attack animation by default
	weapon.visible = false


func _process(delta):

	handle_input()

	# Dash blocks everything — no movement, no attack
	if is_dashing:
		return

	# Attack blocks movement — player is locked in attack state
	if is_attacking:
		return

	handle_movement(delta)


# --------------------
# Input
# --------------------
func handle_input():

	if Input.is_action_just_pressed("dash"):
		dash()
		return  # Prevent attack registering on the same frame as dash

	if Input.is_action_just_pressed("light_attack"):
		try_attack()


# --------------------
# ATTACK
# --------------------
func try_attack():

	# Blocked: still dashing or in post-dash lockout
	if is_dashing or dash_lockout_active:
		return

	# Blocked: sword is still on cooldown — don't lock the player up for nothing
	if not weapon.can_attack:
		return

	# Blocked: already mid-attack
	if is_attacking:
		return

	light_attack()


func light_attack():

	is_attacking = true

	# Hard-interrupt movement: snap to idle in last-faced direction immediately
	anim.play(get_idle_anim())

	# Show weapon, play attack
	weapon.visible = true
	weapon.attack_light()

	# Hold player in attack state for the sword's cooldown duration
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

	var tween = create_tween()
	tween.tween_property(
		self,
		"position",
		position + dir.normalized() * dash_distance,
		dash_duration
	)

	await tween.finished

	is_dashing = false

	# Brief lockout so player can't immediately attack out of a dash
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

	position += dir.normalized() * speed * delta

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
