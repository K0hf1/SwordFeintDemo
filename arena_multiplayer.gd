# arena_multiplayer.gd
# Multiplayer arena controller. Attach to the root Node2D of arena_multiplayer.tscn.
#
# ── HOW THIS REPLACES arena_test.gd ──────────────────────────────────────────
# arena_test.gd spawned two players immediately in _ready() with hardcoded
# InputProfile.for_player_a() / for_player_b(). That approach is local-only
# because both players run on the same machine and the caller decides profiles.
#
# arena_multiplayer.gd instead:
#   1. Registers itself with NetworkManager on _ready()
#   2. Waits for NetworkManager to call spawn_player() / respawn_player() via RPC
#   3. Assigns input providers based on multiplayer authority — the local peer
#      gets a LocalInputProvider; the remote peer gets a NullInputProvider so
#      it idles until future input-sync RPCs arrive
#
# ── SCENE STRUCTURE (arena_multiplayer.tscn) ──────────────────────────────────
#   Node2D  (this script)
#   ├── Arena
#   │   ├── SpawnA  (Marker2D)   ← player index 0 spawn point
#   │   └── SpawnB  (Marker2D)   ← player index 1 spawn point
#   └── Players  (Node2D)         ← all player instances are added here
#
# ── LOCAL PLAY FALLBACK ───────────────────────────────────────────────────────
# If no multiplayer peer is active (offline / testing), _ready() detects the
# absence of a peer and falls back to local mode: spawns both players with
# their original InputProfile assignments, exactly as arena_test.gd did.
# This keeps the local test workflow intact without maintaining two scenes.
#
extends Node2D

const PLAYER_SCENE := preload("res://player.tscn")
const RESPAWN_DELAY: float = 2.0

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var _spawn_a:  Marker2D = $Arena/SpawnA
@onready var _spawn_b:  Marker2D = $Arena/SpawnB
@onready var _players:  Node2D   = $Players

# ── Live player references ────────────────────────────────────────────────────
# Indexed by player_index (0 = PlayerA, 1 = PlayerB).
# Entries are null while the player is dead.
var _player_nodes: Array[CharacterBody2D] = [null, null]

# Peer IDs for each player slot — needed for multiplayer_authority assignment.
var _peer_ids: Array[int] = [1, 1]   # defaults; overwritten by spawn_player()

# Cached at _ready() so the debug draw never calls get_unique_id() on a null peer.
var _local_peer_id: int = 1

# ── Debug overlay ─────────────────────────────────────────────────────────────
var _show_debug: bool = true


func _ready() -> void:
	# Use NetworkManager's cached peer ID — it's set at connection time, before
	# the arena scene loads, so it's always correct on both host and client.
	# Calling multiplayer.get_unique_id() here was unreliable on the client
	# because the ENet handshake timing meant it sometimes returned 1 (host ID).
	_local_peer_id = NetworkManager.get_local_peer_id()

	if _is_networked():
		# Networked mode: tell NetworkManager we're live; it will RPC spawn_player
		NetworkManager.arena_ready(self)
		print("[Arena] Networked mode — waiting for spawn commands.")
	else:
		# Local / offline mode: replicate the original arena_test.gd behaviour
		print("[Arena] Local mode — spawning both players immediately.")
		_spawn_local_fallback()


# ── Public API (called by NetworkManager via RPC) ─────────────────────────────

# Spawn a player for the given peer at the given position.
# Called on ALL peers (call_local RPC from host).
func spawn_player(peer_id: int, player_index: int, spawn_pos: Vector2) -> void:
	if player_index < 0 or player_index > 1:
		push_error("[Arena] spawn_player: invalid player_index %d" % player_index)
		return

	# Remove any existing node in this slot (shouldn't happen on initial spawn)
	_remove_player_node(player_index)

	_peer_ids[player_index] = peer_id
	var node_name := "Player%d_Peer%d" % [player_index, peer_id]

	var p := _instantiate_player(peer_id, player_index, spawn_pos, node_name)
	_player_nodes[player_index] = p

	# Connect death for respawn — bind peer_id and player_index for the RPC
	var health: Node = p.get_node_or_null("PlayerHealth")
	if health != null:
		health.player_died.connect(
			_on_player_died.bind(peer_id, player_index, spawn_pos))

	print("[Arena] Spawned player_index:%d  peer:%d  pos:%s  authority:%s"
		% [player_index, peer_id, spawn_pos,
		   "LOCAL" if peer_id == _local_peer_id else "REMOTE"])


# Despawn then respawn. Called on ALL peers by host RPC.
func respawn_player(peer_id: int, player_index: int, spawn_pos: Vector2) -> void:
	_remove_player_node(player_index)
	spawn_player(peer_id, player_index, spawn_pos)


# Return the world position of a spawn marker by index.
func get_spawn_position(player_index: int) -> Vector2:
	match player_index:
		0: return _spawn_a.global_position
		1: return _spawn_b.global_position
		_: return Vector2.ZERO


# ── Death handler ─────────────────────────────────────────────────────────────

