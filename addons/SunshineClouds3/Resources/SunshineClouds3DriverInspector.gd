@tool
extends EditorInspectorPlugin
## The driver's Cloud Lights and Cloud Effectors sections: a box per light or effector with its node and settings in
## the inspector's own property editors (the driver's cloud_lists/ fields), all undoable.

# Editor: the undo/redo manager list edits are recorded with.
var undo_redo : EditorUndoRedoManager


func _init(p_undo_redo : EditorUndoRedoManager) -> void:
	undo_redo = p_undo_redo


func _can_handle(object : Object) -> bool:
	return object is SunshineClouds3Driver


func _parse_property(object : Object, _type : Variant.Type, name : String, _hint_type : PropertyHint, _hint_string : String,
		_usage_flags : int, _wide : bool) -> bool:
	if name == "cloud_lights":
		add_custom_control(Lists.new(object, undo_redo, ["directional", "omni"]))
		return true
	if name == "cloud_effectors":
		add_custom_control(Lists.new(object, undo_redo, ["effector"]))
		return true
	return false


class Lists extends VBoxContainer:
	# Per list (the driver's LISTS): its title, what one is called, its node's class.
	const KINDS := {
		"directional": ["Directional Lights", "Directional Light", "DirectionalLight3D"],
		"omni": ["Omni Lights", "Omni Light", "OmniLight3D"],
		"effector": ["Effectors", "Effector", "Node3D"],
	}

	# Context: the driver being edited, the undo/redo manager, and the editor's display scale.
	var driver : SunshineClouds3Driver
	var undo_redo : EditorUndoRedoManager
	var editor_scale := EditorInterface.get_editor_scale()

	func _init(p_driver : SunshineClouds3Driver, p_undo_redo : EditorUndoRedoManager, lists : Array) -> void:
		driver = p_driver
		undo_redo = p_undo_redo
		add_theme_constant_override(&"separation", roundi(6.0 * editor_scale))
		for i in lists.size():
			if i > 0:
				_add_spacer(6.0)
			# A section with one list needs no title of its own.
			_add_list(lists[i], lists.size() > 1)

	func _add_spacer(height : float) -> void:
		var spacer := Control.new()
		spacer.custom_minimum_size.y = height * editor_scale
		add_child(spacer)

	func _add_list(list : String, titled : bool) -> void:
		if titled:
			var title := Label.new()
			title.text = KINDS[list][0]
			title.theme_type_variation = &"HeaderSmall"
			add_child(title)
		for i in driver.get(SunshineClouds3Driver.LISTS[list][0]).size():
			add_child(_box(list, i))
		_add_spacer(6.0)
		var add := Button.new()
		add.text = "Add %s" % KINDS[list][1]
		add.icon = EditorInterface.get_editor_theme().get_icon(&"Add", &"EditorIcons")
		add.pressed.connect(_add.bind(list))
		add_child(add)

	# One entry's box: node and remove button on top, then its settings.
	func _box(list : String, index : int) -> Control:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		style.border_color = Color.WHITE
		style.set_border_width_all(maxi(roundi(editor_scale), 1))
		style.set_corner_radius_all(roundi(4.0 * editor_scale))
		style.set_content_margin_all(6.0 * editor_scale)
		var box := PanelContainer.new()
		box.add_theme_stylebox_override(&"panel", style)
		var column := VBoxContainer.new()
		column.add_theme_constant_override(&"separation", roundi(4.0 * editor_scale))
		box.add_child(column)

		var prefix := "cloud_lists/%s/%d/" % [list, index]
		var top := HBoxContainer.new()
		var node := _editor(prefix + "node", TYPE_OBJECT, PROPERTY_HINT_NODE_TYPE, KINDS[list][2], KINDS[list][1])
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top.add_child(node)
		var remove := Button.new()
		remove.flat = true
		remove.icon = EditorInterface.get_editor_theme().get_icon(&"Remove", &"EditorIcons")
		remove.tooltip_text = "Remove this %s from the clouds." % KINDS[list][1].to_lower()
		remove.custom_minimum_size.x = 28.0 * editor_scale
		remove.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		remove.pressed.connect(_remove.bind(list, index))
		top.add_child(remove)
		column.add_child(top)

		var picked : Object = driver.get(prefix + "node")
		var own_settings := "SunshineEffector" if list == "effector" && picked is SunshineEffector \
			else "SunshineOmniLight" if list == "omni" && picked is SunshineOmniLight else ""
		if own_settings:
			var note := Label.new()
			note.text = "Settings come from the %s itself." % own_settings
			note.theme_type_variation = &"HeaderSmall"
			note.add_theme_color_override(&"font_color", EditorInterface.get_editor_theme().get_color(&"font_disabled_color", &"Editor"))
			column.add_child(_padded_control(note))
		elif list == "effector":
			column.add_child(_padded(_editor(prefix + "radius", TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,100000,1,or_greater,suffix:m", "Radius",
				"How far it reaches, times the effector's largest scale.")))
			column.add_child(_padded(_editor(prefix + "strength", TYPE_FLOAT, PROPERTY_HINT_RANGE, "-1,1,0.01,or_greater,or_less", "Strength",
				"Coverage added at its centre: 1 fills the layers, -1 clears them. Beyond either holds that out further towards the edge.")))
			column.add_child(_padded(_editor(prefix + "falloff", TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,1,0.01", "Falloff",
				"How much of the radius it fades out over, from its edge in: 0 = a hard edge, 1 = from the centre.")))
		else:
			column.add_child(_padded(_editor(prefix + "energy_multiplier", TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,16,0.01,or_greater", "Energy Multiplier",
				"Scales this light's energy on the clouds only. The light's effect on the world is unchanged.")))
			if list == "directional":
				column.add_child(_padded(_editor(prefix + "color", TYPE_COLOR, PROPERTY_HINT_COLOR_NO_ALPHA, "", "Color",
					"The colour the clouds are lit with, in place of the light's own.")))
				column.add_child(_padded(_editor(prefix + "cast_cloud_shadows", TYPE_BOOL, PROPERTY_HINT_NONE, "", "Cast Cloud Shadows",
					"Whether this light can cast the cloud shadows (the strongest one that can does).")))
				column.add_child(_padded(_editor(prefix + "drive_light_color", TYPE_BOOL, PROPERTY_HINT_NONE, "", "Drive Light Color",
					"Sets the light's own colour to what's left of it after the atmosphere, times Color.")))
			column.add_child(_padded(_editor(prefix + "shadow_samples", TYPE_INT, PROPERTY_HINT_RANGE, "0,16,1", "Shadow Samples",
				"Samples through the clouds towards the light per cloud sample. 0 = none (lit through).")))
		var settings : Array = driver.get(SunshineClouds3Driver.LISTS[list][1])
		if index < settings.size() && settings[index]:
			# Deferred: the colour editor resets the colour before reporting the pick; an immediate refresh would lose it.
			settings[index].changed.connect(_refresh.bind(column), CONNECT_DEFERRED)
		return box

	# Pads an option's editor to the node editor's width so the columns line up.
	func _padded(editor : EditorProperty) -> Control:
		return _padded_control(editor)

	func _padded_control(control : Control) -> Control:
		var row := HBoxContainer.new()
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(control)
		var gap := Control.new()
		gap.custom_minimum_size.x = 28.0 * editor_scale
		row.add_child(gap)
		return row

	func _editor(property : String, type : Variant.Type, hint : PropertyHint, hint_text : String, label : String, tooltip : String = "") -> EditorProperty:
		var editor := EditorInspector.instantiate_property_editor(driver, type, property, hint, hint_text, PROPERTY_USAGE_EDITOR)
		editor.set_object_and_property(driver, property)
		editor.label = label
		editor.tooltip_text = tooltip
		editor.update_property()
		editor.property_changed.connect(_property_changed.bind(label, editor))
		return editor

	# Undo and redo change the settings behind the editors' backs.
	func _refresh(column : Control) -> void:
		for editor : EditorProperty in column.find_children("*", "EditorProperty", true, false):
			editor.update_property()

	# One undo step per change. The colour editor previews a drag itself and resets it before reporting the pick,
	# so old_value is the pre-drag one.
	func _property_changed(property : StringName, value : Variant, _field : StringName, _changing : bool, label : String, editor : EditorProperty) -> void:
		var old_value : Variant = driver.get(property)
		if old_value != value:
			var kind : String = KINDS[String(property).get_slice("/", 1)][1]
			undo_redo.create_action("Set Cloud %s %s" % [kind, label], UndoRedo.MERGE_DISABLE, driver)
			undo_redo.add_do_property(driver, property, value)
			undo_redo.add_undo_property(driver, property, old_value)
			undo_redo.commit_action()
		editor.update_property()

	func _add(list : String) -> void:
		var nodes : Array = driver.get(SunshineClouds3Driver.LISTS[list][0]).duplicate()
		var settings : Array = driver.get(SunshineClouds3Driver.LISTS[list][1]).duplicate()
		nodes.append(NodePath())
		match list:
			"directional":
				settings.append(CloudDirectionalLightSettings.new())
			"omni":
				settings.append(CloudOmniLightSettings.new())
			_:
				settings.append(CloudEffectorSettings.new())
		_set_lists("Add Cloud %s" % KINDS[list][1], list, nodes, settings)

	func _remove(list : String, index : int) -> void:
		var nodes : Array = driver.get(SunshineClouds3Driver.LISTS[list][0]).duplicate()
		var settings : Array = driver.get(SunshineClouds3Driver.LISTS[list][1]).duplicate()
		nodes.remove_at(index)
		if index < settings.size():
			settings.remove_at(index)
		_set_lists("Remove Cloud %s" % KINDS[list][1], list, nodes, settings)

	func _set_lists(action : String, list : String, nodes : Array, settings : Array) -> void:
		var nodes_property : StringName = SunshineClouds3Driver.LISTS[list][0]
		var settings_property : StringName = SunshineClouds3Driver.LISTS[list][1]
		undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, driver)
		undo_redo.add_do_property(driver, nodes_property, nodes)
		undo_redo.add_do_property(driver, settings_property, settings)
		undo_redo.add_undo_property(driver, nodes_property, driver.get(nodes_property).duplicate())
		undo_redo.add_undo_property(driver, settings_property, driver.get(settings_property).duplicate())
		undo_redo.commit_action()
