class_name Player
extends CharacterBody2D
## Movement, contact damage intake, and the stats/health the run mutates.
## Call down, signal up: Main listens to our signals; we never reach up.

signal died
signal health_changed(hp: int, max_hp: int)
## Second Wind fired. Main clears the screen — the player does not know how.
signal second_wind(at: Vector2)
## Emitted only when damage actually LANDS -- not on a blocked or shielded
## hit, which must not be rewarded with a free crowd clear.
signal hurt(at: Vector2)
## Fired on a successful dash so Main can juice it without the player knowing how.
signal dashed(at: Vector2)

## THE DASH — earned by beating the Prism (MetaState.UNLOCK_DASH).
##
## Deliberately absent from the first five minutes. The prime-directive run a
## stranger plays never has it, so BRIEF defect #1 ("floaty or unresponsive")
## cannot regress in the part of the game that decides the restart click. It
## arrives exactly when the arena starts filling with bullets on the road to
## Nogaxeh, because bullet hell without a dodge is arbitrary rather than hard.
##
## The i-frames ARE the feature. A dash that only moves you quickly is a movement
## upgrade; a dash that passes THROUGH a bullet is a verb, and it is what turns a
## dense pattern from a wall into a puzzle. The window is deliberately longer
## than the travel so the dodge forgives a slightly early press.
const DASH_SPEED_MULT: float = 3.6
const DASH_TIME: float = 0.15
const DASH_IFRAMES: float = 0.26
const DASH_COOLDOWN: float = 1.0

## Weapon data. Everything but the blaster is gated behind a meta unlock:
## orbital = first victory, scattergun = 1000 total kills, lance = surviving to
## the double boss. Each milestone hands over a new way to play, not a number.
const BLASTER_WEAPON: WeaponResource = preload("res://resources/weapons/blaster.tres")
const ORBITAL_WEAPON: WeaponResource = preload("res://resources/weapons/orbital.tres")
const SCATTER_WEAPON: WeaponResource = preload("res://resources/weapons/scattergun.tres")
const LANCE_WEAPON: WeaponResource = preload("res://resources/weapons/lance.tres")

@export var stats: Stats

var health: Health
## Temporary power-up effects. Never written into Stats — a six-second buff
## leaking into a permanent modifier would be silent and unbounded.
var buffs: BuffState = BuffState.new()
## Second Wind is once per RUN. Spending it here rather than in Stats keeps
## the permanent modifiers free of run-scoped state.
var _second_wind_spent: bool = false
var _aegis_cd: float = 0.0
## Dash state. `_can_dash` stays false until the unlock is applied, so an
## un-earned dash costs nothing but a bool check per frame.
var _can_dash: bool = false
var _dash_left: float = 0.0
var _dash_cd: float = 0.0
var _dash_dir: Vector2 = Vector2.RIGHT
## What last landed a hit. Read by the game-over screen so a run can end with the
## player understanding why — BRIEF defect #4, review finding 16.
var last_hit_source: StringName = &""
var last_hit_by: StringName = &""
## Pause-safe clock: accumulates physics time, used for i-frame windows.
var _time: float = 0.0
## Decaying impulse that rides on top of input — see _throw_clear_of.
var _knockback: Vector2 = Vector2.ZERO

@onready var hurtbox: Area2D = $Hurtbox
@onready var magnet: Area2D = $Magnet
@onready var magnet_shape: CollisionShape2D = $Magnet/CollisionShape2D
@onready var visual: Sprite2D = $Visual
@onready var core: Sprite2D = %Core
@onready var shield: Sprite2D = %Shield
@onready var trail: Line2D = %Trail
@onready var jet_a: Line2D = %JetA
@onready var jet_b: Line2D = %JetB
@onready var weapon: Weapon = $Weapon
@onready var scattergun: Weapon = $Scattergun
@onready var lance: LanceWeapon = $Lance
@onready var orbitals: OrbitalWeapon = $Orbitals
@onready var camera: GameCamera = $Camera2D