func _on_player_died(peer_id: int, player_index: int, spawn_pos: Vector2) -> void:
	print("[Arena] player_index:%d (peer:%d) died — respawning in %.1fs."
		% [player_index, peer_id, RESPAWN_DELAY])
	_player_nodes[player_index] = null

	# Only the host schedules the respawn RPC; clients just wait for the command.
	if NetworkManager.is_host():
		_schedule_respawn(peer_id, player_index, spawn_pos)


func _schedule_respawn(peer_id: int, player_index: int, spawn_pos: Vector2) -> void:
	await get_tree().create_timer(RESPAWN_DELAY).timeout
	# RPC triggers respawn on all peers simultaneously
	NetworkManager.rpc("rpc_respawn_player", peer_id, player_index, spawn_pos)


# ── Local fallback (no network peer active) ───────────────────────────────────

func _spawn_local_fallback() -> void:
	# Replicates the exact behaviour of the original arena_test.gd.
	# Uses peer_id = 1 for both (host conventions; authority doesn't matter locally).
	spawn_player(1, 0, _spawn_a.global_position)
	spawn_player(2, 1, _spawn_b.global_position)

	# In local mode the death handler's host check would block respawns because
	# NetworkManager.is_host() returns true but there's no second peer to RPC.
	# The fallback spawn already connected the health signal with peer/index bound,
	# so _on_player_died → _schedule_respawn → rpc_respawn_player works fine:
	# rpc with call_local and no actual peer just runs locally.
	print("[Arena] Local fallback: PlayerA at %s, PlayerB at %s"
		% [_spawn_a.global_position, _spawn_b.global_position])


# ── Player instantiation ──────────────────────────────────────────────────────

func _instantiate_player(peer_id: int, player_index: int,
		spawn_pos: Vector2, node_name: String) -> CharacterBody2D:

	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	p.name = node_name

	# Set multiplayer authority BEFORE adding to tree so Godot registers it
	# correctly for any @rpc methods on the player or its children.
	p.set_multiplayer_authority(peer_id)

	_players.add_child(p)
	p.global_position = spawn_pos

	_configure_collision(p)

	# Assign input provider based on authority
	_assign_input_provider(p, peer_id, player_index)

	return p


func _assign_input_provider(player: CharacterBody2D,
		peer_id: int, _player_index: int) -> void:

	var is_local := (peer_id == _local_peer_id)

	if is_local or not _is_networked():
		# This machine controls this player.
		# Always use for_player_a() — each peer uses their own primary bindings.
		# In local fallback mode, peer_id 1 = slot 0 (WASD) and peer_id 2 = slot 1
		# (Arrows), so we keep the original index-based split only for local mode.
		var profile: InputProfile
		if not _is_networked():
			# Local mode: preserve original two-keyboard split
			profile = InputProfile.for_player_a() if _player_index == 0 else InputProfile.for_player_b()
		else:
			# Networked mode: every peer uses their own machine's primary bindings
			profile = InputProfile.for_player_a()
		player.set_input_provider(LocalInputProvider.new(profile))
	else:
		# Remote player on this machine — idle until input-sync RPC is added.
		player.set_input_provider(NullInputProvider.new())


func _remove_player_node(player_index: int) -> void:
	var existing := _player_nodes[player_index]
	if existing != null and is_instance_valid(existing):
		existing.queue_free()
	_player_nodes[player_index] = null


func _configure_collision(player: CharacterBody2D) -> void:
	player.collision_layer = 0b0010
	player.collision_mask  = 0b0011
	player.motion_mode     = CharacterBody2D.MOTION_MODE_FLOATING


# ── Helpers ───────────────────────────────────────────────────────────────────

func _is_networked() -> bool:
	# True when an actual ENet peer is active (host or client).
	# False during local offline testing.
	return (multiplayer.multiplayer_peer != null
		and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer))


# ── Debug overlay (F1 toggle) ─────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		_show_debug = not _show_debug


func _process(_delta: float) -> void:
	if _show_debug:
		queue_redraw()


func _draw() -> void:
	if not _show_debug:
		return
	var colors := [Color.CORNFLOWER_BLUE, Color.TOMATO]
	var labels := ["A", "B"]
	for i in 2:
		var p := _player_nodes[i]
		if p != null and is_instance_valid(p):
			var combat: Node = p.get_node_or_null("CombatController")
			_draw_player_debug(p, combat, labels[i], colors[i], _peer_ids[i])


func _draw_player_debug(player: CharacterBody2D, combat: Node,
		label: String, col: Color, peer_id: int) -> void:
	var lpos := to_local(player.global_position)
	draw_circle(lpos, 5.0, col)

	var state_str := "?" if combat == null else str(combat.combat_state)

	var hp_str := ""
	var health: Node = player.get_node_or_null("PlayerHealth")
	if health != null:
		hp_str = "  HP:%.0f/%.0f" % [health.get_hp(), health.get_max_hp()]

	var auth_str := " [LOCAL]" if peer_id == _local_peer_id else " [REMOTE]"

	draw_string(ThemeDB.fallback_font,
		lpos + Vector2(10, -20),
		"P%s %s%s%s" % [label, state_str, hp_str, auth_str],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)
