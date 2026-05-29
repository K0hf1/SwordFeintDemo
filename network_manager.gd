# network_manager.gd
# Autoload singleton. Add to Project → Project Settings → Autoload as "NetworkManager".
#
# ── RESPONSIBILITIES ──────────────────────────────────────────────────────────
#   - Create / destroy the ENet multiplayer peer (host or client)
#   - Track which peer_id owns which player slot
#   - Signal the UI about connection state changes
#   - Tell the Arena scene when it's safe to spawn players
#   - NOT responsible for spawning directly — it tells ArenaMultiplayer to spawn
#
# ── PEER ID → SPAWN SLOT RULES ───────────────────────────────────────────────
#   Host  (unique_id == 1)  → always spawns as player_index 0 (SpawnA)
#   Client (unique_id != 1) → always spawns as player_index 1 (SpawnB)
#
#   peer_registry maps  peer_id → player_index  so the Arena can look up
#   "which spawn point does peer X own?" without coupling to the host/client
#   distinction at the Arena level.
#
# ── SCENE FLOW ────────────────────────────────────────────────────────────────
#   host_game()
#       creates ENetMultiplayerPeer server
#       connects peer_connected / disconnected signals
#       loads Arena scene immediately (host doesn't wait)
#
#   join_game(ip)
#       creates ENetMultiplayerPeer client
#       on connected_to_server → loads Arena scene
#       on connection_failed   → emits status signal
#
#   Arena _ready() calls NetworkManager.arena_ready()
#       host: calls _do_spawn_all() — spawns both players if both peers registered
#       client: no-op, waits for host RPC spawn command
#
# ── CONFLICT NOTE ─────────────────────────────────────────────────────────────
#   GameClock is an autoload that advances via _physics_process when NOT a client.
#   NetworkManager does NOT call GameClock.set_tick() itself — that belongs in a
#   future LockstepManager. For now, both peers run their own clocks (host-driven
#   clock sync is stubbed in GameClock and ready to wire up).
#
extends Node

# ── Configuration ─────────────────────────────────────────────────────────────
const DEFAULT_PORT: int  = 7777
const MAX_CLIENTS:  int  = 1   # strict 1v1; raise for lobbies

# ── Signals (connect these in your UI / Arena) ────────────────────────────────
signal status_changed(message: String)   # human-readable state for the UI label
signal connection_failed()               # client could not reach host
signal server_disconnected()             # host dropped while client was in game
signal all_peers_ready()                 # host emits when both slots are filled

# ── Peer registry ─────────────────────────────────────────────────────────────
# peer_id → player_index (0 = PlayerA/SpawnA, 1 = PlayerB/SpawnB)
var peer_registry: Dictionary = {}

# Reference to the current Arena scene root (set by ArenaMultiplayer._ready)
var _arena: Node = null


# ── Public API ────────────────────────────────────────────────────────────────

func host_game(port: int = DEFAULT_PORT) -> void:
	_reset()

	var peer := ENetMultiplayerPeer.new()
	var err  := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		_emit_status("ERROR: could not open port %d (err %d)" % [port, err])
		return

	multiplayer.multiplayer_peer = peer

	# Host always owns player index 0
	_register_peer(multiplayer.get_unique_id(), 0)

	# Wire ENet signals
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	_emit_status("Hosting on port %d — waiting for opponent…" % port)
	_load_arena()


func join_game(ip: String, port: int = DEFAULT_PORT) -> void:
	_reset()

	var peer := ENetMultiplayerPeer.new()
	var err  := peer.create_client(ip, port)
	if err != OK:
		_emit_status("ERROR: could not create client (err %d)" % err)
		return

	multiplayer.multiplayer_peer = peer

	# Wire ENet signals
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	_emit_status("Connecting to %s:%d…" % [ip, port])


# Called by ArenaMultiplayer._ready() so NetworkManager knows the arena is live.
func arena_ready(arena: Node) -> void:
	_arena = arena
	if _is_host():
		# If the client connected before the arena finished loading, spawn now.
		# Otherwise _on_peer_connected will call this once the second peer joins.
		_try_spawn_all()


