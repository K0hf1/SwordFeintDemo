# null_input_provider.gd
# Returns a zeroed InputSnapshot every tick. Used for remote players whose
# input has not yet arrived over the network, or for AI-controlled actors.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
# player.gd expects _input_provider.build_snapshot(...) to always return a
# valid InputSnapshot. Without a provider, the else-branch returns a blank
# snapshot anyway — but NullInputProvider makes that intent explicit and lets
# us replace it cleanly with RemoteInputProvider when input-sync RPC is added,
# without touching player.gd at all.
#
# ── FUTURE REPLACEMENT ────────────────────────────────────────────────────────
# When per-tick input RPCs are implemented:
#   1. Create RemoteInputProvider that reads from InputBuffer.current
#   2. In ArenaMultiplayer._assign_input_provider(), swap NullInputProvider
#      for RemoteInputProvider(player.get_node("InputBuffer"))
#   3. The RPC path: client sends input snapshot → host receives it →
#      host calls InputBuffer.receive_snapshot(data) → RemoteInputProvider
#      reads InputBuffer.current next tick
#
class_name NullInputProvider

func build_snapshot(tick_number: int, _player_pos: Vector2,
		_viewport: Viewport) -> InputSnapshot:
	var snap := InputSnapshot.new()
	snap.tick = tick_number
	# All booleans default false, all vectors default Vector2.ZERO —
	# player will stand idle and accept no input this tick.
	return snap
