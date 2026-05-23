# dummy.gd  (REFACTORED)
# Training dummy. Receives HitData via hurtbox signal.
# Applies damage, knockback impulse, and a simple visual flash.
# Does NOT use CombatController (it doesn't attack).
# Does NOT connect to anything in physics engine directly.
#
extends Node2D

@onready var anim: AnimatedSprite2D = $Body
@onready var hurtbox: Area2D = $Hurtbox

@export var max_hp: float = 150.0
var hp: float = max_hp

# Knockback is applied as a velocity impulse and decays over time.
# If Dummy is a CharacterBody2D, use move_and_slide with this velocity.
# If it's a static Node2D for testing, just print the value.
var knockback_velocity: Vector2 = Vector2.ZERO
const KNOCKBACK_DECAY: float = 0.85   # multiplied per physics frame


func _ready() -> void:
	anim.play("dummy_idle")
	hurtbox.hit_received.connect(_on_hit_received)


func _physics_process(_delta: float) -> void:
	# Decay knockback each frame (simple exponential falloff)
	if knockback_velocity.length() > 1.0:
		knockback_velocity *= KNOCKBACK_DECAY
		# If dummy were CharacterBody2D: velocity = knockback_velocity; move_and_slide()
	else:
		knockback_velocity = Vector2.ZERO


# ── Hit response ──────────────────────────────────────────────────────────────

func _on_hit_received(hit: HitData) -> void:
	if hit == null:
		return

	hp -= hit.damage
	hp  = max(hp, 0.0)
	knockback_velocity = hit.knockback_vector

	print("[Dummy] HIT — attacker:%s  dmg:%.1f  hp_remaining:%.1f  knockback:%s"
		% [hit.attacker.name, hit.damage, hp, knockback_velocity])

	# Flash white to show hit (visual only — doesn't affect game state)
	_flash_hit()

	if hp <= 0.0:
		_on_defeated()


func _flash_hit() -> void:
	# Simple modulate flash — replace with shader or animation as needed
	anim.modulate = Color.WHITE * 3.0
	await get_tree().create_timer(0.08).timeout  # visual only, not game logic
	anim.modulate = Color.WHITE


func _on_defeated() -> void:
	print("[Dummy] Defeated — respawning...")
	await get_tree().create_timer(1.0).timeout
	hp = max_hp
	anim.play("dummy_idle")
