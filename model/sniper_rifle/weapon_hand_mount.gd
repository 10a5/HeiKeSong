@tool
extends Node3D
## Locks a held weapon to a character's hand bone.
##
## Runs in the editor as well (`@tool`) so the weapon is visible in the hand
## while the AnimationPlayer is scrubbed — otherwise an inspector-opened scene
## shows the rifle parked at the scene origin, which reads as a broken mount.
##
## An imported character normally ships no weapon socket — the hand bone is the
## only anchor there is.  This node re-derives its own global transform from
## that bone every frame, so the weapon rides along with whatever clip is
## playing and **no animation needs a single gun track**.  Swapping the weapon,
## or pointing the same rig at a different rifle, is a scene edit rather than a
## re-export.
##
## [member mount] is the weapon's placement expressed in the hand bone's own
## space.  Set it once (the shipped scene already has it solved) and the weapon
## stays in the hand through every clip.  Put the weapon's own scale on the
## weapon child node and keep [member mount] rotation-only, so the mount reads
## as a pure orientation in the inspector.
##
##     Character                 imported rig, animations play on it
##     WeaponMount               this script, points at the hand bone
##         Weapon                the weapon mesh, scaled

## Node that owns the Skeleton3D.  Resolved lazily: an imported scene builds its
## skeleton during its own `_ready`, which may run after ours.
@export var character_path: NodePath
## Bone the weapon is parented to.  Mixamo rigs use `mixamorig_RightHand`;
## Godot imports the `:` as `_`, hence the underscore.
@export var hand_bone: StringName = &"mixamorig_RightHand"
## Weapon placement in hand-bone space (rotation and offset, no scale).
@export var mount := Transform3D.IDENTITY
## Stop re-parenting every frame — useful when a script wants to place the
## weapon itself, e.g. for a holster or a reload animation.
@export var follow := true

var _skeleton: Skeleton3D
var _bone := -1


func _ready() -> void:
	_resolve()


func _process(_delta: float) -> void:
	if not follow:
		return
	if _skeleton == null or _bone < 0:
		_resolve()
		if _skeleton == null:
			return
	# Skin poses live in skeleton space, so the skeleton's own transform has to
	# be composed in before the result can be written as a global transform.
	global_transform = _skeleton.global_transform \
		* _skeleton.get_bone_global_pose(_bone) * mount


## True once the weapon is actually parented to the hand bone.
func is_mounted() -> bool:
	return _skeleton != null and _bone >= 0


## World position of the weapon in the hand, for aiming or hit-scan origins.
func muzzle_hint(local_muzzle: Vector3) -> Vector3:
	return global_transform * local_muzzle


func _resolve() -> void:
	var host := get_node_or_null(character_path)
	if host == null:
		return
	_skeleton = _find_skeleton(host)
	if _skeleton == null:
		return
	_bone = _skeleton.find_bone(hand_bone)
	if _bone < 0:
		push_warning("WeaponMount: %s has no bone named %s" % [host.name, hand_bone])


static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null
