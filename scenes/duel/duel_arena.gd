class_name DuelArena
extends Node3D
## SYSTEM CONTRACT — Duel Arena
##
## Purpose: a first-person 1v1 room for a boss fight. The run switches INTO this
##   scene when a duel boss arrives and back out when it dies.
##
## Ownership:
##   Owns:      the room, its lighting, the first-person player body, and the
##              boss's 3D body and behaviour.
##   Does NOT own: run state. HP, level, upgrades and unlocks belong to the run
##              and are passed IN. Nothing here writes to a save.
##   Calls down: DuelPlayer.
##   Signals up: `finished` when the duel resolves, so Main decides what a win or
##              a death MEANS. This scene does not know about game-over screens.
##
## Invariants:
##   1. The 2D game is not loaded while this runs, and this is not loaded while
##      the 2D game runs. There is never a frame with both combat models live.
##   2. Every rule shared with the arena comes from the SAME class -- Health,
##      Stats, Difficulty. A duel that computed its own damage would drift from
##      the game it is part of within one balance pass.
##   3. The cursor is captured only while this scene is the active thing. See
##      DuelPlayer.capture_mouse.
##
## WHY A SEPARATE SCENE, NOT A CONVERTED ONE. boss.gd records what happens when
## something merely RESEMBLES the type the rest of the game casts to: the weapon's
## nearest-target query and the projectile's hit check both cast to Enemy, and a
## boss that only looked like one shipped untargetable AND invulnerable. Retro-
## fitting the 2D player and boss into 3D bodies puts every weapon, projectile and
## hurtbox one cast away from that same failure. Switching scenes instead means
## the 2D combat model is not modified at all -- it is simply not running.
##
## SCALE IS METRES HERE, unlike ArenaStage which works at 100 pixels to the unit.
## A first-person scene has to be scaled to a person or nothing in it reads as a
## size. The two scales never meet: no value is converted between them, because
## pixels and metres are not convertible and a conversion factor would look
## principled while playing wrong.

## Emitted once, when the duel resolves. `won` false means the player died.
## Main decides what that means; this scene does not know what a game-over is.
signal finished(won: bool)

const PLAYER_SCENE: PackedScene = preload("res://scenes/duel/duel_player.tscn")

## Half-width of the room in metres. 15 gives roughly 30m across -- enough to
## circle a boss and to be cornered by one, which are the two things the space has
## to allow.
const ROOM_HALF: float = 15.0
const WALL_HEIGHT: float = 9.0
## Where the boss floats, and how far the player starts from it. Opposite sides,
## so the first frame of the duel is the boss at a readable distance rather than
## already in the player's face.
const BOSS_HOVER: float = 2.6
const PLAYER_START_Z: float = 11.0

## Boss solid, in metres. The Prism is a 70px sprite in the arena; here it is
## sized to LOOM -- roughly three times the player's height. A boss that reads as
## a threat top-down does not automatically read as one at eye level, and this is
## the number that carries it.
const BOSS_RADIUS: float = 2.2
const BOSS_HEIGHT: float = 3.6
const BOSS_SPIN: float = 0.55
## Degrees the solid is tipped off vertical, so its cap faces the player instead
## of the sky. Enough to read the polygon, not so much that it looks toppled.
const BOSS_CANT_DEG: float = 24.0
## Slow vertical drift, so a hovering solid is alive rather than parked.
const BOB_AMPLITUDE: float = 0.35
const BOB_RATE: float = 0.9

## The arena's own palette, so a duel is unmistakably the same game. Matches
## ArenaStage's void treatment rather than re-picking colours.
const VOID_TOP: Color = Color(0.026, 0.026, 0.05)
const VOID_HORIZON: Color = Color(0.10, 0.09, 0.17)
const FLOOR_TINT: Color = Color(0.55, 0.58, 0.95)
const WALL_TINT: Color = Color(0.10, 0.10, 0.19)

var player: DuelPlayer
var boss: DuelBoss

