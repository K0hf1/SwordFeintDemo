# game_clock.gd
# Authoritative shared tick clock. Register as an Autoload named "GameClock".
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
# In the original code, player.gd incremented its own `_tick` and
# combat_controller.gd incremented its own `tick_counter` independently.
# On two separate machines those counters diverge immediately — PlayerA's
# tick 158 and PlayerB's tick 158 represent different real-world moments.
# Frame data (startup_end_tick, active_end_tick, recovery_end_tick) was
# computed as local_tick + startup_frames, making those absolute values
# meaningless to the remote peer.
#
# GameClock is a single Node that advances once per _physics_process call.
# Both Player and CombatController read GameClock.tick instead of keeping
# their own counters. Because Godot's scene tree calls _physics_process in
# deterministic order, every node on the same machine reads the same value
# within a single frame.
#
# ── MULTIPLAYER AUTHORITY PATH ────────────────────────────────────────────────
# For peer-to-peer / client-server play, the HOST calls
# GameClock.set_tick(value) via RPC at the start of each lockstep frame.
# Clients do NOT advance their own clock; they wait for the host tick.
#
#   Host side (called once per physics frame):
#       rpc("set_tick", GameClock.tick + 1)
#
#   Client side (receives RPC):
#       @rpc("authority", "reliable") func set_tick(t: int) -> void:
#           tick = t
#           tick_advanced.emit(tick)
#
# For local play no setup is needed — the clock advances automatically
# via _physics_process and both players on the same machine share it.
#
# ── ROLLBACK NOTE ─────────────────────────────────────────────────────────────
# For a full rollback-netcode implementation, save/restore GameClock.tick
# alongside the rest of game state when rolling back. The clock is just an
# integer — cheap to snapshot.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   # In any node — no @onready needed, autoload is always available:
#   var t: int = GameClock.tick
#
#   # Subscribe to each tick advance (optional):
#   GameClock.tick_advanced.connect(_on_tick)
#
extends Node

# The current authoritative physics tick. Read-only for all game systems.
# Only GameClock._physics_process (local) or set_tick() (network host) writes this.
var tick: int = 0

# Emitted after tick is incremented. Systems that need to react to each new
# tick can connect here instead of polling in their own _physics_process.
signal tick_advanced(new_tick: int)


func _ready() -> void:
	# Process before players so CombatController always reads the already-
	# incremented value for the current frame.
	process_priority = -10


func _physics_process(_delta: float) -> void:
	# Local play / host: advance the clock ourselves each physics frame.
	# Then broadcast the new value to all clients so their clocks stay in sync.
	# Clients do NOT self-advance (see _is_network_client()); they receive the
	# authoritative value via the set_tick() RPC below.
	if not _is_network_client():
		_advance()
		# Broadcast to clients when a real network peer is active.
		# set_tick uses "call_remote" so the host does NOT double-increment itself.
		var mp := get_tree().get_multiplayer()
		if mp != null and mp.multiplayer_peer != null \
				and not (mp.multiplayer_peer is OfflineMultiplayerPeer):
			rpc("set_tick", tick)


# ── Network host entry point ──────────────────────────────────────────────────
# The host calls this (via RPC on clients) to synchronise the clock.
# On the host itself, _physics_process already calls _advance(); do NOT call
# set_tick() locally or the tick will double-increment.
@rpc("authority", "call_remote", "reliable")
func set_tick(t: int) -> void:
	tick = t
	tick_advanced.emit(tick)


# ── Internal ──────────────────────────────────────────────────────────────────
func _advance() -> void:
	tick += 1
	tick_advanced.emit(tick)


# Returns true when running as a non-authority network peer.
# In local play (no active multiplayer peer) this is always false.
func _is_network_client() -> bool:
	var mp := get_tree().get_multiplayer()
	if mp == null:
		return false
	# multiplayer_peer is null until a peer is created; unique_id == 1 is host.
	if mp.multiplayer_peer == null:
		return false
	return mp.get_unique_id() != 1
