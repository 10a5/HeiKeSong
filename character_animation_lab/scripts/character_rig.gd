@tool
extends Node3D
## Shared import correction for the copied FBX rig.
## Keeping this in a separate scene lets the editor and the game reference the
## same CharacterRig.tscn without touching the original project's player.gd.

@export var model_height := 1.8

func _ready() -> void:
	_apply_import_transform()

func _apply_import_transform() -> void:
	var character := get_node_or_null("Character") as Node3D
	if character == null:
		return
	character.scale = Vector3.ONE * model_height
	var armature := character.get_node_or_null("Armature") as Node3D
	if armature:
		# The imported FBX uses the same coordinate conversion as the main game.
		armature.rotation.x = -PI * 0.5
