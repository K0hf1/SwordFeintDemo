extends Area2D

func _ready():
	print("Hurtbox ready")
	area_entered.connect(_on_area_entered)

func _on_area_entered(area):
	if area.is_in_group("player_attack"):
		print("Dummy hit!")