func _ready() -> void:
	health = Health.new(stats.max_hp)
	health.changed.connect(func(hp: int, max_hp: int) -> void: health_changed.emit(hp, max_hp))
	health.died.connect(_on_died)
	weapon.stats = stats
	weapon.buffs = buffs
	weapon.resource = BLASTER_WEAPON
	scattergun.stats = stats
	scattergun.buffs = buffs
	lance.stats = stats
	lance.buffs = buffs
	magnet.area_entered.connect(_on_magnet_area_entered)
	refresh_from_stats()
	health_changed.emit(health.hp, health.max_hp)


func _on_magnet_area_entered(area: Area2D) -> void:
	if area is XpGem:
		(area as XpGem).attract(self)


func _physics_process(delta: float) -> void:
	_time += delta
	for expired: StringName in buffs.tick(delta):
		if expired == BuffState.SHIELD:
			Sfx.play(&"shield_off", -6.0)
	health.shielded = buffs.has(BuffState.SHIELD)
	_tick_aegis(delta)
	var dir: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if dev_autopilot:
		dir = Vector2.RIGHT.rotated(_time * 1.3)
	_tick_dash(delta, dir)
	if _dash_left > 0.0:
		velocity = _dash_dir * stats.speed() * DASH_SPEED_MULT
	else:
		velocity = dir * stats.speed()
	# Applied last, so input owns velocity and the throw-clear rides on top of it —
	# the same shape Enemy uses for its knockback.
	if _knockback.length_squared() > 1.0:
		velocity += _knockback
		_knockback = _knockback.lerp(Vector2.ZERO, minf(1.0, KNOCKBACK_DECAY * delta))
	else:
		_knockback = Vector2.ZERO
	move_and_slide()
	_update_motion_visual(delta)
	_check_contact_damage()
	_update_invuln_visual()


## Main calls this once after _ready, and again whenever a milestone fires
## mid-run. Unlocks are passed DOWN rather than read from the Meta autoload:
## reaching up couples the player scene to save state and makes the whole scene
## chain uncompilable in a tool script (authoring the Shard died on "Identifier
## not found: Meta"). Same rule as the Resources.
##
## Since M7.3 this hands over exactly one thing: the DASH. Weapons are no longer
## delivered by an unlock — the unlock puts their card into the draft pool, and
## the card hands the weapon over. The dash stays here because it is a verb with
## no card: it arrives the moment it is earned, including mid-run on Continue.
func apply_unlocks(unlocks: Array[StringName]) -> void:
	_can_dash = unlocks.has(MetaState.UNLOCK_DASH)


## Dash cooldown, window, and the press that starts one. Kept separate from
## _physics_process so the movement line above stays a single readable
## assignment — `velocity` is still never smoothed.
func _tick_dash(delta: float, dir: Vector2) -> void:
	_dash_cd = maxf(0.0, _dash_cd - delta)
	if _dash_left > 0.0:
		_dash_left -= delta
		return
	if not _can_dash or _dash_cd > 0.0 or not Input.is_action_just_pressed(&"dash"):
		return
	# Dash along input; standing still dashes the way the sprite is already
	# stretched, so a neutral-stick dash never fires in a direction the player
	# had no way to predict.
	_dash_dir = dir.normalized() if dir.length_squared() > 0.01 \
			else Vector2.RIGHT.rotated(visual.rotation)
	_dash_left = DASH_TIME
	_dash_cd = DASH_COOLDOWN
	health.grant_invuln(_time, DASH_IFRAMES)
	camera.add_trauma(0.16)
	Sfx.play(&"dash", -9.0)
	dashed.emit(global_position)


