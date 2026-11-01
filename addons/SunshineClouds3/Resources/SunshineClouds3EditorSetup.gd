@tool
extends RefCounted
## Setting the clouds up in the edited scene, editor only: the SunshineClouds3 plugin's Project >
## Tools > Add Sunshine Clouds to Scene, and SunshineEffectors and SunshineOmniLights connecting
## themselves to the driver as they're added (they load() this in the editor only, so exported games
## never do). Each change is one undo action, told in a toast.


## Called deferred from a SunshineEffector's or SunshineOmniLight's _ready in the editor (outside the
## action that added it): adds it to the scene's first driver unless a driver has it already.
static func connect_to_driver(node : Node3D) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if !is_instance_valid(node) || root == null || !(node == root || root.is_ancestor_of(node)):
		return
	var list := "omni" if node is SunshineOmniLight else "effector"
	var kind := "SunshineOmniLight" if node is SunshineOmniLight else "SunshineEffector"
	var drivers := _find_all(root, func(n : Node) -> bool: return n is SunshineClouds3Driver)
	for driver : SunshineClouds3Driver in drivers:
		if driver.get_path_to(node) in driver.get(SunshineClouds3Driver.LISTS[list][0]):
			return
	if drivers.is_empty():
		_toast("%s \"%s\" isn't on the clouds: no SunshineClouds3Driver in the scene." % [kind, node.name], EditorToaster.SEVERITY_WARNING,
			"Project > Tools > Add Sunshine Clouds to Scene adds one (and connects the scene's directional lights).")
		return
	var driver : SunshineClouds3Driver = drivers[0]
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Connect %s to Clouds" % kind, UndoRedo.MERGE_DISABLE, driver)
	_add_to_list(undo_redo, driver, list, [node])
	undo_redo.commit_action()
	_toast("Connected %s \"%s\" to %s." % [kind, node.name, driver.name])


## Project > Tools > Add Sunshine Clouds to Scene: adds what the edited scene lacks of a
## WorldEnvironment, a SunshineClouds3 effect in its compositor and a SunshineClouds3Driver driving
## it (with the WorldEnvironment as its world_environment, for the skybox), and adds the
## scene's directional lights the driver doesn't have yet to it.
static func add_to_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_toast("Open a scene to add Sunshine Clouds to.", EditorToaster.SEVERITY_WARNING)
		return

	# The WorldEnvironment with the clouds, else the first one.
	var environments := _find_all(root, func(n : Node) -> bool: return n is WorldEnvironment)
	var environment : WorldEnvironment = environments[0] if !environments.is_empty() else null
	var clouds : SunshineClouds3 = null
	for candidate : WorldEnvironment in environments:
		clouds = _clouds_of(candidate)
		if clouds:
			environment = candidate
			break

	# The driver driving them, else one driving nothing (or anything, when there are no clouds yet).
	var drivers := _find_all(root, func(n : Node) -> bool: return n is SunshineClouds3Driver)
	var driver : SunshineClouds3Driver = null
	for candidate : SunshineClouds3Driver in drivers:
		if clouds && candidate.clouds_resource == clouds:
			driver = candidate
			break
	if driver == null:
		for candidate : SunshineClouds3Driver in drivers:
			if candidate.clouds_resource == null || clouds == null:
				driver = candidate
				break

	# No clouds yet: the driver's own if it has some, else new ones.
	var add_clouds := clouds == null
	if add_clouds:
		clouds = driver.clouds_resource if driver && driver.clouds_resource else SunshineClouds3.new()

	var lights := _find_all(root, func(n : Node) -> bool: return n is DirectionalLight3D)
	if driver:
		lights = lights.filter(func(light : Node) -> bool: return !(driver.get_path_to(light) in driver.directional_lights))

	if environment && !add_clouds && driver && driver.clouds_resource == clouds && driver.world_environment == environment && lights.is_empty():
		_toast("Sunshine Clouds is already set up: %s's clouds, driven by %s." % [environment.name, driver.name])
		return

	# Short for the toast, in full for its tooltip.
	var done := PackedStringArray()
	var details := PackedStringArray()
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Add Sunshine Clouds to Scene", UndoRedo.MERGE_DISABLE, root)

	if environment == null:
		environment = WorldEnvironment.new()
		environment.name = "WorldEnvironment"
		environment.environment = _new_environment()
		environment.compositor = Compositor.new()
		environment.compositor.compositor_effects = [clouds]
		_add_node(undo_redo, root, environment)
		done.append("added WorldEnvironment with clouds")
		details.append("Added a WorldEnvironment (procedural sky) with a SunshineClouds3 effect in its compositor.")
	elif add_clouds:
		if environment.compositor == null:
			var compositor := Compositor.new()
			compositor.compositor_effects = [clouds]
			undo_redo.add_do_property(environment, &"compositor", compositor)
			undo_redo.add_undo_property(environment, &"compositor", null)
		else:
			var effects := environment.compositor.compositor_effects.duplicate()
			effects.append(clouds)
			undo_redo.add_do_property(environment.compositor, &"compositor_effects", effects)
			undo_redo.add_undo_property(environment.compositor, &"compositor_effects", environment.compositor.compositor_effects.duplicate())
		done.append("added clouds to %s" % environment.name)
		details.append("Added a SunshineClouds3 effect to %s's compositor." % environment.name)

	if driver == null:
		# Its lists set before it's in the tree, with paths from where it will be (under root).
		driver = SunshineClouds3Driver.new()
		driver.name = "SunshineClouds3Driver"
		driver.clouds_resource = clouds
		driver.world_environment = environment
		for light : DirectionalLight3D in lights:
			driver.directional_lights.append(NodePath("..") if light == root else NodePath("../%s" % root.get_path_to(light)))
			driver.directional_light_settings.append(CloudDirectionalLightSettings.new())
		_add_node(undo_redo, root, driver)
		done.append("added driver")
		details.append("Added a SunshineClouds3Driver driving the clouds.")
	else:
		if driver.clouds_resource != clouds:
			undo_redo.add_do_property(driver, &"clouds_resource", clouds)
			undo_redo.add_undo_property(driver, &"clouds_resource", driver.clouds_resource)
			done.append("%s now drives them" % driver.name)
			details.append("Set %s's clouds_resource to the clouds." % driver.name)
		if driver.world_environment != environment:
			undo_redo.add_do_property(driver, &"world_environment", environment)
			undo_redo.add_undo_property(driver, &"world_environment", driver.world_environment)
			done.append("%s gets %s's sky" % [driver.name, environment.name])
			details.append("Set %s's world_environment to %s, for the skybox." % [driver.name, environment.name])
		if !lights.is_empty():
			_add_to_list(undo_redo, driver, "directional", lights)

	if !lights.is_empty():
		var names := PackedStringArray(lights.map(func(light : Node) -> String: return light.name))
		done.append("connected %s" % (", ".join(names) if names.size() <= 3 else "%d directional lights" % names.size()))
		details.append("Connected directional light%s %s to the driver." % ["" if names.size() == 1 else "s", ", ".join(names)])
	undo_redo.commit_action()
	EditorInterface.edit_node(driver)
	_toast("Sunshine Clouds: %s." % ", ".join(done), EditorToaster.SEVERITY_INFO, "\n".join(details))


