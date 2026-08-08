extends Node3D
## DEV HARNESS — can the flat 2D arena tilt into 3D, with the boss standing up
## out of it, without losing the pixel grid?
##
## This answers that ONE question before any of it touches main.tscn. Excluded
## from exports, like everything else in scenes/dev/.
##
## WHY A TEXTURED FLOOR AND NOT A 3D GAME. Boss extends Enemy, which is a
## CharacterBody2D, and boss.gd records what happens when something merely
## RESEMBLES an Enemy: the weapon's nearest-target query and the projectile's hit
## check both cast, so it shipped once as untargetable AND invulnerable. Gameplay
## stays 2D. Only the PRESENTATION becomes 3D, so not one line of combat code has
## to be trusted again.
##
## WHY THE CAMERA IS PERSPECTIVE EVEN WHEN THE ARENA LOOKS FLAT. A plane viewed
## square-on has uniform depth, so a perspective projection distorts it by
## exactly nothing — the flat state is pixel-identical to an orthogonal render.
## That makes tilt ONE continuous parameter from zero, instead of a switch
## between two projections that cannot be interpolated and would pop on the frame
## it flipped.
##
## WHY A PIVOT AND NOT look_at. At zero tilt the camera stares straight down, and
## `look_at` with a +Y up vector is degenerate on exactly that axis — it produces
## either a flipped frame or a warning, depending on float noise. Parenting the
## camera to a rotating pivot has no singularity anywhere in the range.
##
## PITCH ONLY — no roll, no yaw. The game reads WASD as screen-relative and the
## weapons aim themselves, so pitch keeps screen-up pointing at world-up and the
## controls keep meaning what they meant. Any yaw and "up" stops being up while
## the player is being shot at.
##
## Run it:
##   <console.exe> --path . -w --resolution 1280x720 res://scenes/dev/arena_3d_check.tscn
##   ... --fixed-fps 60 -- --screenshot=<abs>/.ai/tilt.png --shot-frames=1,20,40,60,80,100
##   ... -- --tilt=38 --screenshot=<abs>/.ai/tilt38.png --shot-frame=20   # hold one angle

## The game's own viewport. The SubViewport has to match it exactly or the floor
## is showing a resampled arena and every shimmer question is answered wrong.
const VIEW_SIZE: Vector2i = Vector2i(640, 360)
## World units, same 16:9 as VIEW_SIZE. Small numbers on purpose — a 640-unit
## quad burns depth precision for nothing. 100 view pixels to the unit.
const FLOOR_SIZE: Vector2 = Vector2(6.4, 3.6)
const PIXELS_PER_UNIT: float = 100.0
const FOV: float = 45.0
## How far the camera swings up off straight-down at full tilt. 38 degrees is the
## opening guess: enough that the floor visibly recedes, short of the point where
## the far half compresses into unreadable mush.
const MAX_TILT_DEG: float = 38.0
## Seconds for a full flat -> tilted sweep.
const TILT_TIME: float = 1.4
## Fraction of camera distance given back at full tilt, to refill the frame a
## lean empties out. Modest — dolly hard enough to fill every pixel and the
## arena's own edges start leaving the screen.
const DOLLY_IN: float = 0.16
## The floor's own navy, so the space around a tilted arena is not black bars.
const BACKDROP: Color = Color(0.05, 0.05, 0.08)

## Boss solid, in world units. The Prism sprite is ~64 view px across, so a 0.32
## circumradius puts the solid at the size of the thing it replaces — which is
## the point: at zero tilt nobody should be able to tell it changed.
const BOSS_RADIUS: float = 0.32
const BOSS_HEIGHT: float = 0.52
const BOSS_TINT: Color = Color(0.85, 0.88, 1.0)

var _sub: SubViewport
var _floor: MeshInstance3D
var _pivot: Node3D
var _camera: Camera3D
var _boss: MeshInstance3D
var _spin: Node2D

var _elapsed: float = 0.0
## >= 0 pins the tilt at a fixed angle instead of sweeping. For photographing one
## specific pose without racing the animation.
var _hold_deg: float = -1.0


func _ready() -> void:
	_parse_args()
	_build_world()
	_build_arena_2d()
	_build_floor()
	_build_boss()
	_build_camera()
	_apply_tilt(0.0)


func _parse_args() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--tilt="):
			_hold_deg = float(arg.get_slice("=", 1))


func _build_world() -> void:
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKDROP
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.30, 0.32, 0.45)
	env.ambient_light_energy = 1.0
	var world: WorldEnvironment = WorldEnvironment.new()
	world.environment = env
	add_child(world)

	# One key light. The floor is unshaded (it is a finished 2D frame), so this
	# exists solely to give the boss solid facets that differ from one another —
	# without it a flat-shaded prism renders as one flat hexagon and the whole
	# exercise looks exactly like the sprite it replaced.
	var key: DirectionalLight3D = DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	key.light_energy = 1.15
	add_child(key)


