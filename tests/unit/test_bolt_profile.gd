extends GutTest
## The bullet law. Pure derivation, so it tests without an enemy, a scene or a
## bullet — the same reason damage and XP were extracted out of Enemy/Main.
##
## These tests are the law's actual specification. The point of deriving bullets
## instead of authoring them is that the RELATIONSHIP holds for every enemy,
## including ones nobody has designed yet, so most of what follows asserts
## relationships rather than numbers.

const EPS: float = 0.0001

# The real roster, so the law is checked against the game rather than against
# invented inputs.
const DART_HP: int = 1
const DART_SPEED: float = 152.0
const LANCER_HP: int = 4
const LANCER_SPEED: float = 66.0
const BULWARK_HP: int = 16
const BULWARK_SPEED: float = 46.0


# --- mass -------------------------------------------------------------------

func test_the_lightest_enemy_in_the_roster_is_mass_zero() -> void:
	assert_almost_eq(BoltProfile.mass_of(DART_HP, DART_SPEED), 0.0, EPS)


func test_the_heaviest_enemy_in_the_roster_is_mass_one() -> void:
	assert_almost_eq(BoltProfile.mass_of(BULWARK_HP, BULWARK_SPEED), 1.0, EPS)


## The Lancer is the basic shooter and has to land in the middle, or the two
## tiers are really one tier plus an outlier.
func test_the_basic_shooter_sits_between_the_extremes() -> void:
	var m: float = BoltProfile.mass_of(LANCER_HP, LANCER_SPEED)
	assert_gt(m, 0.15)
	assert_lt(m, 0.85)


## An enemy tougher than anything authored must not produce a bullet bigger than
## anything drawn. Clamped, not extrapolated.
func test_mass_clamps_outside_the_fitted_roster() -> void:
	assert_almost_eq(BoltProfile.mass_of(9999, 1.0), 1.0, EPS)
	assert_almost_eq(BoltProfile.mass_of(0, 9999.0), 0.0, EPS)


func test_slower_is_heavier_at_equal_hp() -> void:
	assert_gt(BoltProfile.mass_of(8, 50.0), BoltProfile.mass_of(8, 140.0))


func test_tougher_is_heavier_at_equal_speed() -> void:
	assert_gt(BoltProfile.mass_of(14, 80.0), BoltProfile.mass_of(2, 80.0))


# --- the law ----------------------------------------------------------------

## THE HEADLINE. Everything else is detail; if this inverts, the game is lying
## to the player about what a bullet will do.
func test_heavy_enemies_fire_bigger_slower_harder_bullets() -> void:
	var light: BoltProfile = BoltProfile.derive(DART_HP, DART_SPEED)
	var heavy: BoltProfile = BoltProfile.derive(BULWARK_HP, BULWARK_SPEED)
	assert_gt(heavy.radius, light.radius, "heavy bullets are bigger")
	assert_lt(heavy.speed, light.speed, "heavy bullets are slower")
	assert_gt(heavy.damage, light.damage, "heavy bullets hurt more")


## The second law: light leads, heavy does not.
func test_only_light_bullets_lead_the_target() -> void:
	assert_true(BoltProfile.derive(DART_HP, DART_SPEED).leads_target)
	assert_false(BoltProfile.derive(BULWARK_HP, BULWARK_SPEED).leads_target)


## A heavy bullet the player cannot outrun cannot be deliberately intercepted,
## and deflection stops being a skill and becomes a dice roll. Dash is
## speed * 3.6, and the slowest player build moves at 55.
func test_heavy_bullets_stay_slower_than_a_dash() -> void:
	var heavy: BoltProfile = BoltProfile.derive(BULWARK_HP, BULWARK_SPEED)
	assert_lt(heavy.speed, 55.0 * 3.6, "a heavy bullet must be catchable")


# --- deflection -------------------------------------------------------------

## Squared, not linear. A linear return makes deflecting chaff worth doing, and
## a deflect that is always worth doing turns the dash into a free damage button
## and deletes the ranged roster.
func test_deflect_reward_grows_faster_than_bullet_damage() -> void:
	var light: BoltProfile = BoltProfile.derive(DART_HP, DART_SPEED)
	var heavy: BoltProfile = BoltProfile.derive(BULWARK_HP, BULWARK_SPEED)
	var damage_ratio: float = float(heavy.damage) / float(light.damage)
	var reward_ratio: float = float(heavy.deflect_damage) / float(light.deflect_damage)
	assert_gt(reward_ratio, damage_ratio,
			"deflecting the heavy shot must be disproportionately worth it")


func test_deflecting_chaff_is_nearly_worthless() -> void:
	assert_lte(BoltProfile.derive(DART_HP, DART_SPEED).deflect_damage, 4)


# --- leading ----------------------------------------------------------------

func test_a_stationary_target_is_not_led() -> void:
	var aim: Vector2 = BoltProfile.lead_point(
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2.ZERO, 200.0)
	assert_almost_eq(aim.distance_to(Vector2(100.0, 0.0)), 0.0, EPS)


## 100px out at 200px/s is half a second of flight, so a target moving 40px/s
## across is led by 20px.
func test_a_moving_target_is_led_by_speed_times_flight_time() -> void:
	var aim: Vector2 = BoltProfile.lead_point(
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(0.0, 40.0), 200.0)
	assert_almost_eq(aim.y, 20.0, EPS)


## A slower bullet spends longer in the air, so it must lead further. If this
## ever inverts, leading would make fast bullets HARDER to aim than slow ones.
func test_slower_bullets_lead_further() -> void:
	var fast: Vector2 = BoltProfile.lead_point(
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(0.0, 40.0), 400.0)
	var slow: Vector2 = BoltProfile.lead_point(
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(0.0, 40.0), 100.0)
	assert_gt(slow.y, fast.y)


## Guards the divide. A zero-speed bullet has infinite flight time, and the
## honest answer is "do not lead" rather than a NaN aim vector.
func test_zero_speed_does_not_divide_by_zero() -> void:
	var aim: Vector2 = BoltProfile.lead_point(
			Vector2.ZERO, Vector2(100.0, 0.0), Vector2(0.0, 40.0), 0.0)
	assert_almost_eq(aim.distance_to(Vector2(100.0, 0.0)), 0.0, EPS)
