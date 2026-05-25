# hurtbox.gd  (REFACTORED)
# Hurtbox is a passive receiver. It no longer has _on_hit_received() called directly.
# Instead, it exposes a signal that the parent (Player, Dummy, Enemy) connects to.
#
# Who emits hit_received?
#   CombatController._query_hits() — the attacker's controller emits on the
#   TARGET's hurtbox. The target's parent connects to this signal to respond.
#
# Who connects?
#   dummy.gd: $Hurtbox.hit_received.connect(_on_hit_received)
#   player.gd (if player can be hit): $Hurtbox.hit_received.connect(_on_hit_received)
#
extends Area2D
class_name Hurtbox

# Emitted by the attacker's CombatController when a hit is confirmed.
# hit_data: HitData — contains damage, knockback, hitstun_frames, attacker ref
signal hit_received(hit_data: HitData)


func _ready() -> void:
	monitoring  = false   # hurtbox doesn't need to detect others
	monitorable = true    # attackers' hitboxes need to detect us
	add_to_group("hurtbox")