## True only while the dash is MOVING — deliberately not the whole i-frame
## window, which outlasts it (DASH_IFRAMES 0.26 against DASH_TIME 0.15).
##
## That gap is the difference between a dash that saves you and a dash that
## deflects. The i-frames are generous on purpose: a dash that ends next to a
## bullet should still spare you, because punishing a correct escape by two
## frames is the kind of death BRIEF defect #4 is about. Deflection cannot be
## that generous. If it used the same window every dash would deflect, and a
## parry that happens whether or not you aimed it is not a parry.
func is_deflecting() -> bool:
	return _dash_left > 0.0


## Which way the current dash is going. Public because a deflected bolt leaves
## along it: sending the bolt back at whoever fired it sounds right and plays
## badly, since the shooter is usually the one enemy already at a safe distance.
## Aiming it with the dash makes the player pick the target, which is the whole
## reason it is a skill rather than a refund.
func dash_direction() -> Vector2:
	return _dash_dir


## True while the dash is on cooldown, plus how far through it is (0..1). The HUD
## needs both: a dash you cannot see the cooldown of is a dash you spam blindly.
func dash_ready_fraction() -> float:
	if not _can_dash:
		return -1.0
	return 1.0 if _dash_cd <= 0.0 else 1.0 - (_dash_cd / DASH_COOLDOWN)


## How many weapons are actually firing. The Run Director scales boss HP by this,
## because boss HP previously scaled by EVENT INDEX ALONE: a first-timer with the
## blaster and a returning player with four stacked weapons fought the identical
## 1800 HP. One number cannot serve profiles that are 4x apart in DPS, and the
## measured result was a seven-second "climax".
##
## Weapon count, not a DPS estimate: it is discrete, known the instant the boss
## spawns, and cannot drift as upgrades change. Trash HP deliberately does NOT
## use this — enemies that scale to your power read as the game cheating, while a
## boss that does reads as the boss rising to meet you.
##
## Since M7.3 this reads the RUN's drafts rather than the profile's unlocks, so
## it finally measures what it always claimed to: weapons in this run.
func active_weapon_count() -> int:
	return 1 + stats.drafted_weapons.size()  # the blaster is never drafted


## Re-read anything derived from stats. Main calls this after every upgrade —
## which is also when a weapon can arrive, so the weapon wiring lives here rather
## than in a second entry point that a future card could forget to call.
func refresh_from_stats() -> void:
	var drafted: Array[StringName] = stats.drafted_weapons
	orbitals.setup(stats, ORBITAL_WEAPON, drafted)
	scattergun.configure(SCATTER_WEAPON, drafted)
	lance.configure(LANCE_WEAPON, drafted)
	var circle: CircleShape2D = magnet_shape.shape
	circle.radius = stats.magnet_radius
	orbitals.refresh()


func _check_contact_damage() -> void:
	if health.is_invulnerable(_time):
		return
	for body: Node2D in hurtbox.get_overlapping_bodies():
		if body is Enemy:
			var enemy: Enemy = body as Enemy
			# Remember WHAT, not just how. BRIEF defect #4 is a run that ends
			# without the player understanding why, and "contact" alone does not
			# answer it — "a Ram ran you down" does.
			if enemy.stats != null:
				last_hit_by = enemy.stats.id
			if apply_damage(enemy.damage, &"contact"):
				if enemy is Boss:
					_throw_clear_of(enemy.global_position)
				break


