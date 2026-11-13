@tool
extends EditorNode3DGizmoPlugin
## Draws SunshineEffector and SunshineOmniLight reach on the clouds: three circles and a radius handle, with undo.
## - SunshineEffector: radius times its largest scale, handle on X; blue adds, red clears, fainter where falloff starts.
## - SunshineOmniLight: cloud_radius, handle on Y (Godot's own gizmo has omni_range on X), warm yellow to stand apart.

const SEGMENTS := 64

# Editor: the undo/redo manager handle drags are recorded with.
var undo_redo : EditorUndoRedoManager


func _init(p_undo_redo : EditorUndoRedoManager) -> void:
	undo_redo = p_undo_redo
	create_material("adding", Color(0.55, 0.8, 1.0))
	create_material("adding_falloff", Color(0.55, 0.8, 1.0, 0.3))
	create_material("clearing", Color(1.0, 0.5, 0.4))
	create_material("clearing_falloff", Color(1.0, 0.5, 0.4, 0.3))
	create_material("cloud_light", Color(1.0, 0.85, 0.4))
	create_handle_material("handles")


func _get_gizmo_name() -> String:
	return "SunshineClouds3"


func _has_gizmo(node : Node3D) -> bool:
	return node is SunshineEffector || node is SunshineOmniLight


func _redraw(gizmo : EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	var scale := _radius_scale(node)
	if scale <= 0.0:
		return
	var radius : float = node.get(_radius_property(node)) * scale
	var effector := node as SunshineEffector
	if effector != null:
		var kind := "adding" if effector.strength >= 0.0 else "clearing"
		gizmo.add_lines(_sphere_lines(node, radius), get_material(kind, gizmo))
		if effector.falloff > 0.0 && effector.falloff < 1.0:
			gizmo.add_lines(_sphere_lines(node, radius * (1.0 - effector.falloff)), get_material(kind + "_falloff", gizmo))
	else:
		gizmo.add_lines(_sphere_lines(node, radius), get_material("cloud_light", gizmo))
	gizmo.add_handles(PackedVector3Array([_to_local(node, _handle_axis(node) * radius)]), get_material("handles", gizmo), PackedInt32Array())


func _get_handle_name(gizmo : EditorNode3DGizmo, _handle_id : int, _secondary : bool) -> String:
	return "Cloud Radius" if gizmo.get_node_3d() is SunshineOmniLight else "Radius"


func _get_handle_value(gizmo : EditorNode3DGizmo, _handle_id : int, _secondary : bool) -> Variant:
	var node := gizmo.get_node_3d()
	return node.get(_radius_property(node))


# The radius where the camera ray passes closest to the handle's axis.
func _set_handle(gizmo : EditorNode3DGizmo, _handle_id : int, _secondary : bool, camera : Camera3D, screen_pos : Vector2) -> void:
	var node := gizmo.get_node_3d()
	var scale := _radius_scale(node)
	if scale <= 0.0:
		return
	var centre := node.global_position
	var axis := _handle_axis(node)
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_end := ray_origin + camera.project_ray_normal(screen_pos) * 1e7
	var closest := Geometry3D.get_closest_points_between_segments(centre - axis * 1e7, centre + axis * 1e7, ray_origin, ray_end)
	node.set(_radius_property(node), maxf((closest[0] - centre).dot(axis), 0.0) / scale)


func _commit_handle(gizmo : EditorNode3DGizmo, _handle_id : int, _secondary : bool, restore : Variant, cancel : bool) -> void:
	var node := gizmo.get_node_3d()
	var property := _radius_property(node)
	if cancel:
		node.set(property, restore)
		return
	undo_redo.create_action("Change Cloud Radius" if node is SunshineOmniLight else "Change Effector Radius")
	undo_redo.add_do_property(node, property, node.get(property))
	undo_redo.add_undo_property(node, property, restore)
	undo_redo.commit_action()


func _radius_property(node : Node3D) -> StringName:
	return &"cloud_radius" if node is SunshineOmniLight else &"radius"


# Effectors scale their radius by their largest scale; lights ignore scale, as Godot's own range does.
func _radius_scale(node : Node3D) -> float:
	if node is SunshineOmniLight:
		return 1.0
	var scale := node.global_transform.basis.get_scale().abs()
	return maxf(scale.x, maxf(scale.y, scale.z))


func _handle_axis(node : Node3D) -> Vector3:
	var basis := node.global_transform.basis
	return (basis.y if node is SunshineOmniLight else basis.x).normalized()


# Three circles of radius (world units) in the node's axis planes, as local-space segments unscaled so they stay round.
func _sphere_lines(node : Node3D, radius : float) -> PackedVector3Array:
	var basis := node.global_transform.basis.orthonormalized()
	var planes := [[basis.x, basis.y], [basis.y, basis.z], [basis.z, basis.x]]
	var lines := PackedVector3Array()
	for plane : Array in planes:
		var previous := _to_local(node, plane[0] * radius)
		for i in range(1, SEGMENTS + 1):
			var angle := TAU * i / SEGMENTS
			var point := _to_local(node, (plane[0] * cos(angle) + plane[1] * sin(angle)) * radius)
			lines.append(previous)
			lines.append(point)
			previous = point
	return lines


# A world space offset from the node in its local space.
func _to_local(node : Node3D, offset : Vector3) -> Vector3:
	return node.global_transform.basis.inverse() * offset
