# arena_test.gd
# Local 1v1 test scene controller.
# Attach to the root Node2D of ArenaTest.tscn.
#
# ── What this scene validates ────────────────────────────────────────────────
#   - Two independent player instances from the same player.tscn
#   - Independent input profiles (Player A = WASD/Mouse, Player B = Arrows/Numpad)
#   - Combat interactions: RPS, hitstun, parry, guard, armor
#   - Simultaneous input handling (no shared state between players)
#   - Architecture readiness for future network authority assignment
#
# ── Scene tree (build manually in Godot editor) ──────────────────────────────
#   ArenaTest (Node2D)                     ← this script
#     ├── Arena (Node2D)
#     │     ├── Walls (Node2D)
#     │     │     ├── WallTop    (StaticBody2D + CollisionShape2D)
#     │     │     ├── WallBottom (StaticBody2D + CollisionShape2D)
#     │     │     ├── WallLeft   (StaticBody2D + CollisionShape2D)
#     │     │     └── WallRight  (StaticBody2D + CollisionShape2D)
#     │     ├── SpawnA (Marker2D)           ← position: (-200, 0)
#     │     └── SpawnB (Marker2D)           ← position: ( 200, 0)
#     └── Players (Node2D)
#           ├── PlayerA  ← instanced from player.tscn at runtime
#           └── PlayerB  ← instanced from player.tscn at runtime
#
# ── Input actions to register (Project Settings → Input Map) ─────────────────
#   p2_parry  → Numpad 1
#   p2_dash   → Numpad 2
#   p2_guard  → Numpad 3
#   (Player A uses existing actions: light_attack, heavy_attack, dash, guard,
#    parry, weapon_switch, ultimate — no changes needed)
#
extends Node2D

const PLAYER_SCENE := preload("res://player.tscn")

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var _spawn_a:  Marker2D = $Arena/SpawnA
@onready var _spawn_b:  Marker2D = $Arena/SpawnB
@onready var _players:  Node2D   = $Players

# Live references — set during _ready(), used for debug overlay
var player_a: CharacterBody2D = null
var player_b: CharacterBody2D = null


func _ready() -> void:
	player_a = _spawn_player(InputProfile.for_player_a(), _spawn_a.position, "PlayerA")
	player_b = _spawn_player(InputProfile.for_player_b(), _spawn_b.position, "PlayerB")

	print("[ArenaTest] Ready. PlayerA at %s, PlayerB at %s"
		% [player_a.global_position, player_b.global_position])


# ── Collision layer setup ─────────────────────────────────────────────────────
# Called from _spawn_player after instancing. Enforces the layer layout so
# players cannot physically push/drag each other via CharacterBody2D resolution,
# while still colliding with walls.
#
# Layer layout (configure matching names in Project → Layer Names → 2D Physics):
#   Layer 1 "world"    — walls, floor, static environment
#   Layer 2 "player"   — player body colliders
#   Layer 3 "hitbox"   — Area2D hitboxes and hurtboxes (no physics interaction)
#
# Players:
#   collision_layer = 0b010  (layer 2 — "I am a player body")
#   collision_mask  = 0b001  (mask 1 — "I collide with world only")
#
# Result: players cannot physically interact with each other's CharacterBody2D.
# Hit detection is done by Area2D overlap queries (unaffected by physics layers).


# ── Spawn helper ──────────────────────────────────────────────────────────────
func _spawn_player(profile: InputProfile, spawn_pos: Vector2,
		node_name: String) -> CharacterBody2D:

	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	p.name = node_name
	_players.add_child(p)
	p.global_position = spawn_pos

	# Assign input provider AFTER add_child so @onready vars inside player are valid.
	# LocalInputProvider is a plain RefCounted — no add_child needed.
	var provider := LocalInputProvider.new(profile)
	p.set_input_provider(provider)

	# Enforce physics layer layout — players collide with walls, not each other.
	# Area2D hitboxes/hurtboxes are unaffected (they use collision_layer independently).
	_configure_player_collision(p)

	return p


# ── Debug overlay (F1 toggle) ─────────────────────────────────────────────────
var _show_debug: bool = true

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		_show_debug = not _show_debug

func _draw() -> void:
	if not _show_debug or player_a == null or player_b == null:
		return

	var combat_a: Node = player_a.get_node("CombatController")
	var combat_b: Node = player_b.get_node("CombatController")

	_draw_player_debug(player_a, combat_a, "A", Color.CORNFLOWER_BLUE)
	_draw_player_debug(player_b, combat_b, "B", Color.TOMATO)

func _draw_player_debug(player: CharacterBody2D, combat: Node,
		label: String, col: Color) -> void:
	# Convert from global to local draw coords
	var lpos := to_local(player.global_position)
	draw_circle(lpos, 5.0, col)

	var state_str: String = "?"
	if combat != null:
		state_str = str(combat.combat_state)

	draw_string(ThemeDB.fallback_font,
		lpos + Vector2(10, -20),
		"P%s %s" % [label, state_str],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)

func _process(_delta: float) -> void:
	if _show_debug:
		queue_redraw()   # redraw debug overlay every frame


# ── Collision layer enforcement (runtime) ─────────────────────────────────────
# Sets layers/masks directly on the spawned player so the scene file doesn't
# need to be manually configured. Override here if your layer numbering differs.
func _configure_player_collision(player: CharacterBody2D) -> void:
	# Layer layout:
	#   Layer 1 = world / walls (StaticBody2D nodes)
	#   Layer 2 = player bodies
	#
	# Players are ON layer 2 and MASK both layer 1 (walls) and layer 2 (other players).
	# This means CharacterBody2D physics WILL push players apart — bodies don't pass
	# through each other — but we prevent the "drag" artifact using MOTION_MODE_FLOATING
	# (set in player.gd). Floating mode means move_and_slide does not project velocity
	# onto a floor normal, so a player standing still cannot be dragged sideways by
	# another player's collision resolution.
	player.collision_layer = 0b0010        # I am on the player layer
	player.collision_mask  = 0b0011        # I collide with world (1) AND other players (2)
	player.motion_mode     = CharacterBody2D.MOTION_MODE_FLOATING
