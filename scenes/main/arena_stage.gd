class_name ArenaStage
extends Node3D
## SYSTEM CONTRACT — Arena Stage
##
## Purpose: own how the arena is PRESENTED. The 2D game renders into a
##   SubViewport; this maps that render onto a floor in 3D and leans the camera
##   over it when a boss arrives.
##
## Ownership:
##   Owns:      the world SubViewport, the floor quad, the 3D camera and its
##              tilt, the stage lighting.
##   Does NOT own: anything about the game. It reads no run state, spawns
##              nothing, and can decide nothing. Main calls enter_boss and
##              exit_boss; this reacts.
##   Calls down: nothing.
##   Signals up: nothing.
##
## Invariants:
##   1. At rest the tilt is EXACTLY zero and the arena is undistorted: no
##      stretch, no offset, no resample. Geometry is exact.
##
##      COLOUR IS NOT. This invariant originally claimed "pixel-identical", and
##      measuring it proved that false. Capturing frame 2 of main.tscn before and
##      after this class existed and diffing the PNGs: 908096 of 921600 pixels
##      differ, with a maximum channel delta of 6/255. Not a wrong picture -- a
##      uniformly very slightly wrong picture, which is the harder kind to notice.
##
##      The cause is the sRGB round trip. Routing the arena through a 3D pass
##      samples the viewport texture as sRGB, works in linear, and writes sRGB
##      back out; the two conversions do not compose to identity at 8 bits.
##
##      It is invisible at 2.4% and the gate is green, so it ships -- but it
##      SHIPS AS A KNOWN COST, not as a claim nobody checked. A ShaderMaterial
##      sampling the texture raw and writing it straight through would remove it,
##      and is the fix if the palette ever turns out to care.
##   2. Pitch only. Never roll, never yaw.
##   3. Removing this node's effect is always possible by holding tilt at 0 —
##      there is no state that only makes sense mid-transition.
##
## Failure mode: if the tween is interrupted (restart mid-fight, a second boss
##   event arriving while the first is still leaning) the tilt resolves to
##   whichever of the two endpoints was asked for last. It never sticks partway.
##
## WHY GAMEPLAY STAYS 2D. Boss extends Enemy, which is a CharacterBody2D, and
## boss.gd records what happens when something merely RESEMBLES an Enemy: the
## weapon's nearest-target query and the projectile's hit check both cast, so it
## shipped once as untargetable AND invulnerable. Nothing here touches a body, a
## collision layer, or a signal the fight depends on.
##
## WHY THE CAMERA IS PERSPECTIVE EVEN WHEN THE ARENA LOOKS FLAT. A plane viewed
## square-on has uniform depth, so a perspective projection distorts it by
## nothing at all. That makes tilt ONE continuous parameter from zero instead of
## a switch between two projections that cannot be interpolated and would pop on
## the frame it flipped.
##
## WHY A PIVOT AND NOT look_at. At zero tilt the camera stares straight down, and
## `look_at` with a +Y up vector is degenerate on exactly that axis. A rotating
## pivot has no singularity anywhere in the range.

## Must equal the project's viewport size. If these ever disagree the floor is
## showing a resampled arena and invariant 1 is silently false.
const VIEW_SIZE: Vector2i = Vector2i(640, 360)
## World units. Same 16:9 as VIEW_SIZE, 100 view pixels to the unit. Small on
## purpose — a 640-unit quad burns depth precision for nothing.
const FLOOR_SIZE: Vector2 = Vector2(6.4, 3.6)
const FOV: float = 45.0
## How far the camera swings up off straight-down for a boss. Enough that the
## floor visibly recedes, short of where the far half compresses into mush.
const MAX_TILT_DEG: float = 38.0
## Fraction of camera distance given back at full tilt, refilling the frame a
## lean empties out. Modest, or the arena's own edges leave the screen.
const DOLLY_IN: float = 0.16
## Arriving is a shove; leaving is a release. The boss lands and the world tips
## under it fast enough to feel like an event, then settles back slowly enough
## that the run does not lurch back into flat the instant the last shard dies.
const TILT_IN_TIME: float = 1.1
const TILT_OUT_TIME: float = 1.9
## The floor's own navy, so the space a tilt opens up is not black bars.
const BACKDROP: Color = Color(0.05, 0.05, 0.08)

## 100 arena pixels to the world unit, fixed by FLOOR_SIZE against VIEW_SIZE.
## Named rather than divided inline because every 2D-to-3D conversion below
## depends on it and three copies of `/ 100.0` is three chances to drift.
const PIXELS_PER_UNIT: float = 100.0
## Boss solid height as a multiple of its radius. Tall enough to read as a
## standing object at 38 degrees, short enough that it does not hide the arena
## behind it.
const BOSS_HEIGHT_RATIO: float = 1.5
## Below this tilt the solids are hidden entirely. At rest the arena must look
## exactly like the 2D game it has always been, and a flat-on hexagon sitting
## over the sprite is not exactly that.
const SOLID_VISIBLE_ABOVE: float = 0.02
## Boss.SHARD_SPIN. The solid turns at the rate the fight already turns at, so
## the 3D body and the 2D shards under it stay in agreement.
const SOLID_SPIN: float = 1.15

