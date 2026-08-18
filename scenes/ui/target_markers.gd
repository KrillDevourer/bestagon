class_name TargetMarkers
extends Control
## Edge-of-screen arrows pointing at things the player must deal with but cannot
## see. Built for NOGAXEH's shield gate.
##
## WHY THIS HAS TO EXIST, in numbers. Spawner.SPAWN_RADIUS is 380px and the camera
## shows 640x360, so the visible half-extents are 320 by 180. Every escort Prism is
## therefore placed FURTHER from the player than the screen edge in every
## direction -- 380 > 320 > 180 -- which means the two bodies gating the whole
## 10:00 fight were guaranteed off-screen at the moment they arrived, every run,
## with no exception. The banner said DESTROY THE PRISMS and the prisms were
## nowhere on screen. Playtest, in the player's words: "el jugador se pierde".
##
## AN ARROW, NOT A MINIMAP. A minimap is a second thing to read, and this game's
## HUD is deliberately four numbers and two bars at 640x360. An arrow answers the
## only question the player actually has -- which way -- and costs one glance.
##
## POINTS IN WORLD TERMS, not screen-projected terms. During a boss event the arena
## is tilted into 3D, so a world position no longer maps linearly to a screen
## position. Projecting through the 3D camera would be more "correct" and worse: the
## player moves in world space with WASD, so an arrow that agrees with the floor
## rather than with the projection is the one that tells them which key to hold.
## Pitch-only tilt is what makes this safe -- there is no yaw or roll to make a
## world direction disagree with a screen direction about left and right.

## Distance in from the viewport edge. Enough that the arrow is not clipped and
## does not collide with the HP bar or the boss banner.
const MARGIN: float = 20.0
## Arrow half-length in pixels, at 640x360.
##
## Started at 6 and measured on a 1280x720 capture: a 12-physical-pixel arrow was
## present, correct, and easy to miss. This is the ONLY thing telling the player
## which way to go in the fight they reported getting lost in, so it is sized to be
## seen rather than to be tasteful. 10 reads immediately without covering the arena.
const SIZE: float = 10.0
## Beats per second of the alpha pulse. Fast enough to catch the eye in a busy
## arena, slow enough not to read as a rendering fault.
const PULSE_RATE: float = 5.0
const PULSE_FLOOR: float = 0.55
## Half-extents of what the camera can see. A target inside this needs no arrow --
## the player is already looking at it, and an arrow over a visible enemy is
## clutter that teaches the player to ignore arrows.
const VIEW_HALF: Vector2 = Vector2(320.0, 180.0)
## Shrunk before the on-screen test, so a target hovering exactly at the boundary
## does not flicker the arrow on and off every frame.
const ONSCREEN_SLACK: float = 26.0

var _origin: Vector2 = Vector2.ZERO
var _targets: PackedVector2Array = PackedVector2Array()
var _tint: Color = Color.WHITE
var _time: float = 0.0


func _ready() -> void:
	# Arrows are decoration over a live fight; they must never eat a click meant
	# for something else.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## `origin` is the CAMERA's centre in world space, not the player's position. The
## two differ under screenshake and at the arena's edges where the camera stops
## following, and using the player would aim every arrow slightly wrong in exactly
## the moments the fight is most violent.
func track(origin: Vector2, targets: PackedVector2Array, tint: Color) -> void:
	_origin = origin
	_targets = targets
	_tint = tint
	set_process(not targets.is_empty())
	queue_redraw()


func clear() -> void:
	if _targets.is_empty():
		return
	_targets = PackedVector2Array()
	set_process(false)
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


func _draw() -> void:
	if _targets.is_empty():
		return
	var centre: Vector2 = size * 0.5
	var half: Vector2 = size * 0.5 - Vector2(MARGIN, MARGIN)
	if half.x <= 1.0 or half.y <= 1.0:
		return
	var pulse: float = PULSE_FLOOR + (1.0 - PULSE_FLOOR) \
			* (0.5 + 0.5 * sin(_time * PULSE_RATE * TAU))
	for target: Vector2 in _targets:
		var offset: Vector2 = target - _origin
		# Already on screen: no arrow. See ONSCREEN_SLACK for the hysteresis.
		if absf(offset.x) < VIEW_HALF.x - ONSCREEN_SLACK \
				and absf(offset.y) < VIEW_HALF.y - ONSCREEN_SLACK:
			continue
		if offset.length_squared() < 1.0:
			continue
		var dir: Vector2 = offset.normalized()
		_draw_arrow(centre + dir * _edge_distance(dir, half), dir, pulse)


## How far along `dir` the viewport's inner rectangle is. Solved per axis and
## minimised, which puts the arrow on the EDGE of a rectangle rather than on an
## inscribed ellipse -- an ellipse bunches the diagonals inward and makes corner
## targets look nearer than they are.
static func _edge_distance(dir: Vector2, half: Vector2) -> float:
	var reach: float = INF
	if absf(dir.x) > 0.0001:
		reach = minf(reach, half.x / absf(dir.x))
	if absf(dir.y) > 0.0001:
		reach = minf(reach, half.y / absf(dir.y))
	return 0.0 if is_inf(reach) else reach


func _draw_arrow(at: Vector2, dir: Vector2, pulse: float) -> void:
	var side: Vector2 = Vector2(-dir.y, dir.x)
	var tip: Vector2 = at + dir * SIZE
	var tail: Vector2 = at - dir * SIZE * 0.5
	var points: PackedVector2Array = PackedVector2Array([
		tip,
		tail + side * SIZE * 0.62,
		tail - side * SIZE * 0.62,
	])
	# A dark backing triangle first. The arena floor is a busy grid and a thin
	# bright shape on it disappears; the same trick the enemy halo uses, inverted.
	var shadow: PackedVector2Array = PackedVector2Array([
		tip + dir * 1.4,
		tail + side * SIZE * 0.62 + (side * 1.4) - dir * 1.0,
		tail - side * SIZE * 0.62 - (side * 1.4) - dir * 1.0,
	])
	draw_colored_polygon(shadow, Color(0.03, 0.03, 0.06, 0.85 * pulse))
	draw_colored_polygon(points, Color(_tint.r, _tint.g, _tint.b, pulse))