## Separation from a BOSS, applied to the player instead of to the boss.
##
## Main's hurt-shove throws the crowd off you when you take a hit, which is what
## gives the i-frames a visible meaning. It cannot do that here: Enemy.shove
## scales by body size (KNOCKBACK_REFERENCE_SIZE / stats.size), so Nogaxeh at size
## 88 receives 13/88 of it — 11 px against a 146 px mirror dash — and Boss.take_hit
## deliberately ignores knockback anyway, because shoving a boss around would undo
## the telegraphed positioning the whole fight is read from.
##
## So the push has to come from the other side. Playtest 2026-08-03: Nogaxeh
## touched the player and "it's like he was stuck with me, couldn't get away from
## him anymore and he just killed me" — i-frames lapsing while still inside his
## body, over and over, until the run ended. That is the same "enemies just latch
## on weirdly" defect the hurt-shove was added to fix; it simply never reached
## anything boss-sized.
##
## FIRST ESTIMATE, expected to move after the next playtest: 180 px is enough to
## leave his body but deliberately NOT enough to beat a committed dash. Escaping a
## boss should still cost you the dash you earned at 5:00.
## 180 -> 260 and a grace window added, 2026-08-03. Distance alone was never the
## whole fix: the throw only fires when damage LANDS, so the boss was free to
## re-close during the i-frame window and be touching again the moment it
## lapsed. Chain-hit, over and over, which is what "he just killed me" was.
##
## The grace makes the throw mean something — you cannot be contact-damaged
## again while you are still being thrown clear. `grant_invuln` takes the MAX of
## the windows, so this can only ever extend the i-frames a hit already bought,
## never shorten them.
##
## This mattered more after the same day's balance cut: player DPS is down ~76%,
## so every boss fight is ~4x longer and offers ~4x the chances to be latched.
const BOSS_CONTACT_KNOCKBACK: float = 260.0
const BOSS_CONTACT_GRACE: float = 0.35
const KNOCKBACK_DECAY: float = 9.0


func _throw_clear_of(from: Vector2) -> void:
	health.grant_invuln(_time, BOSS_CONTACT_GRACE)
	var away: Vector2 = global_position - from
	# Dead centre inside the body: any direction beats staying welded, and picking
	# one at random keeps it from always resolving the same way.
	if away.length_squared() <= 0.01:
		away = Vector2.RIGHT.rotated(randf() * TAU)
	# `pixels * DECAY` is the initial speed whose exponential decay integrates to
	# `pixels` of travel — same formulation as Enemy.shove, so the number in the
	# constant is the distance it actually moves you.
	_knockback = away.normalized() * BOSS_CONTACT_KNOCKBACK * KNOCKBACK_DECAY


## Aegis: a free shield on a timer. Runs only once the upgrade sets an interval.
func _tick_aegis(delta: float) -> void:
	if stats.aegis_interval <= 0.0:
		return
	_aegis_cd -= delta
	if _aegis_cd <= 0.0:
		_aegis_cd = stats.aegis_interval
		buffs.grant(BuffState.SHIELD, 2.0)
		Sfx.play(&"shield_on", -10.0)


## Drop any i-frames currently running. Only NOGAXEH's detonation uses this: the
## blast is the finale of a two-minute fight, and surviving it because a bolt
## happened to clip you half a second earlier is an accident, not a dodge.
func clear_invuln() -> void:
	health.clear_invuln()


## End the run outright, for a cause that has already been decided elsewhere.
##
## ONE caller: a lost first-person duel. That fight runs on its own Health seeded
## from this one, so THIS object's `died` never fired and the run still has to end
## the way every other death ends. Routed through the same handler as an ordinary
## death rather than reimplementing the teardown, because a game with two endings
## has two endings to keep in agreement.
##
## Deliberately NOT apply_damage: that is gated by i-frames and by Second Wind, and
## either of them silently refusing would leave a player standing in an arena they
## have already lost.
func kill(source: StringName) -> void:
	if health.hp <= 0:
		return
	last_hit_by = source
	last_hit_source = source
	health.set_hp(0)
	_on_died()


