# input_buffer.gd
# Kept as a thin node in the Player scene for two purposes:
#
#   1. NETWORKING PATH (future): RemoteInputProvider calls receive_snapshot()
#      to inject a deserialized snapshot from the network, which the host
#      then feeds into Player.tick() on the next physics frame.
#
#   2. ROLLBACK PATH (future): a ring buffer of past snapshots can live here
#      for re-simulation without touching Player.gd.
#
# LOCAL PLAY: this node is idle. LocalInputProvider builds the snapshot
# directly and Player.gd receives it in _physics_process. capture_tick()
# is no longer called in local mode.
#
# Attach to: Player → InputBuffer (Node)
#
extends Node

# Last received snapshot — read by RemoteInputProvider.build_snapshot()
var current: InputSnapshot = InputSnapshot.new()


# ── Networking path ───────────────────────────────────────────────────────────
# Called by the network layer when a serialized snapshot arrives.
# The RemoteInputProvider then reads `current` to serve it to Player.tick().
func receive_snapshot(data: Dictionary) -> void:
	current = InputSnapshot.deserialize(data)


# ── Future rollback buffer ────────────────────────────────────────────────────
# Uncomment and expand when rollback is introduced:
#
# const BUFFER_SIZE := 8
# var _history: Array[InputSnapshot] = []
#
# func push(snap: InputSnapshot) -> void:
# 	_history.push_front(snap)
# 	if _history.size() > BUFFER_SIZE:
# 		_history.pop_back()
#
# func get_at(tick: int) -> InputSnapshot:
# 	for s in _history:
# 		if s.tick == tick:
# 			return s
# 	return InputSnapshot.new()