## The 2D game, rendered off-screen. Stand-in content, not the real Main — this
## harness is asking about the RENDER PATH, and booting the director, spawner and
## level-up panel to ask it would only add ways for the answer to be wrong.
func _build_arena_2d() -> void:
	_sub = SubViewport.new()
	_sub.size = VIEW_SIZE
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# The project sets nearest filtering globally, but a SubViewport does NOT
	# inherit it — it defaults to linear, which blurs every sprite and makes the
	# pixel-grid verdict meaningless. Cost one confusing capture to find.
	_sub.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	# The arena is opaque; a transparent target would composite the backdrop twice.
	_sub.transparent_bg = false
	add_child(_sub)

	var floor_sprite: Sprite2D = Sprite2D.new()
	floor_sprite.texture = load("res://assets/sprites/floor.png") as Texture2D
	floor_sprite.centered = false
	floor_sprite.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	floor_sprite.region_enabled = true
	floor_sprite.region_rect = Rect2(0, 0, VIEW_SIZE.x, VIEW_SIZE.y)
	floor_sprite.z_index = -10
	_sub.add_child(floor_sprite)

	# A rotating ring, because a still frame cannot answer "does it shimmer".
	_spin = Node2D.new()
	_spin.position = Vector2(VIEW_SIZE) * 0.5
	_sub.add_child(_spin)
	for i: int in 6:
		var enemy: Sprite2D = Sprite2D.new()
		enemy.texture = load("res://assets/sprites/enemy.png") as Texture2D
		enemy.position = Vector2.RIGHT.rotated(TAU * float(i) / 6.0) * 118.0
		_spin.add_child(enemy)

	var player: Sprite2D = Sprite2D.new()
	player.texture = load("res://assets/sprites/player_body.png") as Texture2D
	player.position = Vector2(VIEW_SIZE) * 0.5 + Vector2(0.0, 132.0)
	_sub.add_child(player)


## The arena, lying flat in XZ so that "up out of the floor" is simply +Y and the
## boss needs no orientation fixup. QuadMesh is authored in XY, hence the tip.
func _build_floor() -> void:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_texture = _sub.get_texture()
	# The arena lights itself — it is a picture of an already-finished frame, and
	# 3D lighting on it would double-shade art that already carries its own.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# The whole point of the exercise: keep the pixels square.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	var mesh: QuadMesh = QuadMesh.new()
	mesh.size = FLOOR_SIZE

	_floor = MeshInstance3D.new()
	_floor.mesh = mesh
	_floor.material_override = mat
	_floor.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(_floor)


## THE PRISM as an actual solid, standing at the arena's centre.
func _build_boss() -> void:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = BOSS_TINT
	mat.metallic = 0.25
	mat.roughness = 0.28
	# gl_compatibility has no glow pass (see enemy.gd), so emission is the only
	# way the solid keeps the lit-from-within look the sprite gets from its baked
	# halo. It brightens the facets; it does not bloom, and it must not pretend to.
	mat.emission_enabled = true
	mat.emission = BOSS_TINT
	mat.emission_energy_multiplier = 0.35

	_boss = MeshInstance3D.new()
	_boss.mesh = HexPrism.build(BOSS_RADIUS, BOSS_HEIGHT)
	_boss.material_override = mat
	add_child(_boss)


func _build_camera() -> void:
	# Camera hangs off a pivot at the arena's centre and only the pivot rotates.
	_pivot = Node3D.new()
	add_child(_pivot)

	_camera = Camera3D.new()
	_camera.fov = FOV
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.current = true
	_pivot.add_child(_camera)


## Camera distance that makes a plane `height` units deep fill a vertical `fov`.
## Static and public so the number can be checked rather than trusted — the same
## reason GameCamera.shake_pixels exists.
static func fit_distance(height: float, fov_deg: float) -> float:
	return (height * 0.5) / tan(deg_to_rad(fov_deg) * 0.5)


## `k` runs 0 (flat, straight down, pixel-exact) to 1 (full tilt).
func _apply_tilt(k: float) -> void:
	# -90 is straight down. Swinging toward 0 raises the eye and lays the floor
	# out ahead of it, which is the same physical act as looking further across a
	# room — so the perspective can only come out the way a floor actually looks.
	# An earlier pass rotated the FLOOR instead and got the sign backwards: it
	# tipped the near edge away and the far edge toward you, which reads as the
	# arena falling over.
	_pivot.rotation_degrees.x = -90.0 + MAX_TILT_DEG * k
	_camera.position = Vector3(0.0, 0.0,
			fit_distance(FLOOR_SIZE.y, FOV) * (1.0 - DOLLY_IN * k))
	# The boss is flush with the floor at zero tilt and rises as the world leans.
	# That ordering is the entire effect: while the arena is flat the solid is
	# indistinguishable from the sprite, and the tilt is what reveals it was
	# never a sprite at all.
	_boss.position.y = BOSS_HEIGHT * 0.5 * k


func _process(delta: float) -> void:
	_elapsed += delta
	if is_instance_valid(_spin):
		_spin.rotation += delta * 0.6
	_boss.rotation.y += delta * 1.15  # Boss.SHARD_SPIN, the rate the fight already uses
	_apply_tilt(_tilt_k())


## Ping-pong flat -> tilted -> flat, so one contact sheet shows the whole
## transition and both of its endpoints.
func _tilt_k() -> float:
	if _hold_deg >= 0.0:
		return clampf(_hold_deg / MAX_TILT_DEG, 0.0, 1.0)
	var phase: float = fmod(_elapsed, TILT_TIME * 2.0) / TILT_TIME
	var k: float = phase if phase <= 1.0 else 2.0 - phase
	# Fast out of flat, settling into the tilt rather than stopping dead at it.
	return ease(k, 0.4)