## Where the 2D game lives. Everything that used to be a direct child of Main and
## has a position in the arena is under here now.
@onready var world_viewport: SubViewport = $WorldViewport

var _floor: MeshInstance3D
var _pivot: Node3D
var _camera: Camera3D
var _tilt: float = 0.0
var _tween: Tween
## Holds the 3D solids so they can be transformed as a group and are trivially
## separable from the floor when reading the remote scene tree.
var _solid_root: Node3D
## Boss (2D CharacterBody2D) -> MeshInstance3D standing in for it.
var _solids: Dictionary = {}
var _spin: float = 0.0


func _ready() -> void:
	# Must match the root viewport or invariant 1 cannot hold.
	world_viewport.size = VIEW_SIZE
	world_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# A SubViewport does NOT inherit the project's nearest filter. It defaults to
	# linear and blurs every sprite in the game. Cost one baffling capture to find.
	world_viewport.canvas_item_default_texture_filter = \
			Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	world_viewport.transparent_bg = false
	_build_environment()
	_build_floor()
	_build_camera()
	_apply(0.0)


func _build_environment() -> void:
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKDROP
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.30, 0.32, 0.45)
	env.ambient_light_energy = 1.0
	var world: WorldEnvironment = WorldEnvironment.new()
	world.environment = env
	add_child(world)

	# One key light. The floor is unshaded, so this exists only for the solids
	# that will later stand on it — without it a flat-shaded prism renders as one
	# flat hexagon and looks exactly like the sprite it replaced.
	var key: DirectionalLight3D = DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	key.light_energy = 1.15
	add_child(key)


## The arena, lying flat in XZ so "up out of the floor" is simply +Y. QuadMesh is
## authored in XY, hence the -90 tip.
func _build_floor() -> void:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_texture = world_viewport.get_texture()
	# The arena lights itself. It is a picture of an already-finished 2D frame,
	# and 3D lighting on it would double-shade art that carries its own.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	var mesh: QuadMesh = QuadMesh.new()
	mesh.size = FLOOR_SIZE

	_floor = MeshInstance3D.new()
	_floor.mesh = mesh
	_floor.material_override = mat
	_floor.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(_floor)


func _build_camera() -> void:
	_pivot = Node3D.new()
	add_child(_pivot)
	_camera = Camera3D.new()
	_camera.fov = FOV
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.current = true
	_pivot.add_child(_camera)
	_solid_root = Node3D.new()
	add_child(_solid_root)


## Give a boss a body in 3D. Called by Main on RunDirector.boss_spawned.
##
## The boss's 2D sprite is NOT hidden, and that is the composition rather than an
## oversight: it stays on the floor as the solid's footprint, so the thing has a
## visible base instead of hovering. It is also what keeps the flat state honest
## -- at zero tilt the solid is scaled to nothing and the sprite is the only
## thing on screen, exactly as it was before any of this existed.
##
## Takes an Enemy, not a Boss. The Shard is a shrunken Prism running boss.gd and
## the escorts are full Prisms, so this has to work for anything the director
## chooses to call a boss without knowing which is which.
func attach_boss(boss: Enemy) -> void:
	if boss == null or boss.stats == null or _solids.has(boss):
		return
	# stats.size is a DIAMETER in arena pixels, so halve it before converting.
	var radius: float = (boss.stats.size * 0.5) / PIXELS_PER_UNIT
	var height: float = radius * BOSS_HEIGHT_RATIO

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	# The boss's own tint from the colour law. Deriving it means a re-tinted boss
	# cannot end up with a solid that disagrees with the sprite under it.
	mat.albedo_color = boss.stats.tint
	mat.metallic = 0.25
	mat.roughness = 0.28
	# gl_compatibility has no glow pass (see enemy.gd), so emission is the only
	# way the solid keeps the lit-from-within look the sprite gets from its baked
	# halo. It brightens facets; it does not bloom, and must not pretend to.
	mat.emission_enabled = true
	mat.emission = boss.stats.tint
	mat.emission_energy_multiplier = 0.35

	var solid: MeshInstance3D = MeshInstance3D.new()
	solid.mesh = HexPrism.build(radius, height)
	solid.material_override = mat
	solid.visible = false
	_solid_root.add_child(solid)
	_solids[boss] = solid
	# tree_exited fires however the boss leaves -- killed, or freed wholesale on a
	# restart -- so the solid cannot outlive its body. `died` alone would leak one
	# per boss every time a run was restarted mid-fight.
	boss.tree_exited.connect(_drop_boss.bind(boss))