## Public damage entry point. Contact damage and enemy projectiles both come
## through here so i-frames, the hurt cue and screenshake can never disagree.
## Returns true if the damage actually landed.
func apply_damage(amount: int, source: StringName = &"unknown") -> bool:
	# Second Wind: survive the hit that would end the run, once. Checked BEFORE
	# the damage lands so there is no frame where hp is 0 and death has fired.
	if stats.second_wind and not _second_wind_spent and amount >= health.hp 			and not health.is_invulnerable(_time) and not health.shielded:
		_second_wind_spent = true
		buffs.grant(BuffState.SHIELD, 2.5)
		camera.add_trauma(1.0)
		# The death cue INTO shield_on: "that should have killed you" resolving
		# into "you are protected" — the whole upgrade in two sounds.
		#
		# Review finding 28: both fired on the SAME FRAME, which does not play the
		# sequence, it plays a chord — and an inverted one, since shield_on ends
		# ~0.35s in while the death cue runs long. The delay puts the shield on
		# the death cue's tail, which is what was authored.
		Sfx.play(&"death", -4.0)
		_play_after(0.42, &"shield_on", -4.0)
		second_wind.emit(global_position)
		return false
	if not health.take_damage(amount, _time):
		return false
	last_hit_source = source
	Telemetry.event(&"damage", {"amt": amount, "hp": health.hp,
			"max_hp": health.max_hp, "src": String(source)})
	Sfx.play(&"hurt")
	camera.add_trauma(0.5)
	# AFTER the shield/i-frame guards above, so a hit that was absorbed does not
	# also hand out a free crowd clear.
	hurt.emit(global_position)
	return true


## FLUIDITY — VISUAL LAYER ONLY.
##
## `velocity` is assigned straight from input above and is NEVER smoothed.
## Acceleration, inertia and momentum are precisely how BRIEF defect #1 ("floaty
## or unresponsive movement") gets manufactured. Playtest 2026-08-02 confirmed the
## input model is not the problem — the complaint was "inert and boring", not
## late or slippery — so none of them appear here. Everything below acts on the
## SPRITES and cannot cost a single frame of input response.
##
## The previous version stretched the body along its travel axis. The human's
## reaction was unambiguous: "I dislike that it thins out when moving. I would
## rather it keeps its beautiful hexagonal shape." THE BODY NEVER DEFORMS. Do not
## reintroduce scale on `visual` under any circumstances.
##
## That rules out almost everything, because a hexagon cannot express motion by
## rotating either — six-fold symmetry means 60 degrees is identical to 0, so
## banking and lean are invisible on this shape. What is left is breaking the
## symmetry FROM THE INSIDE (the core lags) and drawing motion OUTSIDE the
## silhouette (the trail). Those are the two mechanisms below.

## Core lag. How far the core may slide from centre, in pixels — the body is 18px
## across, so this stays comfortably inside the shell.
const CORE_LAG: float = 2.7
## Spring toward the lag target. Deliberately underdamped: the small overshoot
## when you stop IS the effect. A critically damped core just slides.
## Critical damping for stiffness k is 2*sqrt(k) = 2*sqrt(160) ~= 25.3. The first
## version used 11 — less than half — which is not "a little bouncy", it RINGS,
## and because the core is its own sprite the whole character read as vibrating
## (playtest 2026-08-02). 24 sits just under critical: it still overshoots once
## when you stop, which is the effect, and then it is done.
const CORE_STIFFNESS: float = 160.0
const CORE_DAMPING: float = 24.0

## Trail length in POINTS. One point is appended per physics frame, so the ribbon
## also lengthens with speed for free — but do the arithmetic before touching
## these, because it is not intuitive: at base speed 130 and 60fps the player
## covers 2.2px per frame, so N points is only N*2.2 pixels of ribbon. The first
## attempt used 15 and produced a 32px streak on an 18px character, i.e. nothing.
##   length_px ~= points * speed / 60
const TRAIL_POINTS_MIN: int = 12
const TRAIL_POINTS_MAX: int = 34
## The dash is a SPIKE, not more of the same — the only 0.15s in the game where
## the player cannot be hit, and it has to look different in kind. The dash only
## lasts ~9 frames, so this mostly keeps the pre-dash tail alive underneath the
## fast segment rather than drawing 48 frames at 3.6x speed.
const TRAIL_POINTS_DASH: int = 48
const TRAIL_WIDTH_MIN: float = 3.0
const TRAIL_WIDTH_MAX: float = 7.5
const TRAIL_WIDTH_DASH: float = 12.0
## Twin jets leave the two TRAILING vertices of the hexagon, +/- 30 degrees off
## dead astern — which is exactly where two of the six vertices sit.
const JET_SPREAD: float = PI / 6.0
const JET_ORIGIN_RADIUS: float = 6.0
const JET_LEN_MAX: float = 15.0
const JET_LEN_DASH: float = 30.0