## Injected by Main before this scene is added. Nothing here reads a global.
var boss_stats: EnemyStats
var boss_sides: int = PolyPrism.DEFAULT_SIDES
## The run's own Health, so a duel starts on the HP the player walked in with and
## a hit taken here is a hit taken in the run. Null only when loaded standalone.
var player_health: Health
## The duel weapon's per-shot damage, derived from the run's loadout by
## DuelWeapon.derive. 0 leaves the weapon's own standalone default.
var weapon_damage: int = 0
## What the boss bar is titled. The run knows the name; this scene does not.
var boss_title: String = "THE PRISM"

var weapon: DuelWeapon
var hud: DuelHud
var _time: float = 0.0


func _ready() -> void:
	_build_environment()
	_build_room()
	_build_boss()
	_build_player()


func _build_environment() -> void:
	var env: Environment = Environment.new()
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = VOID_TOP
	sky_mat.sky_horizon_color = VOID_HORIZON
	sky_mat.ground_bottom_color = VOID_TOP
	sky_mat.ground_horizon_color = VOID_HORIZON
	# No sun disk: this game's readability rests on bullets being the brightest
	# thing on screen, and a bright blob in the backdrop would outrank them.
	sky_mat.sun_angle_max = 0.0
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.26, 0.28, 0.42)
	env.ambient_light_energy = 1.0
	var world: WorldEnvironment = WorldEnvironment.new()
	world.environment = env
	add_child(world)

	var key: DirectionalLight3D = DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-58.0, -38.0, 0.0)
	key.light_energy = 1.1
	# Shadows give the boss a footprint on the floor, which is what tells the
	# player where it actually IS when they are looking up at it.
	key.shadow_enabled = true
	add_child(key)


## Floor and four walls. The floor wears the game's own floor.png, tiled, so a
## duel looks like it happens inside BESTAGON rather than in a grey box -- and
## because the grid is what gives a first-person camera any sense of speed at all.
func _build_room() -> void:
	var floor_mat: StandardMaterial3D = StandardMaterial3D.new()
	floor_mat.albedo_texture = load("res://assets/sprites/floor.png") as Texture2D
	floor_mat.albedo_color = FLOOR_TINT
	floor_mat.uv1_scale = Vector3(ROOM_HALF * 0.5, ROOM_HALF * 0.5, 1.0)
	# Nearest, matching the project's texture filter. A blurred grid would be the
	# one soft thing in a game whose whole look is hard pixel edges.
	floor_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	floor_mat.roughness = 0.75

	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(ROOM_HALF * 2.0, ROOM_HALF * 2.0)
	var ground: MeshInstance3D = MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = floor_mat
	add_child(ground)

	var body: StaticBody3D = StaticBody3D.new()
	# Layer 5 = walls, mirroring the 2D layer names. 3D layers are a separate set
	# from 2D layers in Godot, so this is a readability choice, not a requirement.
	body.collision_layer = 1 << 4
	body.collision_mask = 0
	add_child(body)

	# THE FLOOR NEEDS A COLLIDER, and this is not obvious enough to leave implicit.
	# A PlaneMesh is geometry only. The first build gave the WALLS a body and left
	# the floor as a bare MeshInstance3D, so gravity did exactly what it was told
	# and the player fell out of the world -- the boss vanished upward within half
	# a second and the capture showed empty sky. Nothing errored: falling forever
	# is a perfectly valid thing for a body with nothing under it to do.
	#
	# WorldBoundaryShape3D rather than a slab: it is a half-space, so there is no
	# thickness to tunnel through at any speed and no edge to walk off if the room
	# ever grows.
	var ground_shape: CollisionShape3D = CollisionShape3D.new()
	ground_shape.shape = WorldBoundaryShape3D.new()
	body.add_child(ground_shape)

	var wall_mat: StandardMaterial3D = StandardMaterial3D.new()
	wall_mat.albedo_color = WALL_TINT
	wall_mat.roughness = 0.9

	# Four walls, built from one loop rather than four hand-placed nodes so the
	# room cannot end up asymmetric by typo.
	for i: int in 4:
		var angle: float = TAU * float(i) / 4.0
		var normal: Vector3 = Vector3(sin(angle), 0.0, cos(angle))
		var at: Vector3 = normal * ROOM_HALF + Vector3(0.0, WALL_HEIGHT * 0.5, 0.0)

		var box: BoxMesh = BoxMesh.new()
		box.size = Vector3(ROOM_HALF * 2.0, WALL_HEIGHT, 0.5)
		var panel: MeshInstance3D = MeshInstance3D.new()
		panel.mesh = box
		panel.material_override = wall_mat
		panel.position = at
		panel.rotation.y = angle
		add_child(panel)

		var shape: CollisionShape3D = CollisionShape3D.new()
		var box_shape: BoxShape3D = BoxShape3D.new()
		box_shape.size = box.size
		shape.shape = box_shape
		shape.position = at
		shape.rotation.y = angle
		body.add_child(shape)


