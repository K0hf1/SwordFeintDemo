# player_hurtbox.gd
# Attach to: Player → Hurtbox (Area2D)
#
# Player-side hurtbox. Mirrors the structure of hurtbox.gd (used on enemies/dummy)
# but belongs to the "player_hurtbox" group so enemy hitboxes never self-detect,
# and player hitboxes (in "enemy_hurtbox" queries) never hit their own Hurtbox.
#
# Who emits hit_received?
#   CombatController._reflect_damage() via parry.gd — attacker_hurtbox.hit_received.emit(reflected)
#   Any future enemy CombatController that mirrors the player's _query_hits() flow.
#
# Who connects?
#   CombatController._ready() — routes incoming hits through RPS resolver (_on_hit_incoming).
#   PlayerHealth._ready()     — applies effective damage to HP after RPS resolution.
#
# Scene placement:
#   Player (CharacterBody2D)
#     └── Hurtbox (Area2D)  ← this script
#           └── CollisionShape2D
#
extends Area2D
class_name PlayerHurtbox

# Emitted by any attacker's CombatController (or parry reflect) when a hit lands.
# hit_data carries damage, knockback, hitstun_frames, attacker ref, and RPS flags.
signal hit_received(hit_data: HitData)


func _ready() -> void:
	monitoring  = false   # player hurtbox does not detect others
	monitorable = true    # enemy hitboxes need to overlap us
	add_to_group("hurtbox")
