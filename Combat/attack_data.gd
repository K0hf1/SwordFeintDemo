# attack_data.gd
# A Resource (not a Node) that defines the frame data for one attack.
# Create instances as .tres files in your project so designers can tune values
# without touching code.
#
# File → New Resource → AttackData → save as res://combat/attacks/light.tres
# Then set @export vars in the Inspector.
#
# At 60Hz physics:
#   4 startup frames  = ~67ms  (windup)
#   5 active frames   = ~83ms  (hitbox live)
#   8 recovery frames = ~133ms (cooldown)
#
class_name AttackData
extends Resource

@export var attack_id: String = "light"

# ── Frame windows (in physics ticks at 60Hz) ────────────────────────────────
@export var startup_frames: int  = 4   # ticks before hitbox activates
@export var active_frames: int   = 5   # ticks hitbox is live
@export var recovery_frames: int = 8   # ticks before IDLE resumes

# ── Damage & Knockback ───────────────────────────────────────────────────────
@export var damage: float = 10.0
@export var knockback_force: float = 220.0
# Angle is in degrees, relative to attacker → target direction.
# 0° = horizontal push directly away, 45° = 45° upward arc, 90° = straight up.
@export var knockback_angle_deg: float = 35.0

# ── Hit response ────────────────────────────────────────────────────────────
@export var hitstun_frames: int = 12  # how long target stays in HITSTUN

# ── Combo chain ─────────────────────────────────────────────────────────────
# If non-empty, this attack can be cancelled into the named attack during
# the combo window at the end of recovery.
@export var combo_followup_id: String = "light2"
# How many frames before recovery_end the combo input window opens.
@export var combo_window_frames: int = 5

# ── Derived tick markers ─────────────────────────────────────────────────────
# These are NOT @export — they are computed by CombatController._begin_attack()
# based on the tick when the attack starts. They live here for convenience.
var startup_end_tick: int  = 0
var active_end_tick: int   = 0
var recovery_end_tick: int = 0

func compute_ticks(tick_now: int) -> void:
	startup_end_tick  = tick_now + startup_frames
	active_end_tick   = startup_end_tick + active_frames
	recovery_end_tick = active_end_tick + recovery_frames