# Adds nodes to one of driver's lists (SunshineClouds3Driver.LISTS) with default settings, undoably.
static func _add_to_list(undo_redo : EditorUndoRedoManager, driver : SunshineClouds3Driver, list : String, nodes : Array) -> void:
	var paths_property : StringName = SunshineClouds3Driver.LISTS[list][0]
	var settings_property : StringName = SunshineClouds3Driver.LISTS[list][1]
	var paths : Array = driver.get(paths_property).duplicate()
	var settings : Array = driver.get(settings_property).duplicate()
	for node : Node in nodes:
		paths.append(driver.get_path_to(node))
		match list:
			"directional":
				settings.append(CloudDirectionalLightSettings.new())
			"omni":
				settings.append(CloudOmniLightSettings.new())
			_:
				settings.append(CloudEffectorSettings.new())
	undo_redo.add_do_property(driver, paths_property, paths)
	undo_redo.add_do_property(driver, settings_property, settings)
	undo_redo.add_undo_property(driver, paths_property, driver.get(paths_property).duplicate())
	undo_redo.add_undo_property(driver, settings_property, driver.get(settings_property).duplicate())


static func _add_node(undo_redo : EditorUndoRedoManager, root : Node, node : Node) -> void:
	undo_redo.add_do_method(root, &"add_child", node, true)
	undo_redo.add_do_method(node, &"set_owner", root)
	undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(root, &"remove_child", node)


# As the addon's test scene has it: a procedural sky, filmic tonemapping.
static func _new_environment() -> Environment:
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	return environment


static func _clouds_of(environment : WorldEnvironment) -> SunshineClouds3:
	if environment.compositor:
		for effect in environment.compositor.compositor_effects:
			if effect is SunshineClouds3:
				return effect
	return null


# node and its descendants (in tree order) that matches returns true for.
static func _find_all(node : Node, matches : Callable, found : Array = []) -> Array:
	if matches.call(node):
		found.append(node)
	for child in node.get_children():
		_find_all(child, matches, found)
	return found


static func _toast(message : String, severity := EditorToaster.SEVERITY_INFO, tooltip := "") -> void:
	EditorInterface.get_editor_toaster().push_toast(message, severity, tooltip)
