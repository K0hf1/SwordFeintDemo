# input_snapshot.gd
# Plain data class — one tick of player input. NOT a Node.
# Serializable for future network transmission.
#
# Input Map actions required (Project Settings → Input Map):
#   "light_attack"   → Left Mouse Button
#   "heavy_attack"   → Right Mouse Button
#   "dash"           → Left Shift
#   "guard"          → Left Shift  (held — same key as dash is fine;
#                       dash is just_pressed, guard is is_action_pressed)
#   "parry"          → C
#   "weapon_switch"  → Tab
#   "ultimate"       → R
#
# NOTE on guard vs dash: both use Shift. Dash fires on the frame Shift is first
# pressed (just_pressed). Guard is true on every frame Shift is held. The two
# can coexist because dash fires once and guard is a held state.
#
class_name InputSnapshot

var tick: int               = 0
var move_direction: Vector2 = Vector2.ZERO
var aim_direction: Vector2  = Vector2.DOWN

var light_attack_pressed: bool  = false
var heavy_attack_pressed: bool  = false   # right mouse / separate key
var dash_pressed: bool          = false   # just_pressed — fires once on Shift down
var guard_held: bool            = false   # is_pressed — true every frame Shift held
var parry_pressed: bool         = false   # just_pressed — C key
var weapon_switch_pressed: bool = false   # just_pressed — Tab
var ultimate_pressed: bool      = false   # just_pressed — R


func serialize() -> Dictionary:
	return {
		"t":   tick,
		"mv":  [move_direction.x, move_direction.y],
		"aim": [aim_direction.x,  aim_direction.y],
		"atk": light_attack_pressed,
		"hvy": heavy_attack_pressed,
		"dsh": dash_pressed,
		"grd": guard_held,
		"pry": parry_pressed,
		"wsw": weapon_switch_pressed,
		"ult": ultimate_pressed,
	}

static func deserialize(d: Dictionary) -> InputSnapshot:
	var s := InputSnapshot.new()
	s.tick                  = d.get("t",   0)
	s.move_direction        = Vector2(d["mv"][0],  d["mv"][1])
	s.aim_direction         = Vector2(d["aim"][0], d["aim"][1])
	s.light_attack_pressed  = d.get("atk", false)
	s.heavy_attack_pressed  = d.get("hvy", false)
	s.dash_pressed          = d.get("dsh", false)
	s.guard_held            = d.get("grd", false)
	s.parry_pressed         = d.get("pry", false)
	s.weapon_switch_pressed = d.get("wsw", false)
	s.ultimate_pressed      = d.get("ult", false)
	return 
