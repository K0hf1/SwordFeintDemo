# combat_controller.gd
# The authoritative combat state machine. Attach as a child of Player.
# This script owns: combat state, tick progression, frame data, hit registration.
# It does NOT own: movement, rendering, or input collection.
#
# Node setup:
#   Player
#     └── CombatController   ← this script
#
# Requires these @onready paths to be set to match your scene tree:
#   @onready var hitbox = $"../WeaponHolder/Sword/LightAttack/HitboxSL"
#   @onready var sword  = $"../WeaponHolder/Sword"
#   @onready var anim   = $"../Body"
#
extends Node

# ── State ────────────────────────────────────────────────────────────────────
enum CombatState { IDLE, STARTUP, ACTIVE, RECOVERY, HITSTUN }

var combat_state: CombatState = CombatState.IDLE
var tick_counter: int = 0          # monotonically increasing, never reset

# ── Current attack ───────────────────────────────────────────────────────────
var current_attack: AttackData = null
var hit_this_swing: Dictionary = {}   # { hurtbox_node: true } — per-swing hit registry

# ── Combo tracking ───────────────────────────────────────────────────────────
var combo_count: int = 0
var last_attack_id: String = ""

# ── Attack library ───────────────────────────────────────────────────────────
# Populate these via @export or load from .tres files.
# @export var attack_light: AttackData
# @export var attack_light2: AttackData
# For now we build defaults in _ready() so the game runs without .tres files.
var attacks: Dictionary = {}

# ── Node references (adjust paths to match your scene tree) ─────────────────
@onready var hitbox: Area2D = $"../WeaponHolder/Sword/LightAttack/HitboxSL"
@onready var sword: Node2D  = $"../WeaponHolder/Sword"
@onready var anim: AnimatedSprite2D = $"../Body"

# Cached reference to player (owner) for direction/position calculations
@onready var player: CharacterBody2D = get_parent()


func _ready() -> void:
	# Build default attack data. Replace with .tres @exports when ready.
	var light := AttackData.new()
	light.attack_id        = "light"
	light.startup_frames   = 4
	light.active_frames    = 5
	light.recovery_frames  = 8
	light.damage           = 10.0
	light.knockback_force  = 220.0
	light.knockback_angle_deg = 35.0
	light.hitstun_frames   = 12
	light.combo_followup_id = "light2"
	light.combo_window_frames = 5
	attacks["light"] = light

	var light2 := AttackData.new()
	light2.attack_id        = "light2"
	light2.startup_frames   = 3
	light2.active_frames    = 4
	light2.recovery_frames  = 10
	light2.damage           = 8.0
	light2.knockback_force  = 180.0
	light2.knockback_angle_deg = 50.0
	light2.hitstun_frames   = 10
	light2.combo_followup_id = ""
	attacks["light2"] = light2

	# Hitbox starts inactive
	hitbox.monitoring = false


# ── Main tick — called by player._physics_process each frame ─────────────────
func tick(input: InputSnapshot) -> void:
	tick_counter += 1
	_process_combat_state(input)


# ── Public queries for player.gd ─────────────────────────────────────────────

func can_move() -> bool:
	return combat_state == CombatState.IDLE

func is_busy() -> bool:
	return combat_state != CombatState.IDLE

func get_state() -> CombatState:
	return combat_state


# ── State machine ────────────────────────────────────────────────────────────

func _process_combat_state(input: InputSnapshot) -> void:
	match combat_state:

		CombatState.IDLE:
			if input.light_attack_pressed:
				_begin_attack(_select_attack(input))

		CombatState.STARTUP:
			if tick_counter >= current_attack.startup_end_tick:
				_enter_active()

		CombatState.ACTIVE:
			_query_hits()
			if tick_counter >= current_attack.active_end_tick:
				_enter_recovery()

		CombatState.RECOVERY:
			# Combo cancel window: check for follow-up input near end of recovery
			if current_attack.combo_followup_id != "":
				var combo_open = current_attack.recovery_end_tick - current_attack.combo_window_frames
				if tick_counter >= combo_open and input.light_attack_pressed:
					var followup = attacks.get(current_attack.combo_followup_id, null)
					if followup != null:
						combo_count += 1
						_begin_attack(followup)
						return

			if tick_counter >= current_attack.recovery_end_tick:
				_enter_idle()

		CombatState.HITSTUN:
			# Hitstun is driven externally by whoever called enter_hitstun().
			# It uses the same tick-counter pattern.
			if tick_counter >= _hitstun_end_tick:
				_enter_idle()