# ── Host RPC: tell all peers to spawn a specific player ──────────────────────
# Called on host; relayed to all peers (including host itself via call_local).
@rpc("authority", "call_local", "reliable")
func rpc_spawn_player(peer_id: int, player_index: int, spawn_pos: Vector2) -> void:
	if _arena == null:
		push_error("[NetworkManager] rpc_spawn_player: _arena is null on peer %d"
			% multiplayer.get_unique_id())
		return
	_arena.spawn_player(peer_id, player_index, spawn_pos)


# ── Host RPC: tell all peers to despawn and respawn a player ─────────────────
@rpc("authority", "call_local", "reliable")
func rpc_respawn_player(peer_id: int, player_index: int, spawn_pos: Vector2) -> void:
	if _arena == null:
		return
	_arena.respawn_player(peer_id, player_index, spawn_pos)


# ── Queries ───────────────────────────────────────────────────────────────────

func get_local_peer_id() -> int:
	return multiplayer.get_unique_id()

func get_local_player_index() -> int:
	return peer_registry.get(get_local_peer_id(), -1)

func is_host() -> bool:
	return _is_host()


# ── ENet callbacks ────────────────────────────────────────────────────────────

func _on_peer_connected(peer_id: int) -> void:
	# Only the host receives this signal (clients get connected_to_server).
	# Assign the joining client to player index 1.
	_register_peer(peer_id, 1)
	_emit_status("Opponent connected (peer %d) — starting match!" % peer_id)
	_try_spawn_all()


func _on_peer_disconnected(peer_id: int) -> void:
	_emit_status("Opponent disconnected (peer %d)." % peer_id)
	peer_registry.erase(peer_id)
	# Future: notify Arena to freeze / show disconnect screen


func _on_connected_to_server() -> void:
	# Client successfully reached the host.
	# Do NOT self-register in peer_registry here — only the host writes that
	# registry. The host will RPC rpc_spawn_player to all peers with the correct
	# peer_id and player_index once _on_peer_connected fires on its side.
	_emit_status("Connected! Loading arena…")
	_load_arena()


func _on_connection_failed() -> void:
	_emit_status("Connection failed — check the IP and try again.")
	connection_failed.emit()
	multiplayer.multiplayer_peer = null


func _on_server_disconnected() -> void:
	_emit_status("Host disconnected.")
	server_disconnected.emit()
	multiplayer.multiplayer_peer = null


# ── Internal ──────────────────────────────────────────────────────────────────

func _is_host() -> bool:
	if multiplayer.multiplayer_peer == null:
		return true   # local / offline mode — behave as host
	return multiplayer.get_unique_id() == 1


func _register_peer(peer_id: int, player_index: int) -> void:
	peer_registry[peer_id] = player_index
	print("[NetworkManager] Registered peer %d → player_index %d" % [peer_id, player_index])


func _try_spawn_all() -> void:
	# Only host spawns. Only spawn when arena is ready AND both peers registered.
	if not _is_host():
		return
	if _arena == null:
		return   # arena_ready() will call us again once the scene is loaded

	# In a 1v1 we need exactly 2 entries: index 0 (host) and index 1 (client)
	var has_slot_0 := false
	var has_slot_1 := false
	for idx in peer_registry.values():
		if idx == 0: has_slot_0 = true
		if idx == 1: has_slot_1 = true

	if not (has_slot_0 and has_slot_1):
		return   # still waiting for the second peer

	all_peers_ready.emit()

	# Tell every peer (including self) to spawn each player.
	# spawn_positions are read from the Arena's Marker2D nodes.
	var pos_a: Vector2 = _arena.get_spawn_position(0)
	var pos_b: Vector2 = _arena.get_spawn_position(1)

	for pid in peer_registry:
		var idx: int = peer_registry[pid]
		var pos: Vector2 = pos_a if idx == 0 else pos_b
		rpc("rpc_spawn_player", pid, idx, pos)


func _load_arena() -> void:
	# Defer so the calling frame (host_game / _on_connected_to_server) completes
	# before the scene tree changes.
	call_deferred("_do_load_arena")


func _do_load_arena() -> void:
	get_tree().change_scene_to_file("res://arena_multiplayer.tscn")


func _reset() -> void:
	peer_registry.clear()
	_arena = null

	# Disconnect any leftover ENet signals to avoid duplicate handlers on restart
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)
	if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)

	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null


func _emit_status(msg: String) -> void:
	print("[NetworkManager] %s" % msg)
	status_changed.emit(msg)
