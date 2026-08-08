class_name DuelBoss
extends Node3D
## THE BOSS, in first person. Same fight, different bodies.
##
## KEEPS THE 2D GRAMMAR, because that grammar is the design and not an artifact of
## the camera: EVERY attack is telegraphed, the tell is a flare plus a cue, and
## nothing can damage the player until the tell has finished. boss.gd is explicit
## that untelegraphed damage violates BRIEF defect #4 -- "a run that ends without
## the player understanding why" -- and that this is the entire reason the boss
## exists rather than a bigger chaser. A duel that dropped the telegraph would be
## a different, worse fight wearing the same name.
##
## Numbers are INJECTED from the 2D boss that spawned this duel, so the Prism
## fights like the Prism and Nogaxeh like Nogaxeh. The defaults below are the
## Prism's authored values from boss.tscn, present only so the scene is loadable
## on its own for inspection.
##
## AN ARC, NOT A RING -- the one place the 2D design does not survive the camera.
## The 2D boss fires a full 360-degree ring and offsets it by half a step so a gap
## always sits where the player is standing, which makes weaving a real choice.
## Top-down, the whole ring is legible at once. In first person you can see maybe
## a third of it, so most of a ring is bolts you will never know existed and the
## gap you are supposed to read is behind you. Firing a wide ARC toward the player
## keeps the mechanic that matters -- find the gap, commit early -- and spends
## every bolt on something the player can actually see.

signal died
signal phase_changed(phase: int)
signal telegraph_started(seconds: float)

const BOLT_SCENE: PackedScene = preload("res://scenes/duel/duel_bolt.tscn")

## The Prism's authored numbers, from boss.tscn. Injected over in a real duel.
const DEFAULT_TELEGRAPH: float = 0.62
const DEFAULT_P1_INTERVAL: float = 1.75
const DEFAULT_P2_INTERVAL: float = 1.15

## Bolts per volley. Far fewer than the 2D boss's 15 and 22, because those numbers
## buy coverage of a full circle and this arc is a third of one -- matching them
## would put the same density into a third of the angle and leave no gap to find.
##
## MUST BE EVEN, and this is the whole mechanic rather than a detail.
##
## The offset that places the gap is `t = (i + 0.5) / count - 0.5`, and t is
## exactly 0 when i = count/2 - 0.5 -- which is a whole number precisely when
## count is ODD. The first pass used 9 and 13, so bolt #4 flew exactly along the
## bearing to the player and the attack did the OPPOSITE of what it was designed
## to do: instead of a gap where they were standing there was a bolt there, and
## holding still went from a valid read to the only losing answer.
##
## boss.gd gets away with an odd spread because a full 360-degree ring has no
## centre for a bolt to land on. An arc centred on the player does.
const SPREAD_P1: int = 10
const SPREAD_P2: int = 14
## Degrees the volley spans, centred on the bearing to the player. Slightly wider
## than the 78-degree camera FOV, so the edges of a volley arrive from just outside
## view and turning your head is rewarded.
const ARC_DEG: float = 108.0
## Metres per second. Slow enough to read and to dodge on reaction, which is the
## speed the whole telegraph design assumes.
const BOLT_SPEED: float = 15.0
## Bolts leave the solid's midline rather than its centre, so a volley looks like
## it came off the body instead of out of thin air.
const MUZZLE_HEIGHT: float = 0.4
## Where on the player a volley is aimed, in metres off the floor. The CHEST, not
## the eyes and not the feet: aiming at the camera means ducking is never wrong,
## and aiming at the feet means the bolts arrive under a capsule that is 1.8m tall.
const TORSO_HEIGHT: float = 1.0

## Visual identity. Cant so the cap is visible -- at eye level a prism reads as a
## rectangle regardless of side count, and the polygon is the boss's whole
## identity. See the header of the arena scene.
const CANT_DEG: float = 24.0
const SPIN: float = 0.55
const BOB_AMPLITUDE: float = 0.35
const BOB_RATE: float = 0.9
const HOVER: float = 2.6

@export var radius: float = 2.2
@export var height: float = 3.6

var telegraph: float = DEFAULT_TELEGRAPH
var p1_interval: float = DEFAULT_P1_INTERVAL
var p2_interval: float = DEFAULT_P2_INTERVAL
var damage: int = 2
var sides: int = PolyPrism.DEFAULT_SIDES
var tint: Color = Color(1.0, 0.42, 0.85)
var max_hp: int = 2400
var hp: int = 2400
## HP fractions at which the phase advances, descending. Same shape as
## Boss.phase_thresholds so a boss's phases are data in both models.
var phase_thresholds: PackedFloat32Array = PackedFloat32Array([0.5])
var phase: int = 1

## Where volleys are aimed. Injected by the arena; never reached for.
var target: Node3D

var _mesh: MeshInstance3D
var _pivot: Node3D
var _material: StandardMaterial3D
var _time: float = 0.0
var _attack_cd: float = 2.2
var _telegraph_left: float = 0.0
var _bolt_parent: Node3D


## Called by the arena before add_child, so the boss is fully described before it
## can act. Separate from _ready for the same reason Boss.configure is.
func configure(p_bolt_parent: Node3D, p_target: Node3D) -> void:
	_bolt_parent = p_bolt_parent
	target = p_target


func _ready() -> void:
	_build_body()
	position.y = HOVER