# ── State transitions ────────────────────────────────────────────────────────

func _begin_attack(data: AttackData) -> void:
	# Track combo chain
	if last_attack_id == "" or last_attack_id != data.attack_id:
		pass  # not a followup, combo_count handled by caller
	last_attack_id = data.attack_id

	current_attack = data
	current_attack.compute_ticks(tick_counter)
	hit_this_swing.clear()
	combat_state = CombatState.STARTUP

	# Tell weapon to aim and start its visual
	sword.execute_attack(data, player.last_aim_direction)

	# Visual feedback (does not drive state)
	anim.play("idle_" + _dir_suffix(player.last_dir_vector))

	print("[Combat] STARTUP — attack:%s  startup_end:%d  active_end:%d  recovery_end:%d"
		% [data.attack_id, data.startup_end_tick, data.active_end_tick, data.recovery_end_tick])


func _enter_active() -> void:
	combat_state = CombatState.ACTIVE
	hitbox.monitoring = true
	# Optional: play active-frame animation here
	print("[Combat] ACTIVE — tick:%d" % tick_counter)


func _enter_recovery() -> void:
	combat_state = CombatState.RECOVERY
	hitbox.monitoring = false
	print("[Combat] RECOVERY — tick:%d" % tick_counter)


func _enter_idle() -> void:
	combat_state = CombatState.IDLE
	hitbox.monitoring = false
	hit_this_swing.clear()
	current_attack = null
	combo_count = 0
	last_attack_id = ""
	sword.visible = false
	print("[Combat] IDLE — tick:%d" % tick_counter)


# ── Hit registration (called each ACTIVE tick) ───────────────────────────────

func _query_hits() -> void:
	for area in hitbox.get_overlapping_areas():
		if not area.is_in_group("enemy_hurtbox"):
			continue
		if hit_this_swing.has(area):
			continue  # already hit this target this swing

		hit_this_swing[area] = true

		var hit := _build_hit_data(area)
		area.hit_received.emit(hit)

		print("[Combat] HIT — target:%s  damage:%.1f" % [area.get_parent().name, hit.damage])


func _build_hit_data(target_hurtbox: Area2D) -> HitData:
	var hit := HitData.new()
	hit.attacker       = player
	hit.attack_id      = current_attack.attack_id
	hit.damage         = current_attack.damage
	hit.hitstun_frames = current_attack.hitstun_frames

	# Compute knockback vector: direction from player to target, rotated by angle
	var to_target := (target_hurtbox.global_position - player.global_position).normalized()
	var angle_rad  := deg_to_rad(current_attack.knockback_angle_deg)
	# Rotate the push direction upward (negative y in Godot 2D = up)
	var kb_dir := Vector2(to_target.x, -abs(sin(angle_rad))).normalized()
	hit.knockback_vector = kb_dir * current_attack.knockback_force

	return hit


# ── Hitstun entry (called by health/damage system when this player is hit) ───

var _hitstun_end_tick: int = 0

func enter_hitstun(frames: int) -> void:
	combat_state = CombatState.HITSTUN
	hitbox.monitoring = false
	_hitstun_end_tick = tick_counter + frames
	hit_this_swing.clear()
	print("[Combat] HITSTUN for %d frames" % frames)


# ── Attack selection ─────────────────────────────────────────────────────────

func _select_attack(input: InputSnapshot) -> AttackData:
	# Directional: if aiming up strongly, use upward attack when you have one
	# var aim = input.aim_direction
	# if aim.y < -0.7 and attacks.has("light_up"):
	#     return attacks["light_up"]
	return attacks["light"]


# ── Helpers ──────────────────────────────────────────────────────────────────

func _dir_suffix(dir: Vector2) -> String:
	if abs(dir.x) > abs(dir.y):
		return "right" if dir.x > 0 else "left"
	return "down" if dir.y > 0 else "up"
