class_name Boss
extends Enemy
## THE PRISM — a hexagonal core orbited by three shards.
##
## Extends Enemy on purpose. To the rest of the game a boss must BE a very large
## enemy: the weapon's nearest-target query and the projectile's hit check both
## cast to Enemy, so anything that merely resembles one is untargetable AND
## invulnerable. (It shipped that way for one build; the boss spawned on time and
## simply could not be killed.) Inheriting means zero special cases in weapon,
## projectile, Main, the death burst, or the kill counter.
##
## EVERY attack is telegraphed — shards flare and a cue plays before anything can
## damage you. Untelegraphed damage violates BRIEF defect #4 ("a run that ends
## without the player understanding why"), which is the entire reason the boss
## exists rather than a bigger chaser.
##
## Two phases, not three. Deliberately scoped to ship finished, not ambitious.

signal phase_changed(phase: int)

const PROJECTILE_SCENE: PackedScene = preload("res://scenes/enemies/enemy_projectile.tscn")

const SHARD_COUNT: int = 3
const SHARD_SPIN: float = 1.15
const DASH_SPEED: float = 250.0
const DASH_TIME: float = 0.55

@export var boss_stats: EnemyStats

## Attack shape is per-scene, not per-class: the Shard is the same fight at a
## smaller scale, so it reuses this script with gentler numbers rather than
## getting a script of its own.
@export_group("Attack")
## Long enough to actually react to at player move speed.
@export var telegraph: float = 0.62
@export var p1_interval: float = 1.75
@export var p2_interval: float = 1.15
@export var spread_p1: int = 15
@export var spread_p2: int = 22
@export var bolt_speed: float = 122.0
@export var shard_orbit: float = 80.0

## HP FRACTIONS at which the phase advances, in descending order. The Prism keeps
## its single threshold, so its two-phase fight is unchanged; Nogaxeh sets two and
## gets three phases. Exported so a boss's shape is data, like everything else.
@export var phase_thresholds: PackedFloat32Array = PackedFloat32Array([0.5])

var phase: int = 1
## While true the boss cannot be damaged at all. Nogaxeh raises this in phases 1
## and 4 until its escorts are dead; nothing else uses it. The indicator is not
## optional — see _blocked_feedback and Hud.set_boss_shielded.
var invulnerable: bool = false
## Set by the director for a Prism spawned as one of Nogaxeh's minions. It exists
## for the HUD: the boss bar is titled NOGAXEH, so counting escort HP into it made
## the bar drain while the mirror sat untouched behind its shield, and a playtester
## read that as "he was not invulnerable" (2026-08-03). An escort is still a boss
## in every other respect — it counts for `bosses_alive`, kills, XP and drops.
var is_escort: bool = false

var _block_cd: float = 0.0
var _shards: Array[Sprite2D] = []
var _spin: float = 0.0
var _attack_cd: float = 2.2
var _telegraph_left: float = 0.0
var _dash_left: float = 0.0
var _dash_dir: Vector2 = Vector2.ZERO
var _ring_offset: float = 0.0


## Called by the director before add_child. Separate from Enemy.setup so the
## director never has to know the boss's stats resource.
func configure(p_target: Node2D, hp_mult: float = 1.0, elite: bool = false) -> void:
	setup(boss_stats, p_target, hp_mult, elite)


## Break the phase lock on multi-boss events. Review finding 13: every boss of an
## event is instantiated in ONE physics tick with an identical `_attack_cd`, and
## the intervals are identical too, so they telegraphed and fired on the same
## frame forever — 44 bolts in a single tick at 5:00, 88 at 10:00, 132 at 15:00,
## plus N copies of the same telegraph cue summing far louder than the authored
## -6 dB. Offsetting the FIRST cooldown separates them permanently.
func stagger(seconds: float) -> void:
	_attack_cd += seconds


func _ready() -> void:
	super._ready()
	_build_shards()


func _build_shards() -> void:
	for i: int in SHARD_COUNT:
		var shard := Sprite2D.new()
		shard.texture = visual.texture
		shard.modulate = stats.tint
		# Proportional to the BODY, not absolute: an absolute scale here meant
		# resizing a boss silently changed how big its shards looked relative to
		# it. 0.385 reproduces the ratio the original 0.42 had at the old size.
		shard.scale = visual.scale * 0.385
		shard.z_index = 1
		add_child(shard)
		_shards.append(shard)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target):
		return
	_block_cd = maxf(0.0, _block_cd - delta)
	_spin += delta * SHARD_SPIN
	_orbit_shards()
	_move(delta)
	_attack(delta)


func _orbit_shards() -> void:
	for i: int in _shards.size():
		var shard: Sprite2D = _shards[i]
		if is_instance_valid(shard):
			shard.position = Vector2.RIGHT.rotated(
					_spin + TAU * float(i) / float(SHARD_COUNT)) * shard_orbit


func _move(delta: float) -> void:
	if _dash_left > 0.0:
		_dash_left -= delta
		velocity = _dash_dir * DASH_SPEED
	elif _telegraph_left > 0.0:
		velocity = Vector2.ZERO  # planting is part of the tell
	else:
		velocity = (target.global_position - global_position).normalized() * stats.speed
	move_and_slide()


func _attack(delta: float) -> void:
	if _telegraph_left > 0.0:
		_telegraph_left -= delta
		if _telegraph_left <= 0.0:
			_fire()
		return
	_attack_cd -= delta
	if _attack_cd <= 0.0:
		_begin_telegraph()