var _core_offset: Vector2 = Vector2.ZERO
var _core_spring: Vector2 = Vector2.ZERO
var _dash_was_ready: bool = false
var _dash_flash: float = 0.0

## --dev-autopilot: drive the player in a slow circle. Exists because a capture
## run has no input, so the player stands perfectly still — which makes every
## MOTION effect (the trail, the jets, the core lag) invisible to exactly the
## tool built for checking things that move. Inert in normal play.
var dev_autopilot: bool = false
var _trail_points: PackedVector2Array = PackedVector2Array()


func _update_motion_visual(delta: float) -> void:
	var frac: float = clampf(velocity.length() / maxf(1.0, stats.speed()), 0.0, 1.0)
	var dashing: bool = _dash_left > 0.0
	_update_core(delta, frac, dashing)
	_update_trail(frac, dashing)
	_update_jets(frac, dashing)


## The core slides toward the TRAILING edge under motion and springs back when
## you stop. This is the whole of the "motion personality" ask: the body stays
## frame-exact so nothing about responsiveness changes, but the shape acquires an
## inside that has weight — and, incidentally, an orientation, which a hexagon
## otherwise does not have.
func _update_core(delta: float, frac: float, dashing: bool) -> void:
	var target: Vector2 = Vector2.ZERO
	if frac > 0.02:
		var reach: float = CORE_LAG * (1.9 if dashing else 1.0)
		target = -velocity.normalized() * reach * frac
	var to_target: Vector2 = target - _core_offset
	_core_spring += to_target * CORE_STIFFNESS * delta
	_core_spring *= exp(-CORE_DAMPING * delta)
	_core_offset += _core_spring * delta
	core.position = _core_offset
	_update_core_state(dashing)


## The REACTIVE half. Same node, carrying state the player would otherwise have
## to read off the HUD: how close to death they are, and whether the dash is
## back. Everything stays inside the cyan family — the core is the player's own
## instrument and the colour law reserves every other hue for things that can
## hurt them.
func _update_core_state(dashing: bool) -> void:
	var hp_frac: float = float(health.hp) / maxf(1.0, float(health.max_hp))
	# Breathes at rest, clenches during the dash. A still core on a still player
	# is the "inert" complaint in miniature.
	var breathe: float = 1.0 + 0.05 * sin(_time * 3.1)
	core.scale = Vector2.ONE * (0.82 if dashing else breathe)

	var ready_now: bool = _can_dash and _dash_cd <= 0.0
	if ready_now and not _dash_was_ready:
		_dash_flash = 1.0  # the moment the verb comes back
	_dash_was_ready = ready_now
	_dash_flash = maxf(0.0, _dash_flash - 4.0 * get_physics_process_delta_time())

	# Dim as HP falls. Not a hue shift: at 12px a desaturating core reads faster
	# than a colour change, and the palette has no spare hue for "you are dying".
	var lum: float = lerpf(0.45, 1.0, clampf(hp_frac, 0.0, 1.0))
	lum = minf(1.6, lum + _dash_flash * 0.8)
	core.modulate = Color(lum, lum, lum, core.modulate.a)


## The ribbon. A world-space Line2D (the node is `top_level`, so its points are
## global coordinates) holding recent positions, oldest first — which is why the
## scene's width curve and gradient both run thin/transparent at offset 0.
func _update_trail(frac: float, dashing: bool) -> void:
	var want: int = TRAIL_POINTS_DASH if dashing else \
			int(round(lerpf(float(TRAIL_POINTS_MIN), float(TRAIL_POINTS_MAX), frac)))
	_trail_points.append(global_position)
	while _trail_points.size() > want:
		_trail_points.remove_at(0)
	# Two points is the minimum that draws; below that, hide rather than leave a
	# stale segment hanging in the arena.
	trail.visible = _trail_points.size() >= 2 and (frac > 0.04 or dashing)
	trail.points = _trail_points
	trail.width = TRAIL_WIDTH_DASH if dashing else lerpf(TRAIL_WIDTH_MIN, TRAIL_WIDTH_MAX, frac)
	trail.modulate.a = 1.0 if dashing else lerpf(0.4, 1.0, frac)


