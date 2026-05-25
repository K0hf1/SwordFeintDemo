# input_profile.gd
# Plain data class — holds all the action/key names for ONE player's input mapping.
# NOT a Node. Instantiated by whoever sets up the player (ArenaTest, lobby, etc.).
#
# Two factory constructors are provided for local play:
#   InputProfile.for_player_a()   → WASD / Mouse / C / LShift / Tab / R
#   InputProfile.for_player_b()   → Arrows / Numpad
#
# For future network players, the host builds a RemoteInputProvider and never
# needs an InputProfile at all — the snapshot arrives over the wire.
#
# Adding a new weapon or action:
#   1. Add a field here (e.g. var block_action: String)
#   2. Read it in LocalInputProvider.build_snapshot()
#   3. Add the field to InputSnapshot
#
class_name InputProfile

# ── Movement ──────────────────────────────────────────────────────────────────
# Set to "" to use raw key scanning instead (see LocalInputProvider)
var move_up_action:    String = ""
var move_down_action:  String = ""
var move_left_action:  String = ""
var move_right_action: String = ""

# Raw key fallback — used when action strings are empty.
# Ignored when the corresponding action string is non-empty.
var key_up:    Key = KEY_W
var key_down:  Key = KEY_S
var key_left:  Key = KEY_A
var key_right: Key = KEY_D

# ── Combat actions (just_pressed) ─────────────────────────────────────────────
var light_attack_action:  String = "light_attack"
var heavy_attack_action:  String = "heavy_attack"
var dash_action:          String = "dash"
var parry_action:         String = "parry"
var weapon_switch_action: String = "weapon_switch"
var ultimate_action:      String = "ultimate"

# ── Held actions ──────────────────────────────────────────────────────────────
var guard_action: String = "guard"

# ── Aim ───────────────────────────────────────────────────────────────────────
# "mouse" = aim toward mouse cursor (Player A style)
# "right_stick" = future gamepad support
# "fixed" = always aim in last movement direction (Player B default for now)
var aim_mode: String = "mouse"


# ── Factory: Player A ─────────────────────────────────────────────────────────
# Uses all existing InputMap actions — nothing in player.gd needs to change.
static func for_player_a() -> InputProfile:
	var p := InputProfile.new()
	p.move_up_action    = ""        # use raw keys
	p.move_down_action  = ""
	p.move_left_action  = ""
	p.move_right_action = ""
	p.key_up    = KEY_W
	p.key_down  = KEY_S
	p.key_left  = KEY_A
	p.key_right = KEY_D
	p.light_attack_action  = "light_attack"
	p.heavy_attack_action  = "heavy_attack"
	p.dash_action          = "dash"
	p.guard_action         = "guard"
	p.parry_action         = "parry"
	p.weapon_switch_action = "weapon_switch"
	p.ultimate_action      = "ultimate"
	p.aim_mode = "mouse"
	return p


# ── Factory: Player B ─────────────────────────────────────────────────────────
# Arrow keys for movement. Numpad for actions.
# No attacks yet — light/heavy actions point to non-existent actions
# so is_action_just_pressed returns false safely.
# aim_mode = "fixed" — always faces last movement direction.
static func for_player_b() -> InputProfile:
	var p := InputProfile.new()
	p.move_up_action    = ""
	p.move_down_action  = ""
	p.move_left_action  = ""
	p.move_right_action = ""
	p.key_up    = KEY_UP
	p.key_down  = KEY_DOWN
	p.key_left  = KEY_LEFT
	p.key_right = KEY_RIGHT
	p.light_attack_action  = ""           # no attacks for B yet
	p.heavy_attack_action  = ""
	p.dash_action          = "p2_dash"    # registered in ArenaTest or Project Settings
	p.guard_action         = "p2_guard"
	p.parry_action         = "p2_parry"
	p.weapon_switch_action = ""
	p.ultimate_action      = ""
	p.aim_mode = "fixed"
	return p
