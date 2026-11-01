# SunshineClouds 3

Raymarched volumetric clouds and a physically based atmosphere for Godot 4, built as a compositor effect.

SunshineClouds 3 is a ground-up rewrite of [SunshineClouds 2](https://github.com/Bonkahe/SunshineClouds2). It keeps what people liked about SC2: clouds you can fly through, soft or stylized looks, and a quick setup. On top of that it adds stacked cloud layers, a precomputed sky and atmosphere, a generated skybox for reflections and ambient light, a spherical planet mode, and cloud shadows cast through Godot's own lights.

> **Early days:** SunshineClouds 3 is still in development (currently v0.2). Settings and defaults may change between versions, and a couple of SC2 features have not been brought over yet. See [Not yet implemented](#not-yet-implemented).

## What it's for

SunshineClouds 3 is meant for projects where the sky matters and the camera can go anywhere:

* **Open worlds and flight games** where the player flies up to, through and above the clouds, and sees them stretch out to the horizon.
* **Day/night cycles** where the sky, the clouds, the sunlight color and the scene's ambient light all need to agree with each other as the sun moves.
* **Large or planetary scale scenes**, with clouds and atmosphere that can curve around a planet instead of sitting on a flat plane.
* **Stylized games** that want soft, painterly or cartoony volumetric clouds rather than realistic ones. The lighting, phase and density settings cover a wide range of looks.

## Features

### Clouds
* Fully volumetric clouds. You can fly through them, and they render out to the horizon (150 km by default, adjustable).
* Up to **8 cloud layers**. Each layer has its own floor, ceiling, density, noise scales and wind speeds, so cumulus, stratus and high cirrus-like decks can share a sky.
* Per-layer **height profile curves** for cloud shape, detail strength and curl strength over the height of the layer.
* Shape built from base noise, detail noise and coverage noise, plus **curl noise** that warps the cloud bases into turbulent, wind-torn bottoms.
* **Wind** that moves each noise of each layer at its own speed, with the detail noise also rising. Direction and strength changes ease in smoothly, and wind can run in the editor, in game, or both.
* **Effectors**: spheres that add or clear clouds in an area within each layer's own shapes. Use the `SunshineEffector` node, or attach effector settings to any `Node3D`.
* Built-in tools to rebuild the noise composite and curl noise textures if you want your own.

### Lighting
* Up to **4 directional lights** and **8 omni lights** on the clouds. Each light has its own settings for energy, self-shadowing samples and (for directional lights) color.
* Dual Henyey-Greenstein phase functions with a multiple scattering approximation, for bright silver linings toward the sun and soft glowing interiors.
* Density-aware ambient lighting, with sky light from above and ground bounce from below, dimmed through the cloud. Dense cores darken and thin wisps stay lit.
* `SunshineOmniLight`: an omni light with its own cloud radius that can light **only the clouds**. Good for lightning, explosions or city glow seen from above.
* Optional **driven sun color**: the driver tints your directional light by the atmosphere at the camera, so the whole scene warms and dims toward sunset along with the sky.
* A configurable fallback light, so the clouds still look right before any lights are connected.

### Atmosphere and sky
* Precomputed atmospheric scattering (Rayleigh, Mie and ozone, multiple scattering orders), based on Eric Bruneton's model. Fully adjustable: planet radius, atmosphere height, haze, scattering heights and more.
* **Skybox generation**: renders the atmosphere, background and a coarse pass of the clouds into a panorama and uses it as your `WorldEnvironment`'s sky. Reflections and ambient light follow the time of day and the cloud cover, in the editor too.
* **Background panorama** behind the atmosphere (stars, nebulae and so on). It fades in as the sky darkens and can be rotated to move the stars through the night.
* **Spherical planet mode**: curves the cloud layers, atmosphere and shadows around a planet center, for scenes that go up to orbit or cover planetary distances.

### Cloud shadows
* Cloud shadows on the world in two modes:
  * **Light Projector**: the shadow map is projected through your directional light, so it works with Godot's own shadowing (needs an engine build with directional light projectors, see [Cloud shadows](#cloud-shadows-1)).
  * **Screen Space**: darkens opaque surfaces in the composite, ambient light included. Works on stock Godot, and is the automatic fallback.
* Adjustable resolution, extent, strength, sharpness and horizon fade. Updates are spread across frames to save GPU time.

### Performance
* Reduced-resolution raymarching (full, half or quarter) reconstructed to full resolution, plus optional interlacing, so only a fraction of pixels are traced each frame.
* Temporal accumulation with reprojection that follows both the camera and the wind.
* Adaptive step sizes: coarse steps through empty sky, fine steps once a ray finds cloud, and longer steps with distance.
* Shadow maps and the skybox update every N frames and blend in between.
* Per-viewport buffers, so multiple cameras and viewports each get their own clouds.

### Editor workflow
* **One-click setup** from *Project > Tools > Add Sunshine Clouds to Scene* (see below).
* Inspector lists on the driver for directional lights, omni lights and effectors, with full undo/redo.
* `SunshineEffector` and `SunshineOmniLight` nodes connect themselves to the scene's driver when you add them.
* 3D viewport gizmos with draggable handles for effector radius (blue to add clouds, red to clear) and omni light cloud radius.
* Shaders hot-reload in the editor when you edit the addon's `.glsl` files.

## Not yet implemented

These SunshineClouds 2 features are **not available in SunshineClouds 3 yet**:

* **MSAA support**: the clouds don't support MSAA at the moment. Keep MSAA off on viewports that render clouds.
* **Cloud painting**: the editor tools for painting cloud density and color are not implemented yet. For now, clouds are procedural, shaped by layers, noise and effectors.

## Requirements

* Godot **4.8** (the version SunshineClouds 3 is developed on).
* The **Forward+** renderer. The effect runs on compute shaders through the compositor, so the Compatibility renderer isn't supported.
* For projector cloud shadows only: a Godot build with directional light projectors (see [Cloud shadows](#cloud-shadows-1)). Everything else works on stock Godot.

## Installation

1. Download this repository and copy the `addons/SunshineClouds3` folder into your project's `addons` folder.
2. Activate the plugin (*Project > Project Settings > Plugins > SunshineClouds3*).
3. Open the scene you want clouds in.
4. Choose *Project > Tools > Add Sunshine Clouds to Scene*.
5. Have fun!

Step 4 does the setup for you as a single undoable action:
* adds a `WorldEnvironment` (with a procedural sky) if the scene doesn't have one,
* adds a `SunshineClouds3` effect to its compositor,
* adds a `SunshineClouds3Driver` pointed at the effect and the environment,
* connects every `DirectionalLight3D` in the scene to the driver.

You can run it again any time to connect directional lights you've added since.

### A few things to turn on

* **Wind** is off by default. Enable *Iterate Wind In Game* (and *Iterate Wind In Editor* if you want to see it while editing) on the driver.
* **Skybox** is off by default. Enable *Skybox > Skybox Enabled* on the clouds resource to have the atmosphere drive your scene's sky, reflections and ambient light. The driver needs its *World Environment* set, which the setup tool does.

### Manual setup

If you'd rather wire it up yourself:
1. Add a `SunshineClouds3` effect to your `WorldEnvironment`'s compositor.
2. Add a `SunshineClouds3Driver` node, and set its *Clouds Resource* to that same effect and its *World Environment* to the `WorldEnvironment`.
3. Add your lights under *Cloud Lights* on the driver, and any effectors under *Cloud Effectors*.

## How it fits together

| Piece | What it does |
| --- | --- |
| `SunshineClouds3` | The compositor effect and its resource. All cloud, layer, lighting, atmosphere, skybox, shadow and quality settings live here. |
| `CloudLayer` | One layer of clouds in the effect's *Layers* array: its height range, density, shape curves, noise scales and wind speeds. |
| `SunshineClouds3Driver` | A node that drives the effect each frame: feeds it the scene's lights and effectors, moves the wind, puts the skybox on the environment and the shadow projector on the light. |
| `SunshineEffector` | A `Node3D` that adds clouds (positive strength) or clears them (negative strength) inside its radius. |
| `SunshineOmniLight` | An `OmniLight3D` with cloud settings on itself: a separate cloud radius, an energy multiplier, and the option to light only the clouds. |

A light's energy on the clouds is its `light_energy` times its `light_volumetric_fog_energy`, times the multipliers in its cloud settings and on the effect. You can tune how a light affects the clouds separately from how it lights the world.

## Scripting

### Sampling cloud density

You can ask the clouds how dense they are at any point in the world. Use it for turbulence, visibility, gameplay inside clouds, and similar. The sample is read back from the GPU, and your callback runs a frame or two later:

```gdscript
@export var clouds : SunshineClouds3Driver

func _physics_process(_delta : float) -> void:
	clouds.add_sample(_on_cloud_sample, global_position)

func _on_cloud_sample(position : Vector3, density : float) -> void:
	if density > 0.1:
		print("Inside a cloud at ", position)
```

Up to 32 samples are processed per frame. Any extra roll over to the next frame.

### Lights and effectors at runtime

The driver can add and remove lights and effectors while the game runs. Each call returns the settings resource, which you can tweak:

```gdscript
var settings := clouds.add_omni_light($Explosion/OmniLight3D)
settings.energy_multiplier = 4.0

clouds.add_effector($StormCenter)        # any Node3D
clouds.remove_directional_light($Moon)
```

### Floating origin

If your project shifts the world origin, set the driver's `origin_offset` to the offset, and the cloud noise stays put in the world.

## Cloud shadows

*Light Projector* mode puts the cloud shadow map on your strongest shadow-casting directional light as a light projector. Stock Godot doesn't support projectors on directional lights yet. There is an open PR adding them ([godotengine/godot#106294](https://github.com/godotengine/godot/pull/106294)), and you'll need to build Godot with it to use this mode. The light must also have *Shadow Enabled* on.

When projectors aren't available, the driver logs a warning and the effect falls back to *Screen Space* shadows. You can also choose *Screen Space* directly. It works on any Godot build.

## Contribution

Feel free to make PRs or issues here, I'll fix them as I'm able. I'd love to see whatever you all come up with!
For questions feel free to hit me up on Discord: [https://discord.com/invite/zGMPmPJ2Y8](https://discord.com/invite/zGMPmPJ2Y8)
Thank you so much to all the wonderful people who support me.

### Current outstanding issues and limitations
* MSAA is not supported yet.
* Cloud painting is not implemented yet.
* Projector cloud shadows need a custom Godot build until directional light projectors are merged.
* Spherical planet mode:
  * Coverage noise is still sampled in flat world space, so set each layer's *Coverage Noise Strength* to 0 when using it.
  * The driven sun color isn't accurate when the sun is on the far side of the planet. Turn off *Drive Light Color* on the light's cloud settings.
* Clouds in the skybox are a coarse approximation: even steps, no curl noise and no omni lights. This is fine for reflections and ambient light, not for close viewing.
* Limits: 8 cloud layers, 4 directional lights, 8 omni lights and 16 effectors.

## References and credits

* Andrew Schneider's work on real-time volumetric clouds: [schneidervfx.com](https://www.schneidervfx.com/andrew-schneider-real-time-volumetrics-and-vfx)
* Eric Bruneton's [Precomputed Atmospheric Scattering](https://ebruneton.github.io/precomputed_atmospheric_scattering/), which the atmosphere follows closely. The atmosphere shader code is under its own BSD license, included at `addons/SunshineClouds3/Compute/atmosphere/LICENSE.txt`.

## License

This plugin has been released under the [MIT License](https://github.com/Bonkahe/SunshineClouds3/blob/main/LICENSE). The atmosphere code in `addons/SunshineClouds3/Compute/atmosphere` is under Eric Bruneton's BSD license, as noted above.
