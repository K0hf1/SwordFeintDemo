# input_snapshot.gd
# A plain data class representing one tick of player input.
# This is NOT a Node — instantiate it with InputSnapshot.new().
# It can be serialized to a Dictionary for network transmission.
#
# Usage:
#   var snap = InputSnapshot.new()
#   snap.tick = current_tick
#   snap.move_direction = Vector2(...)
#
class_name InputSnapshot

var tick: int = 0
var move_direction: Vector2 = Vector2.ZERO
var aim_direction: Vector2 = Vector2.DOWN   # direction to mouse / analog aim
var light_attack_pressed: bool = false
var dash_pressed: bool = false

# ---------------------------------------------------------------------------
# Networking helpers (implement when adding listen-server multiplayer)
# ---------------------------------------------------------------------------

func serialize() -> Dictionary:
	return {
		"t":   tick,
		"mv":  [move_direction.x, move_direction.y],
		"aim": [aim_direction.x, aim_direction.y],
		"atk": light_attack_pressed,
		"dsh": dash_pressed,
	}

static func deserialize(d: Dictionary) -> InputSnapshot:
	var s := InputSnapshot.new()
	s.tick            = d.get("t", 0)
	s.move_direction  = Vector2(d["mv"][0],  d["mv"][1])
	s.aim_direction   = Vector2(d["aim"][0], d["aim"][1])
	s.light_attack_pressed = d.get("atk", false)
	s.dash_pressed         = d.get("dsh", false)
	return s
