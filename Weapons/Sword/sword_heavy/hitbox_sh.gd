# hitbox_sh.gd
# HitboxSH — passive sensor for the Sword's Heavy (stab) attack.
# Identical contract to HitboxSL. CombatController controls monitoring.
# This node has no logic — it is a pure shape + group membership.
#
# Scene location:
#   Sword / HeavyAttack / HitboxSH   ← this script
#
extends Area2D


func _ready() -> void:
	monitoring  = false   # CombatController activates during ACTIVE frames
	monitorable = true    # enemy hurtboxes can detect this if needed
