extends Node2D

@onready var anim = $Body

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	anim.play("dummy_idle")


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
