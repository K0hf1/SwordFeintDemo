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
# ── Respawn ───────────────────────────────────────────────────────────────────
#   When a player's HP reaches zero, PlayerHealth removes the player node and
#   emits player_died. ArenaTest listens and schedules a respawn after 2 seconds
#   using _respawn_player(), which re-instances the scene at the original spawn
#   position with the same InputProfile.
#
extends Node2D

const PLAYER_SCENE := preload("res://player.tscn")
const RESPAWN_DELAY: float = 2.0

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var _spawn_a:  Marker2D = $Arena/SpawnA
@onready var _spawn_b:  Marker2D = $Arena/SpawnB
@onready var _players:  Node2D   = $Players

# Live references — updated on spawn and respawn; may be null while dead
var player_a: CharacterBody2D = null
var player_b: CharacterBody2D = null

# Stored profiles — needed for respawning without re-creating them
var _profile_a: InputProfile = null
var _profile_b: InputProfile = null


func _ready() -> void:
	_profile_a = InputProfile.for_player_a()
	_profile_b = InputProfile.for_player_b()

	player_a = _spawn_player(_profile_a, _spawn_a.position, "PlayerA")
	player_b = _spawn_player(_profile_b, _spawn_b.position, "PlayerB")

	print("[ArenaTest] Ready. PlayerA at %s, PlayerB at %s"
		% [player_a.global_position, player_b.global_position])


# ── Spawn helper ──────────────────────────────────────────────────────────────
func _spawn_player(profile: InputProfile, spawn_pos: Vector2,
		node_name: String) -> CharacterBody2D:

	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	p.name = node_name
	_players.add_child(p)
	p.global_position = spawn_pos

	var provider := LocalInputProvider.new(profile)
	p.set_input_provider(provider)

	_configure_player_collision(p)

	# Connect death signal for respawn handling
	var health: Node = p.get_node_or_null("PlayerHealth")
	if health != null:
		health.player_died.connect(_on_player_died.bind(node_name, profile, spawn_pos))

	return p


# ── Death / Respawn ───────────────────────────────────────────────────────────
func _on_player_died(node_name: String, profile: InputProfile, spawn_pos: Vector2) -> void:
	print("[ArenaTest] %s died — respawning in %.1fs." % [node_name, RESPAWN_DELAY])
	# Null out the live reference immediately so debug overlay skips it
	if node_name == "PlayerA":
		player_a = null
	else:
		player_b = null

	# Wait, then respawn
	await get_tree().create_timer(RESPAWN_DELAY).timeout
	_respawn_player(profile, spawn_pos, node_name)


func _respawn_player(profile: InputProfile, spawn_pos: Vector2, node_name: String) -> void:
	print("[ArenaTest] Respawning %s at %s." % [node_name, spawn_pos])
	var p := _spawn_player(profile, spawn_pos, node_name)
	if node_name == "PlayerA":
		player_a = p
	else:
		player_b = p


# ── Debug overlay (F1 toggle) ─────────────────────────────────────────────────
var _show_debug: bool = true

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		_show_debug = not _show_debug

func _draw() -> void:
	if not _show_debug:
		return

	if player_a != null and is_instance_valid(player_a):
		var combat_a: Node = player_a.get_node_or_null("CombatController")
		_draw_player_debug(player_a, combat_a, "A", Color.CORNFLOWER_BLUE)

	if player_b != null and is_instance_valid(player_b):
		var combat_b: Node = player_b.get_node_or_null("CombatController")
		_draw_player_debug(player_b, combat_b, "B", Color.TOMATO)

func _draw_player_debug(player: CharacterBody2D, combat: Node,
		label: String, col: Color) -> void:
	var lpos := to_local(player.global_position)
	draw_circle(lpos, 5.0, col)

	var state_str: String = "?"
	if combat != null:
		state_str = str(combat.combat_state)

	# Show HP alongside combat state if PlayerHealth exists
	var hp_str: String = ""
	var health: Node = player.get_node_or_null("PlayerHealth")
	if health != null:
		hp_str = "  HP:%.0f/%.0f" % [health.get_hp(), health.get_max_hp()]

	draw_string(ThemeDB.fallback_font,
		lpos + Vector2(10, -20),
		"P%s %s%s" % [label, state_str, hp_str],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)

func _process(_delta: float) -> void:
	if _show_debug:
		queue_redraw()


# ── Collision layer enforcement (runtime) ─────────────────────────────────────
func _configure_player_collision(player: CharacterBody2D) -> void:
	player.collision_layer = 0b0010
	player.collision_mask  = 0b0011
	player.motion_mode     = CharacterBody2D.MOTION_MODE_FLOATING
