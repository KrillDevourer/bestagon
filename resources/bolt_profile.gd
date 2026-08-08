class_name BoltProfile
extends Resource
## What an enemy's bullet looks like and does — DERIVED from the enemy, never
## authored per type.
##
## THE LAW: bullet mass is the inverse of enemy mobility.
##
##   A heavy, slow enemy fires a big, slow, hard-hitting bullet.
##   A light, fast enemy fires a small, fast, barely-scratching one.
##
## Derived rather than authored because a bullet is a PROMISE about its shooter,
## and a promise a human types by hand is a promise that eventually gets typed
## wrong. With one formula, bullet size IS the damage tell and it cannot
## disagree with the enemy that fired it — a player reads an unfamiliar bullet
## correctly the first time they see one, including bullets from enemies added
## after they last played.
##
## THE SECOND LAW: light bullets aim where you WILL BE, heavy bullets aim where
## you ARE.
##
## Speed alone does not make a shot hard to dodge — a fast bullet on a straight
## line to where you were standing is dodged by walking. What makes a shot hard
## is being LED. So the light tier leads its target and the heavy tier does not,
## which gives the two tiers genuinely different demands rather than the same
## demand at two speeds: heavy punishes standing still, light punishes moving
## predictably. Neither is dodged the way the other is.
##
## Pure, and takes primitives rather than an EnemyStats, for two reasons: it
## keeps a class cycle from forming between the two files, and it means the law
## can be tested without constructing a single enemy.

## The observed roster, which is what the normalisation is fitted to. Dart is the
## lightest thing in the game at 1 HP and 152 speed; Bulwark the heaviest at 16
## and 46. Constants rather than a scan of the .tres files: the curve has to be
## stable when a new enemy is added, and a fitted range that MOVES every time
## somebody authors an outlier would silently re-tune every existing bullet.
const HP_LIGHTEST: float = 1.0
const HP_HEAVIEST: float = 16.0
const SPEED_SLOWEST: float = 46.0
const SPEED_FASTEST: float = 152.0

## Bullet radius in pixels. The floor is 3px because below that the streak is
## wider than the bullet and the tracer becomes the only visible part.
const RADIUS_LIGHT: float = 3.0
const RADIUS_HEAVY: float = 9.0
## Travel speed. The heavy end must stay clearly slower than the player's dash
## (speed * 3.6) or a heavy bullet cannot be closed on and deflected on purpose.
const SPEED_LIGHT_BOLT: float = 230.0
const SPEED_HEAVY_BOLT: float = 70.0
const DAMAGE_LIGHT: int = 1
const DAMAGE_HEAVY: int = 4
## Below this the bullet leads its target. Half the roster on each side.
const LEAD_BELOW_MASS: float = 0.5

## Deflected damage is the bullet's own damage SQUARED, times this.
##
## Squared on purpose. A linear return makes deflecting a 1-damage needle worth
## a third of deflecting a 4-damage shell, which is enough to be worth doing —
## and a deflect that is always worth doing turns the dash into a free
## damage button and deletes the entire ranged roster. Squared, the needle
## returns 2 and the shell returns 32: catching the heavy thing is the play, and
## flailing at chaff is not.
const DEFLECT_SCALE: int = 2

@export var radius: float = RADIUS_LIGHT
@export var speed: float = SPEED_LIGHT_BOLT
@export var damage: int = DAMAGE_LIGHT
## Aim at where the target is going rather than where it is.
@export var leads_target: bool = true
## Damage this bullet deals to an ENEMY once the player has deflected it.
@export var deflect_damage: int = DEFLECT_SCALE
## 0 (lightest thing in the game) to 1 (heaviest). Kept so the HUD, the sprite
## generator and the deflect feedback can all size themselves off the same
## number the bullet did, instead of three places re-deriving it slightly apart.
@export var mass: float = 0.0


## Where 0 is the lightest enemy in the roster and 1 the heaviest.
##
## HP and slowness weigh the same. Weighting HP higher made the Lancer — 4 HP,
## 66 speed, the game's basic shooter — fire an almost-light bullet while
## reading on screen as a deliberate, planted thing, and the bullet has to match
## how the enemy READS, not how long it takes to kill.
static func mass_of(max_hp: int, speed_px: float) -> float:
	var by_hp: float = _norm(float(max_hp), HP_LIGHTEST, HP_HEAVIEST)
	# Inverted: SLOW is heavy.
	var by_speed: float = 1.0 - _norm(speed_px, SPEED_SLOWEST, SPEED_FASTEST)
	return clampf((by_hp + by_speed) * 0.5, 0.0, 1.0)


## Clamped so an enemy outside the fitted range cannot produce a bullet outside
## the authored one. A future 200 HP elite gets the heaviest bullet in the game,
## not a 40px bullet nobody drew.
static func _norm(value: float, lo: float, hi: float) -> float:
	if is_equal_approx(lo, hi):
		return 0.0
	return clampf((value - lo) / (hi - lo), 0.0, 1.0)


static func derive(max_hp: int, speed_px: float) -> BoltProfile:
	var p: BoltProfile = BoltProfile.new()
	p.mass = mass_of(max_hp, speed_px)
	p.radius = lerpf(RADIUS_LIGHT, RADIUS_HEAVY, p.mass)
	p.speed = lerpf(SPEED_LIGHT_BOLT, SPEED_HEAVY_BOLT, p.mass)
	p.damage = int(roundf(lerpf(float(DAMAGE_LIGHT), float(DAMAGE_HEAVY), p.mass)))
	p.leads_target = p.mass < LEAD_BELOW_MASS
	p.deflect_damage = p.damage * p.damage * DEFLECT_SCALE
	return p


## Where to aim so a bullet at `speed` meets a target moving at `target_velocity`.
##
## One iteration, not an exact intercept solve. The exact solution is a quadratic
## with two roots and a no-solution case when the target outruns the bullet, and
## a shooter that becomes UNABLE TO FIRE when the player is fast enough is a
## worse bug than a shot that leads slightly short. One pass is also what a
## human leading a shot does, so it misses in ways that read as aiming rather
## than as arithmetic.
static func lead_point(from: Vector2, target: Vector2, target_velocity: Vector2,
		bolt_speed: float) -> Vector2:
	if bolt_speed <= 0.0:
		return target
	var flight: float = from.distance_to(target) / bolt_speed
	return target + target_velocity * flight