func _build_body() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = tint
	_material.metallic = 0.3
	_material.roughness = 0.26
	# gl_compatibility has no glow pass (enemy.gd), so emission is the only way the
	# solid keeps the lit-from-within look. It brightens facets; it does not bloom.
	_material.emission_enabled = true
	_material.emission = tint
	_material.emission_energy_multiplier = 0.4

	_pivot = Node3D.new()
	add_child(_pivot)
	_mesh = MeshInstance3D.new()
	_mesh.mesh = PolyPrism.build(radius, height, sides)
	_mesh.material_override = _material
	_mesh.rotation_degrees = Vector3(0.0, 0.0, CANT_DEG)
	_pivot.add_child(_mesh)


func _process(delta: float) -> void:
	_time += delta
	_pivot.rotation.y += delta * SPIN
	position.y = HOVER + sin(_time * BOB_RATE) * BOB_AMPLITUDE
	_attack(delta)


func _attack(delta: float) -> void:
	if not is_instance_valid(target):
		return
	if _telegraph_left > 0.0:
		_telegraph_left -= delta
		if _telegraph_left <= 0.0:
			_fire()
		return
	_attack_cd -= delta
	if _attack_cd <= 0.0:
		_begin_telegraph()


## The tell: the solid flares and a cue plays. Nothing can hurt the player until
## this finishes.
##
## YELLOW, not white, and that distinction is load-bearing exactly as it is in
## boss.gd: white is the hit flash, "you hurt it". This has to say the opposite.
## The cue is the same dread-swell the 2D fight uses, sized to end inside the
## window -- it was once the LEVEL-UP jingle, which taught the player that a
## reward sound precedes damage.
func _begin_telegraph() -> void:
	_telegraph_left = telegraph
	Sfx.play(&"boss_telegraph", -1.0)
	telegraph_started.emit(telegraph)
	var t: Tween = create_tween()
	t.tween_property(_material, "emission", Enemy.TELEGRAPH, telegraph * 0.7)
	t.tween_property(_material, "emission", tint, telegraph * 0.3)


## One volley: an arc of bolts across the player's bearing, with a gap where they
## are standing.
##
## The half-step offset is lifted straight from boss.gd and is the reason the
## attack is a decision rather than a coin flip: aiming a bolt AT the player would
## mean the safe answer is always "keep moving", while putting a GAP where they
## stand means holding still is safe and the volley has to be read.
func _fire() -> void:
	# One cue per VOLLEY, not per bolt: a dozen simultaneous plays would eat the
	# whole voice pool and read as one blast anyway.
	Sfx.play(&"bolt", -9.0)
	var count: int = SPREAD_P1 if phase == 1 else SPREAD_P2
	var origin: Vector3 = global_position + Vector3(0.0, MUZZLE_HEIGHT, 0.0)
	# AIM AT THE TORSO, IN 3D. The first version flattened the bearing to the
	# horizontal plane and fired level -- which, from a boss hovering at 2.6m plus
	# a 0.4m muzzle, put every bolt at 3.0m altitude travelling flat. The player
	# capsule tops out at 1.8m, so the entire volley sailed over their head and the
	# attack could not land at all. It looked completely correct on a contact
	# sheet: nine bolts, fanned, on their way.
	#
	# So the base direction keeps its downward component and the fan rotates AROUND
	# Y, which spreads the volley horizontally while every bolt still descends onto
	# the player.
	var aim_at: Vector3 = target.global_position + Vector3(0.0, TORSO_HEIGHT, 0.0)
	var base_dir: Vector3 = (aim_at - origin).normalized()
	var span: float = deg_to_rad(ARC_DEG)
	for i: int in count:
		# +0.5 puts a bolt either side of the bearing rather than one down the
		# middle, which is what leaves the gap on the player.
		var t: float = (float(i) + 0.5) / float(count) - 0.5
		var dir: Vector3 = base_dir.rotated(Vector3.UP, t * span)
		var bolt: DuelBolt = BOLT_SCENE.instantiate()
		bolt.setup(dir * BOLT_SPEED, damage)
		_bolt_parent.add_child(bolt)
		bolt.global_position = origin
	_attack_cd = p1_interval if phase == 1 else p2_interval


## Damage entry point. Mirrors Boss.take_hit: no execute threshold and no
## knockback, because an instant-kill on a boss would delete the fight the run is
## built around and shoving it would undo the telegraphed positioning the whole
## fight rests on.
func take_hit(amount: int) -> void:
	if hp <= 0:
		return
	hp = maxi(0, hp - amount)
	_flash()
	if hp <= 0:
		died.emit()
		return
	# `while`, not `if`: one very large hit can cross two thresholds at once, and a
	# skipped phase would skip whatever that phase was supposed to set up.
	while phase - 1 < phase_thresholds.size() \
			and float(hp) <= float(max_hp) * phase_thresholds[phase - 1]:
		_advance_phase()


## WHITE, because white means "you damaged it" in this game and the duel does not
## get its own vocabulary.
func _flash() -> void:
	var t: Tween = create_tween()
	t.tween_property(_material, "albedo_color", Color.WHITE, 0.04)
	t.tween_property(_material, "albedo_color", tint, 0.14)


func _advance_phase() -> void:
	phase += 1
	_attack_cd = minf(_attack_cd, 1.0)
	phase_changed.emit(phase)
