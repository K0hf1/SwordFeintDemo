# attack_data.gd
# A Resource that defines the frame data for one attack.
# Create instances as .tres files in your project so designers can tune values
# without touching code.
#
# File → New Resource → AttackData → save as res://combat/attacks/sword_light.tres
#
# At 60Hz physics:
#   4 startup frames  = ~67ms  (windup)
#   5 active frames   = ~83ms  (hitbox live)
#   8 recovery frames = ~133ms (cooldown)
#
# COMBO DESIGN NOTE:
#   Damage is ALWAYS flat — it never changes based on combo position.
#   The combo chain is a hit-confirmed record used for ultimate generation only.
#   attack_type identifies this attack's contribution to the chain ("light" or "heavy").
#   weapon_id ties this attack to a specific weapon — combo chains are per-weapon.
#
class_name AttackData
extends Resource

# ── Identity ─────────────────────────────────────────────────────────────────
@export var attack_id: String = "sword_light"
# Which weapon owns this attack. Used by ComboTracker to scope chains correctly.
# Must match the weapon's weapon_id (e.g. "sword", "bow").
@export var weapon_id: String = "sword"
# The type label stored in the combo chain array when this attack CONFIRMS a hit.
# Use "light" or "heavy". Keep lowercase — ComboTracker compares these strings.
@export var attack_type: String = "light"

# ── Frame windows (in physics ticks at 60Hz) ─────────────────────────────────
@export var startup_frames: int  = 4   # ticks before hitbox activates
@export var active_frames: int   = 5   # ticks hitbox is live
@export var recovery_frames: int = 8   # ticks before IDLE resumes

# ── Damage & Knockback ────────────────────────────────────────────────────────
# Damage is FLAT. It is never modified by combo count or chain position.
@export var damage: float = 10.0
@export var knockback_force: float = 220.0
# Angle in degrees: 0° = horizontal push, 45° = upward arc, 90° = straight up.
@export var knockback_angle_deg: float = 35.0

# ── Hit response ──────────────────────────────────────────────────────────────
@export var hitstun_frames: int = 12

# ── Derived tick markers ──────────────────────────────────────────────────────
# NOT @export — computed by CombatController._begin_attack() at attack start.
var startup_end_tick: int  = 0
var active_end_tick: int   = 0
var recovery_end_tick: int = 0

func compute_ticks(tick_now: int) -> void:
	startup_end_tick  = tick_now + startup_frames
	active_end_tick   = startup_end_tick + active_frames
	recovery_end_tick = active_end_tick + recovery_frames
