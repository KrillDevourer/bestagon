class_name DuelPlayer
extends CharacterBody3D
## The player, in first person, for the boss duel.
##
## A SECOND BODY, NOT A CONVERTED ONE. scenes/player/player.tscn stays exactly
## what it is: a CharacterBody2D the whole 2D game is built around. boss.gd
## records what happens when something merely RESEMBLES the type the rest of the
## game casts to, and the same trap applies in reverse -- retrofitting the 2D
## player into 3D would put every weapon, projectile and hurtbox in the game one
## cast away from silently not working.
##
## The RULES are shared, though, and that is the whole reason this is affordable:
## Health, BuffState, Stats and Difficulty are all RefCounted or Resource with
## time injected, so the duel runs the same HP, the same invulnerability windows
## and the same upgrade numbers as the arena. Only the body is new.
##
## MOUSE LOOK IS THE PROJECT'S FIRST MOUSE DEPENDENCY. There was not a single
## InputEventMouse in project.godot before this. Two consequences that are easy to
## miss and expensive to find:
##   * Capture must be RELEASED whenever a modal opens or the window loses focus,
##     or a paused game eats the cursor and the player cannot reach the menu.
##   * The web build needs a user gesture before pointer lock will engage, so
##     capture cannot simply be set in _ready and assumed.
## Both are handled here rather than by the caller, so there is one place that
## knows the cursor rules.

## Eye height in metres. The duel works in METRES, unlike the arena stage which
## works in 100-pixels-to-the-unit -- a first-person scene has to be scaled to a
## person or nothing in it reads as a size at all.
const EYE_HEIGHT: float = 1.7
## Radians per pixel of mouse movement. Deliberately a constant for now: a
## sensitivity slider belongs in Settings alongside shake_scale, and shipping it
## as a magic number here would be the second place that owns the same value.
const MOUSE_SENS: float = 0.0022
## Just short of straight up and down. Exactly 90 lets the camera roll past
## vertical and invert the world.
const PITCH_LIMIT_DEG: float = 85.0
## Strafing sideways as fast as advancing is what makes an FPS feel weightless.
const STRAFE_SCALE: float = 0.86
const GRAVITY: float = 24.0
## How hard the body stops when input is released. High, because a duel is about
## precise spacing and a sliding player cannot hold a distance.
const FRICTION: float = 14.0
const ACCEL: float = 12.0

## Metres per second at the arena's base move speed. The 2D game's 55 px/s over a
## 640px viewport is about a twelfth of the screen per second; this is tuned to
## feel equivalent in a room measured in metres rather than derived from it,
## because pixels and metres are not convertible and pretending they are would
## produce a number that looks principled and plays wrong.
const BASE_SPEED: float = 6.2

## Invulnerability after a hit. The arena's value, not a duel-specific one -- the
## fight is harder or easier than the 2D game for design reasons, never because two
## copies of the same rule drifted apart.
const HIT_IFRAMES: float = 0.6

signal died
signal health_changed(hp: int, max_hp: int)

var speed: float = BASE_SPEED
## THE SHARED RULE. Not a duel-local hp int: Health is RefCounted with time
## injected, so the duel runs the same HP arithmetic, the same i-frame windows and
## the same shield interaction as the arena. Assigned by the arena from the run's
## real health so a duel starts on the HP the player walked in with.
var health: Health

var _yaw: float = 0.0
var _pitch: float = 0.0
## Own clock, because Health takes time as an argument rather than reading one.
## Starts at 0 on entering the duel, which is safe precisely because every window
## Health tracks is relative.
var _time: float = 0.0

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	camera.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	# TAKE THE CAMERA. ArenaStage's Camera3D is `current` for the whole 2D run and
	# lives in the SAME World3D as this scene, so without claiming it the duel is
	# rendered from the arena's top-down eye: the first live test showed the duel
	# boss as a black silhouette over the 2D floor grid, with the duel HUD correctly
	# on top of it. Two cameras in one world, and the wrong one was winning.
	camera.current = true
	if health == null:
		# Standalone inspection only. A real duel is handed the run's own Health.
		health = Health.new(12, HIT_IFRAMES)
	health.died.connect(func() -> void: died.emit())
	health.changed.connect(func(hp: int, max_hp: int) -> void:
		health_changed.emit(hp, max_hp))
	capture_mouse(true)


## Enemy fire landed. Named for what hit rather than for what it does, matching
## Player.apply_damage's `source` habit -- BRIEF defect #4 is a run that ends
## without the player understanding why, and "a bolt" is an answer.
func take_bolt(amount: int) -> void:
	if health == null:
		return
	if health.take_damage(amount, _time):
		Sfx.play(&"hurt", -2.0)


## Public because Main and the pause menu both need to let go of the cursor, and
## because the web build cannot capture until the player has clicked something.
func capture_mouse(on: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


## Release the cursor the instant the window stops being the thing the player is
## looking at. Without this, alt-tabbing out of a duel leaves the pointer locked
## to a window that is no longer focused.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		capture_mouse(false)


func _unhandled_input(event: InputEvent) -> void:
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion == null or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	_yaw -= motion.relative.x * MOUSE_SENS
	_pitch = clampf(_pitch - motion.relative.y * MOUSE_SENS,
			-deg_to_rad(PITCH_LIMIT_DEG), deg_to_rad(PITCH_LIMIT_DEG))
	# Yaw on the BODY and pitch on the CAMERA, never both on one node. Pitching
	# the body would tilt its collision shape and let the player walk up walls.
	rotation.y = _yaw
	camera.rotation.x = _pitch


func _physics_process(delta: float) -> void:
	_time += delta
	# The same four actions the 2D game uses, so the duel needs no new bindings
	# and a rebound key works in both halves of the game.
	var input: Vector2 = Input.get_vector(&"move_left", &"move_right",
			&"move_up", &"move_down")
	# Relative to where the player is LOOKING. -Z is forward in Godot.
	var forward: Vector3 = -transform.basis.z
	var right: Vector3 = transform.basis.x
	var wish: Vector3 = (forward * -input.y + right * input.x * STRAFE_SCALE)
	wish.y = 0.0
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	var target: Vector3 = wish * speed
	var rate: float = ACCEL if wish.length_squared() > 0.01 else FRICTION
	velocity.x = move_toward(velocity.x, target.x, rate * speed * delta)
	velocity.z = move_toward(velocity.z, target.z, rate * speed * delta)
	# Gravity, so the floor is a real floor. There is nothing to jump onto and no
	# jump action; this only keeps the body seated.
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * delta
	move_and_slide()


## Point the body at something, yaw only. Used once, on entering the duel: being
## dropped into a boss fight facing a wall reads as the scene having failed to
## load rather than as a choice.
##
## Sets `_yaw` as well as the transform, or the first mouse motion would snap the
## view back to whatever yaw the look never told the input state about.
func look_at_boss(at: Vector3) -> void:
	var to: Vector3 = at - global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	_yaw = atan2(-to.x, -to.z)
	rotation.y = _yaw


## Where the player is aiming, for the duel weapon. Taken off the CAMERA rather
## than the body, so a shot goes where the crosshair is including pitch.
func aim_direction() -> Vector3:
	return -camera.global_transform.basis.z


## Eye position in world space, so a shot leaves the face and not the feet.
func muzzle_position() -> Vector3:
	return camera.global_position
