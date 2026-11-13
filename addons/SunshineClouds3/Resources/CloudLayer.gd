@tool
extends Resource
class_name CloudLayer

@export_group("Layer")
## Off leaves the layer out, as if removed.
@export var enabled : bool = true:
	set(value):
		enabled = value
		emit_changed()
## World Y of the bottom of the layer.
@export var cloud_floor : float = 2000.0
## World Y of the top of the layer.
@export var cloud_ceiling : float = 7000.0
## Extinction per world unit at a cloud density of 1.
@export_range(0.0, 1.0, 0.0001, "or_greater") var density : float = 0.3213

@export_subgroup("Dimensional Profile")
## Pushes the coverage noise: 1 = full coverage everywhere, 0.5 = the noise as is, 0 = none.
## cloud_density = saturate(noise - (1 - vertical_profile(height) * coverage)); curves: 0 = floor, 1 = ceiling.
@export_range(0.0, 1.0, 0.001) var cloud_coverage : float = 0.581
## Cloud shape over height: how much of the noise survives at each height.
@export var vertical_profile_curve : Curve = _profile_curve([0.0, 0.01569, 16.71, 16.71, 0.06944444, 0.9550562, 0.24576867, 0.24576867,
	0.12562814, 0.66135466, -1.8260871, -1.8260871, 0.37339056, 0.45549738, 0.0, 0.0,
	0.884375, 0.27642274, -0.24628581, -0.24628581, 1.0, 0.003922, -2.739, -2.739]): # Default: fast rise off the floor, peak near 7%, tapering to 0 at the ceiling.
	set(value):
		_watch_curve(vertical_profile_curve, value)
		vertical_profile_curve = value
		emit_changed()
## Multiplies [member detail_strength] over height.
@export var detail_curve : Curve = _profile_curve([0.0, 1.0, 0.0, 0.0, 1.0, 0.0, -2.4269671, 0.0]): # Default: full detail at the floor, fading to none at the ceiling.
	set(value):
		_watch_curve(detail_curve, value)
		detail_curve = value
		emit_changed()
## Multiplies [member curl_strength] over height. The default keeps it to the bottom 7%, for turbulent bases.
@export var curl_curve : Curve = _profile_curve([0.0, 1.0, 0.0, 0.0, 0.07081545, 0.0, -0.45368385, 0.062191937]):
	set(value):
		_watch_curve(curl_curve, value)
		curl_curve = value
		emit_changed()

@export_group("Primary Noise")
## World size of one tile of the base noise composite.
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:m") var noise_scale : float = 16592.0
## World size of one tile of the coverage noise (sampled in world XZ).
@export_range(100.0, 1000000.0, 1.0, "or_greater", "suffix:m") var coverage_noise_scale : float = 68130.0
## Fills the gaps the coverage noise leaves: 0 = coverage fully from the noise, 1 = uniform [member cloud_coverage].
@export_range(0.0, 1.0, 0.01) var coverage_noise_strength : float = 0.0

@export_group("Detail Noise")
## Tile size of the noise composite resampled as detail, added before the coverage cut: lumps and bites in the
## surface at about the same volume.
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:m") var detail_noise_scale : float = 1807.0
## How far detail moves the surface: at 1, a 1-sigma detail sample moves it by the full local coverage. 0 = off.
@export_range(0.0, 1.0, 0.001, "or_greater") var detail_strength : float = 0.099
## Keeps detail to the soft, low primary-noise shapes between puffs, fading toward their cores: 0 = everywhere,
## 1 = only there.
@export_range(0.0, 1.0, 0.001) var detail_power : float = 1.0

@export_group("Curl Noise")
## World size of one tile of the curl noise.
@export_range(10.0, 100000.0, 1.0, "or_greater", "suffix:m") var curl_noise_scale : float = 6712.0
## How far each curl step pushes a sample, times [member curl_curve] at its height (0 = off).
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var curl_strength : float = 0.0

@export_group("Wind")
## World units/s SunshineClouds3Driver moves each noise at, at full wind (detail also rises at its speed).
@export var coverage_wind_speed : float = 2000.0
@export var base_wind_speed : float = 1000.0
@export var detail_wind_speed : float = 250.0
@export var curl_wind_speed : float = 500.0

# Wind offsets: noise positions set by SunshineClouds3Driver (sampled at position - offset), and noise_offset when the effect last drew, for reprojection.
var noise_offset : Vector3 = Vector3.ZERO
var detail_noise_offset : Vector3 = Vector3.ZERO
var coverage_noise_offset : Vector3 = Vector3.ZERO
var curl_noise_offset : Vector3 = Vector3.ZERO
var prev_noise_offset : Vector3 = Vector3.ZERO


func _init() -> void:
	# Initial values don't go through the setters.
	for curve : Curve in [vertical_profile_curve, detail_curve, curl_curve]:
		_watch_curve(null, curve)


## A Curve from (x, y, left tangent, right tangent) per point.
static func _profile_curve(points : Array) -> Curve:
	var curve := Curve.new()
	for i in range(0, points.size(), 4):
		curve.add_point(Vector2(points[i], points[i + 1]), points[i + 2], points[i + 3])
	return curve


## Re-emits a curve's edits as this layer's changed signal.
func _watch_curve(old_curve : Curve, new_curve : Curve) -> void:
	if old_curve && old_curve.changed.is_connected(emit_changed) \
			&& [vertical_profile_curve, detail_curve, curl_curve].count(old_curve) <= 1:
		old_curve.changed.disconnect(emit_changed)
	if new_curve && !new_curve.changed.is_connected(emit_changed):
		new_curve.changed.connect(emit_changed)


## The curves at height (0 = floor, 1 = ceiling) as r, g, b, each clamped to 0-1; a missing curve gives 1.
func sample_profile(height : float) -> Color:
	return Color(
		_sample_clamped(vertical_profile_curve, height),
		_sample_clamped(detail_curve, height),
		_sample_clamped(curl_curve, height),
		1.0)


## curve at height clamped to 0-1, NaN as 0 (clampf passes NaN through); a missing curve gives 1.
static func _sample_clamped(curve : Curve, height : float) -> float:
	if curve == null:
		return 1.0
	var value := curve.sample(height)
	return 0.0 if is_nan(value) else clampf(value, 0.0, 1.0)