## The boss, at duel scale. Same PolyPrism the tilted arena uses and the same side
## count, so the thing the player has been shooting at from above is recognisably
## the thing now standing in front of them -- a pentagon for THE PRISM, a hexagon
## only for NOGAXEH.
##
## Its body, phases and volleys live in DuelBoss. This scene owns the ROOM; a boss
## that grew its attack pattern inside the arena script would put two unrelated
## responsibilities in one file, and the arena would have to be edited every time
## a boss learned a new move.
func _build_boss() -> void:
	boss = DuelBoss.new()
	if boss_stats != null:
		boss.tint = boss_stats.tint
		boss.damage = boss_stats.damage
		boss.max_hp = boss_stats.max_hp
		boss.hp = boss_stats.max_hp
	boss.sides = boss_sides
	boss.name = "DuelBoss"
	add_child(boss)


func _build_player() -> void:
	player = PLAYER_SCENE.instantiate() as DuelPlayer
	player.position = Vector3(0.0, 0.2, PLAYER_START_Z)
	player.health = player_health
	add_child(player)
	# Face the boss on the first frame. Being dropped into a duel looking at a wall
	# is the kind of thing that reads as the scene having failed to load.
	player.look_at_boss(boss.global_position)
	# Bolts are parented to the ARENA, not the boss: parented to the boss they
	# would inherit its hover, its spin and its cant, so a volley would swing
	# around with the thing that fired it instead of flying straight. Same reason
	# the 2D game hands EnemyProjectile a bolt_container.
	boss.configure(self, player)
	boss.died.connect(_on_boss_died)
	player.died.connect(_on_player_died)

	# The weapon is a child of the PLAYER so it goes wherever they go, but its shots
	# are parented to the ARENA -- on the player they would inherit the body's yaw
	# and every shot already in flight would swing when the view turned.
	weapon = DuelWeapon.new()
	weapon.name = "DuelWeapon"
	if weapon_damage > 0:
		weapon.damage = weapon_damage
	player.add_child(weapon)
	weapon.configure(player, self)

	hud = DuelHud.new()
	hud.boss_tint = boss.tint
	hud.boss_title = boss_title
	add_child(hud)
	# Pushed once now, because both bars would otherwise sit empty until the first
	# hit landed -- and a boss bar that reads zero before the fight starts looks
	# like the fight is already over.
	hud.set_boss_health(boss.hp, boss.max_hp)
	hud.set_player_health(player.health.hp, player.health.max_hp)
	boss.health_changed.connect(hud.set_boss_health)
	player.health_changed.connect(hud.set_player_health)


## Stop shooting. The duel is over either way, and a weapon that kept firing into
## an empty room past the outcome banner reads as the game not having noticed.
func _end_duel() -> void:
	if is_instance_valid(weapon):
		weapon.set_process(false)
	player.capture_mouse(false)


func _on_boss_died() -> void:
	# The boss's body goes; its bolts do NOT. A volley already in the air stays
	# lethal, so killing the boss on its wind-up does not erase the shot you
	# should still have to dodge.
	if is_instance_valid(boss):
		boss.queue_free()
	_end_duel()
	hud.show_outcome(true)
	finished.emit(true)


func _on_player_died() -> void:
	_end_duel()
	hud.show_outcome(false)
	finished.emit(false)


func _process(delta: float) -> void:
	_time += delta