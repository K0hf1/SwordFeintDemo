# attack_data.gd
# Resource defining frame data for one attack. Create as .tres files.
#
# RPS SYSTEM:
#   is_armored = true  → this attack CRUSHES incoming light attacks.
#                        Set true on all heavy attacks.
#                        When an armored attack collides with a light attack,
#                        the light attack's hitbox is ignored and the heavy lands.
#   attack_type        → "light" or "heavy". Stored in ComboTracker chain and
#                        in HitData so receivers can resolve RPS interactions.
#
# At 60Hz: 1 tick ≈ 16.67ms
#
class_name AttackData
extends Resource

# ── Identity ──────────────────────────────────────────────────────────────────
@export var attack_id: String   = "sword_light"
@export var weapon_id: String   = "sword"       # must match weapon's weapon_id
@export var attack_type: String = "light"       # "light" or "heavy"

# ── Frame windows (physics ticks at 60Hz) ────────────────────────────────────
@export var startup_frames: int  = 4
@export var active_frames: int   = 5
@export var recovery_frames: int = 8

# ── Damage & Knockback ────────────────────────────────────────────────────────
# Damage is FLAT — never modified by combo state or chain position.
@export var damage: float              = 10.0
@export var knockback_force: float     = 220.0
@export var knockback_angle_deg: float = 35.0   # 0°=horizontal  90°=straight up

# ── Hit response ──────────────────────────────────────────────────────────────
@export var hitstun_frames: int = 12

# ── RPS flags ─────────────────────────────────────────────────────────────────
# is_armored: true on all heavy attacks. Causes this attack to CRUSH light attacks
# that hit it during ACTIVE frames. The light attacker takes no credit; the heavy
# still lands. Any heavy attack crushes any light attack — weapon type is irrelevant.
@export var is_armored: bool = false

# ── Derived tick markers (NOT exported — set by compute_ticks()) ──────────────
var startup_end_tick: int  = 0
var active_end_tick: int   = 0
var recovery_end_tick: int = 0

func compute_ticks(tick_now: int) -> void:
	startup_end_tick  = tick_now + startup_frames
	active_end_tick   = startup_end_tick + active_frames
	recovery_end_tick = active_end_tick + recovery_frames