## Two short jets from the trailing vertices. The ribbon says "you are moving";
## the jets say "you are moving THAT WAY", and they are the only element that
## uses the fact that the player is specifically a hexagon.
func _update_jets(frac: float, dashing: bool) -> void:
	var show: bool = frac > 0.12 or dashing
	jet_a.visible = show
	jet_b.visible = show
	if not show:
		return
	var back: Vector2 = -velocity.normalized()
	var length: float = JET_LEN_DASH if dashing else JET_LEN_MAX * frac
	var alpha: float = 1.0 if dashing else lerpf(0.35, 1.0, frac)
	_aim_jet(jet_a, back.rotated(JET_SPREAD), length, alpha)
	_aim_jet(jet_b, back.rotated(-JET_SPREAD), length, alpha)


func _aim_jet(line: Line2D, dir: Vector2, length: float, alpha: float) -> void:
	var origin: Vector2 = global_position + dir * JET_ORIGIN_RADIUS
	# Tail first, head second — same ordering the width curve and gradient expect.
	line.points = PackedVector2Array([origin + dir * length, origin])
	line.modulate.a = alpha


## Fire a cue after a real delay. `process_always` so a screen that pauses the
## tree between the two halves cannot swallow the second one.
func _play_after(seconds: float, cue: StringName, volume_db: float) -> void:
	await get_tree().create_timer(seconds, true, false, false).timeout
	Sfx.play(cue, volume_db)


func _update_invuln_visual() -> void:
	# The RING carries the shield, not the tint. Playtest, 2026-08-03: "Aegis is
	# practically invisible. cant tell when it's on or off." The old cue was a
	# cyan tint on a player who is already cyan -- it was asking hue to encode a
	# timed buff when hue is already spent on allegiance. A ring is a channel
	# nothing else uses, and it is visible on a 12px sprite in a crowded arena.
	shield.visible = health.shielded
	if health.shielded:
		# Breathes, so "on" is unmistakably an active state rather than a decal,
		# and spins the opposite way to the orbitals so the two never read as one
		# mechanic.
		shield.rotation = -_time * 1.1
		var pulse: float = 0.78 + 0.22 * sin(_time * 7.0)
		shield.modulate = Color(0.72, 1.0, 1.0, pulse)
		shield.scale = Vector2.ONE * (1.0 + 0.05 * sin(_time * 7.0))
		visual.modulate = Color(0.6, 1.0, 1.0, 1.0)
		core.modulate.a = 1.0
		return
	visual.modulate.r = 1.0
	visual.modulate.g = 1.0
	visual.modulate.b = 1.0
	# The core flickers WITH the body. Half the point of splitting them is that
	# the core carries state, so it must never be the one thing that stays solid
	# while the player is mid i-frames.
	var alpha: float = 1.0
	if health.is_invulnerable(_time):
		alpha = 0.4 + 0.6 * absf(sin(_time * 30.0))
	visual.modulate.a = alpha
	core.modulate.a = alpha


func _on_died() -> void:
	set_physics_process(false)
	weapon.set_physics_process(false)
	visual.modulate = Color(0.4, 0.4, 0.4, 0.8)
	core.modulate = Color(0.4, 0.4, 0.4, 0.8)
	# The trail nodes are top_level, so they are NOT dragged out of view with the
	# corpse — a live ribbon left hanging in the arena after death would read as
	# the player still being somewhere.
	trail.visible = false
	jet_a.visible = false
	jet_b.visible = false
	died.emit()