## The tell: shards flare to white and a cue plays. Nothing can hurt the player
## until this finishes. The cue is a dread-swell sized to end inside the
## telegraph window — it used to be the LEVEL-UP jingle, which taught the
## player that reward-sound precedes damage. Exactly backwards.
func _begin_telegraph() -> void:
	_telegraph_left = telegraph
	Sfx.play(&"boss_telegraph", -1.0)
	for shard: Sprite2D in _shards:
		if not is_instance_valid(shard):
			continue
		var t: Tween = create_tween()
		# Yellow, not white — same reason as Enemy.TELEGRAPH (finding 17). White
		# is the hit flash: "you hurt it". This has to say the opposite.
		t.tween_property(shard, "modulate", Enemy.TELEGRAPH, telegraph * 0.7)
		t.tween_property(shard, "modulate", stats.tint, telegraph * 0.3)


func _fire() -> void:
	# One cue per VOLLEY, not per bolt — 15+ simultaneous plays would eat the
	# whole voice pool and read as one loud blast anyway.
	Sfx.play(&"bolt", -9.0)
	var count: int = spread_p1 if phase == 1 else spread_p2
	# Offset the ring by half a step off the player's bearing, so a gap always
	# sits where they are standing and weaving is a real choice, not a coin flip.
	var base: float = (target.global_position - global_position).angle() + _ring_offset
	_ring_offset += PI / float(count)
	for i: int in count:
		var angle: float = base + TAU * (float(i) + 0.5) / float(count)
		var bolt: EnemyProjectile = PROJECTILE_SCENE.instantiate()
		bolt.setup(Vector2.RIGHT.rotated(angle) * bolt_speed, damage)
		bolt.global_position = global_position
		_bolt_parent().add_child(bolt)
	if phase >= 2:
		_dash_dir = (target.global_position - global_position).normalized()
		_dash_left = DASH_TIME
	_attack_cd = p1_interval if phase == 1 else p2_interval


func take_hit(amount: int, execute_below: float = 0.0,
		from: Vector2 = Vector2.INF) -> int:
	if invulnerable:
		_blocked_feedback()
		# Absorbed NOTHING. The shield deflected the shot, so a Ricochet keeps
		# its full damage for the next target instead of spending it on a boss
		# it was never allowed to hurt.
		return 0
	var was_alive: bool = hp > 0
	# Bosses ignore Executioner — an instant-kill threshold on a boss would
	# delete the fight the run is built around. They also ignore knockback:
	# shoving the boss around would undo its telegraphed positioning, which is
	# the whole basis of the fight being readable.
	var absorbed: int = super.take_hit(amount, 0.0, Vector2.INF)
	if not was_alive or hp <= 0:
		return absorbed
	# `while`, not `if`: one very large hit can cross two thresholds at once, and
	# a skipped phase would skip whatever that phase was supposed to set up.
	while phase - 1 < phase_thresholds.size() \
			and float(hp) <= float(max_hp) * phase_thresholds[phase - 1]:
		_advance_phase()
	return absorbed


## Advance a phase for a reason that is NOT damage. Nogaxeh's phase 1 ends when
## its escorts die, and it is invulnerable for the whole of that phase — so its
## HP never moves and an HP threshold could never fire. Public because only the
## director knows when that condition is met.
func force_phase() -> void:
	if phase - 1 < phase_thresholds.size():
		_advance_phase()


## Phase transition. Subclasses override `_on_phase`, never this.
func _advance_phase() -> void:
	phase += 1
	_attack_cd = minf(_attack_cd, 1.0)
	_on_phase(phase)
	phase_changed.emit(phase)


## Per-boss reaction to entering a phase. The Prism detaches its shards at 2, so
## the arena gets busier exactly as the core gets more aggressive. Nogaxeh
## overrides this to run a three-phase fight.
func _on_phase(new_phase: int) -> void:
	if new_phase == 2:
		detach_shards()


## Where the still-orbiting shards are, as offsets from the core in arena pixels.
##
## Public and read-only so ArenaStage can give each shard a body in 3D without
## re-deriving the orbit. Re-deriving it would mean a second copy of the spin
## rate, the count and the radius, and three copies of `_spin` drifting apart is
## how the solid ends up orbited by shards that are not where its own shards are.
##
## Returns empty once they detach at phase 2, which is exactly right: the 3D
## shards should vanish on the same frame the sprites do.
func shard_offsets() -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	for shard: Sprite2D in _shards:
		if is_instance_valid(shard):
			out.append(shard.position)
	return out


## How wide one shard is, in arena pixels. Derived from the same visual scale the
## sprite uses rather than from a constant, so resizing a boss resizes both its
## sprite shards and its solid ones together.
func shard_pixel_size() -> float:
	return stats.size * 0.385 if stats != null else 0.0


func detach_shards() -> void:
	for shard: Sprite2D in _shards:
		if is_instance_valid(shard):
			shard.queue_free()
	_shards.clear()


## What a hit on an INVULNERABLE boss looks and sounds like.
##
## Deliberately NOT the white hit-flash: white means "you damaged it", and a
## player who cannot tell "shielded" from "the game is broken" is BRIEF defect
## #4. A flat grey pulse and a dull, quiet thud say "blocked" with no text at
## all. Rate-limited, or a four-weapon build would strobe it every frame.
func _blocked_feedback() -> void:
	if _block_cd > 0.0:
		return
	_block_cd = 0.15
	Sfx.play(&"hit", -19.0, 0.0)
	var t: Tween = create_tween()
	t.tween_property(visual, "modulate", Color(0.5, 0.5, 0.58), 0.05)
	t.tween_property(visual, "modulate", stats.tint, 0.16)
