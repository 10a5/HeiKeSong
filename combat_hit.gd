extends RefCounted
## Shared melee geometry. Y height and world occlusion remain meaningful in 3D.


static func can_hit(attacker: Node3D, target: Node3D, direction: Vector3, reach: float, half_angle: float, vertical_reach: float) -> bool:
	if not is_instance_valid(attacker) or not is_instance_valid(target):
		return false
	var offset := target.global_position - attacker.global_position
	if absf(offset.y) > vertical_reach:
		return false
	var horizontal := Vector3(offset.x, 0.0, offset.z)
	var distance := horizontal.length()
	var target_radius: float = float(target.get("radius")) if target.get("radius") != null else 0.35
	if distance > reach + target_radius:
		return false
	var aim := Vector3(direction.x, 0.0, direction.z).normalized()
	if distance > target_radius:
		var edge_margin := asin(clampf(target_radius / distance, 0.0, 1.0))
		if aim.is_zero_approx() or aim.angle_to(horizontal) > half_angle + edge_margin:
			return false
	# World geometry occupies layer 1; player/enemy bodies use separate layers.
	var ray := PhysicsRayQueryParameters3D.create(attacker.global_position + Vector3.UP * 0.85, target.global_position + Vector3.UP * 0.85, 1)
	var exclusions: Array[RID] = []
	if attacker is CollisionObject3D:
		exclusions.append(attacker.get_rid())
	if target is CollisionObject3D:
		exclusions.append(target.get_rid())
	ray.exclude = exclusions
	return attacker.get_world_3d().direct_space_state.intersect_ray(ray).is_empty()