func _drop_boss(boss: Enemy) -> void:
	var solid: MeshInstance3D = _solids.get(boss) as MeshInstance3D
	if is_instance_valid(solid):
		solid.queue_free()
	_solids.erase(boss)


## Arena pixels to a point on the floor.
##
## The SubViewport is a 640x360 window onto a 1280x720 arena, so a world position
## only means something relative to where the Camera2D is currently looking --
## which is why this asks the viewport for its camera every frame instead of
## caching one. The player's camera is the only Camera2D in there, and it moves.
func _floor_point(world_pos: Vector2) -> Vector3:
	var cam: Camera2D = world_viewport.get_camera_2d()
	if cam == null:
		return Vector3.ZERO
	var top_left: Vector2 = cam.get_screen_center_position() - Vector2(VIEW_SIZE) * 0.5
	var on_screen: Vector2 = world_pos - top_left
	return Vector3(
			(on_screen.x / float(VIEW_SIZE.x) - 0.5) * FLOOR_SIZE.x,
			0.0,
			(on_screen.y / float(VIEW_SIZE.y) - 0.5) * FLOOR_SIZE.y)


## Solids track their bodies every frame and GROW OUT OF THE FLOOR as the world
## leans. Scaling height by tilt rather than fading opacity in is what sells it
## as one continuous move: the arena tips and the boss stands up out of it,
## instead of a second object appearing on top of the first.
func _update_solids(delta: float) -> void:
	_spin += delta * SOLID_SPIN
	var showing: bool = _tilt > SOLID_VISIBLE_ABOVE
	for boss: Variant in _solids.keys():
		var body: Enemy = boss as Enemy
		var solid: MeshInstance3D = _solids[boss] as MeshInstance3D
		if not is_instance_valid(body) or not is_instance_valid(solid):
			continue
		solid.visible = showing
		if not showing:
			continue
		var base: Vector3 = _floor_point(body.global_position)
		# The mesh is centred on its own origin, so lifting it by half its scaled
		# height is what puts its BASE on the floor rather than its middle.
		var height: float = (body.stats.size * 0.5 / PIXELS_PER_UNIT) * BOSS_HEIGHT_RATIO
		solid.scale.y = _tilt
		solid.position = base + Vector3(0.0, height * _tilt * 0.5, 0.0)
		solid.rotation.y = _spin


func _process(delta: float) -> void:
	_update_solids(delta)


## Camera distance that makes a plane `height` units deep fill a vertical `fov`.
## Static and public so the number can be checked rather than trusted — the same
## reason GameCamera.shake_pixels exists.
static func fit_distance(height: float, fov_deg: float) -> float:
	return (height * 0.5) / tan(deg_to_rad(fov_deg) * 0.5)


## Lean the world over. Called by Main on RunDirector.boss_spawned.
##
## Idempotent: a second boss arriving mid-lean retargets the same tween rather
## than stacking a second one. The 10:00 event spawns NOGAXEH and two escorts in
## the same tick, so this is the normal case, not an edge case.
func enter_boss() -> void:
	_tilt_to(1.0, TILT_IN_TIME)


## Lay it flat again. Called on RunDirector.boss_event_cleared.
func exit_boss() -> void:
	_tilt_to(0.0, TILT_OUT_TIME)


func _tilt_to(target: float, seconds: float) -> void:
	if is_equal_approx(_tilt, target) and _tween == null:
		return
	# Kill before create, every time. An abandoned tween on a node that outlives
	# it is the exact leak tools/verify.ps1 has a dedicated regression stage for.
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	# The fight continues while the world leans, so the tilt must not be frozen
	# by the pause that a level-up brings up mid-boss.
	_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_method(_apply, _tilt, target, seconds)


## `k` runs 0 (flat, straight down, pixel-exact) to 1 (full tilt).
func _apply(k: float) -> void:
	_tilt = k
	# -90 is straight down. Swinging toward 0 raises the eye and lays the floor
	# out ahead of it, the same physical act as looking further across a room, so
	# the perspective can only come out the way a floor actually looks. Rotating
	# the FLOOR instead gets the sign backwards and reads as the arena toppling.
	_pivot.rotation_degrees.x = -90.0 + MAX_TILT_DEG * k
	_camera.position = Vector3(0.0, 0.0,
			fit_distance(FLOOR_SIZE.y, FOV) * (1.0 - DOLLY_IN * k))


## How tilted the stage is right now, 0 to 1. Public so the 3D solids that will
## stand on this floor can rise in step with it rather than keeping their own
## copy of the clock and drifting out of phase with the camera.
func tilt() -> float:
	return _tilt
