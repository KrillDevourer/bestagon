class_name EnemyStats
extends Resource
## One .tres per enemy type — new enemies are content, not code.

## How a type behaves.
##
## RANGED is what makes standing still stop working: playtest 2026-08-02 found
## the player could hold position all run, because every enemy walked into the
## auto-weapon's fire. CHARGE punishes the opposite habit — sitting in an open
## lane — by committing to a straight dash it cannot steer out of.
enum Behavior { CHASE, RANGED, CHARGE }

@export var id: StringName
@export var behavior: Behavior = Behavior.CHASE
@export var max_hp: int = 3
@export var speed: float = 55.0
@export var damage: int = 1
@export var xp_value: int = 3
@export var tint: Color = Color(0.9, 0.3, 0.3)
@export var size: float = 14.0

## Per-type silhouette. Null keeps the scene's default (the Drifter square).
@export var sprite: Texture2D

## Rotate the sprite to point along travel. For DIRECTIONAL silhouettes only —
## the Ram's wedge is drawn pointing up and is unreadable at any other angle. A
## shape that turns is also the cheapest possible "this one is aimed at you".
## Radially symmetric types (square, octagon, diamond) leave this false: spinning
## them would read as a bug.
##
## THE DART TURNED THIS OFF on 2026-08-03 and TURNED IT BACK ON the same day.
## Both halves are worth keeping, because the second overrules the first.
##
## OFF: playtest said "orange dart looks more like a projectile", and a 1:1 crop
## confirmed it read as a tracer round even with the glow on. The diagnosis was
## that a small pointed shape ROTATED ALONG ITS VELOCITY is the visual grammar of
## a bullet, so the fix was to stop rotating it — reserving facing for shapes
## whose rotation is a TELEGRAPH (the Ram's wind-up).
##
## ON: the next playtest reported the opposite — "darts no longer fly pointing
## towards you" — because a needle silhouette frozen at a fixed angle reads as
## BROKEN, which is worse than reading as ammunition. The diagnosis above had the
## wrong culprit: the problem was the SHAPE, not the rotation. Rotation is the
## only thing making a needle look deliberate.
##
## So the Dart faces travel again and is separated from bolts by MASS instead:
## +20% body size and +20% glow (`glow_scale`), on the reasoning that a bullet is
## small and a body is not. Radially symmetric types (square, octagon, diamond)
## still leave this false — spinning them would read as a bug.
@export var faces_travel: bool = false

## Multiplies the halo's alpha. The halo's SIZE already follows body size, so this
## is the separate axis: how brightly a type burns for its size, not how big the
## glow is. Exists for the Dart, which needs to out-read a screen full of bolts
## that share its hue — see faces_travel.
@export var glow_scale: float = 1.0

## Per-type scene, as a PATH rather than a PackedScene. Empty uses the spawner's
## default. Set this when a type needs BEHAVIOUR the shared Enemy script lacks —
## the Shard is a shrunken Prism, so it wants boss.gd, not a new archetype.
##
## A path, not a typed PackedScene, because an authoring tool that only wants to
## write numbers would otherwise have to LOAD the whole gameplay scene graph —
## and that chain reaches player.gd, which legitimately uses autoloads that do
## not exist in a `-s` tool run. Autoloads in node scripts are fine; pulling node
## scripts into a data tool is not.
@export_file("*.tscn") var scene_path: String = ""

## Maximum of this type alive at once. 0 = unlimited. Exists because a type can
## be fun in small numbers and miserable in a swarm.
@export var max_alive: int = 0

@export_group("Death payload")
## What this leaves behind when it dies (the Splitter). A path, for the same
## reason `scene_path` is one.
@export_file("*.tres") var split_into_path: String = ""
@export var split_count: int = 0

@export_group("Ranged")
## RANGED only: the distance it tries to hold, and how often it fires.
@export var attack_range: float = 190.0
@export var attack_interval: float = 2.4

## OVERRIDE, not the source of truth. 0 means "use the law" — see BoltProfile.
##
## Bullet speed is DERIVED from the enemy's own mass now, because authoring it by
## hand had already gone wrong in the shipped data and nobody had noticed:
## `lancer` (4 HP, 66 speed) fired at 140 while `lancer_heavy` (9 HP, 58 speed)
## fired at 165. The heavier, slower, more deliberate-looking enemy had the
## FASTER bullet — exactly backwards from what its silhouette promises, and the
## kind of mistake that is invisible in a .tres and unmissable in play.
##
## Left as an override rather than deleted so a future enemy whose whole identity
## is a wrong-feeling bullet can still have one. It has to be a deliberate
## exception to a rule, not the absence of a rule.
@export var bolt_speed: float = 0.0

@export_group("Charge")
## CHARGE only. Telegraph, then a fast straight dash, then a recovery it cannot
## steer through — the recovery IS the counterplay. A charger that could turn
## mid-dash would be unavoidable; one that never committed would just be a
## slightly faster chaser.
@export var charge_range: float = 210.0
@export var charge_telegraph: float = 0.65
@export var charge_speed: float = 430.0
@export var charge_time: float = 0.42
@export var charge_recover: float = 0.9

var _scene_cache: PackedScene
var _split_cache: Resource
var _bolt_cache: BoltProfile


## The bullet this type fires. Derived from its own HP and speed, so every enemy
## — including ones not designed yet — gets a bullet that matches how it reads
## without anybody choosing numbers for it. See BoltProfile for the two laws.
##
## Cached because it is asked for on every shot and the answer cannot change: it
## depends only on authored stats, and a Resource's authored stats do not move at
## runtime. The difficulty HP multiplier deliberately does NOT feed it — a wave-6
## Lancer is the same Lancer with more health, and having its bullet quietly grow
## heavier as the run went on would break the promise that bullet size means one
## fixed thing.
func bolt_profile() -> BoltProfile:
	if _bolt_cache == null:
		_bolt_cache = BoltProfile.derive(max_hp, speed)
		if bolt_speed > 0.0:
			_bolt_cache.speed = bolt_speed
	return _bolt_cache


## HP this type spawns with under a difficulty multiplier. Pure, so the scaling
## curve is testable without instancing an Enemy. Never returns less than 1 —
## a rounding-down multiplier must never produce an unkillable 0-HP enemy.
func effective_hp(hp_mult: float) -> int:
	return maxi(1, roundi(max_hp * hp_mult))


## Resolved once, at runtime, where the autoloads actually exist.
func resolve_scene() -> PackedScene:
	if scene_path.is_empty():
		return null
	if _scene_cache == null:
		_scene_cache = load(scene_path) as PackedScene
	return _scene_cache


func resolve_split() -> EnemyStats:
	if split_into_path.is_empty():
		return null
	if _split_cache == null:
		_split_cache = load(split_into_path)
	return _split_cache as EnemyStats
