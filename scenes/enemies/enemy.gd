class_name Enemy
extends CharacterBody2D
## Chases its target. All numbers come from an EnemyStats resource —
## new enemy types are .tres files, not new scripts.

signal died(xp_value: int, at: Vector2, tint: Color)

const FLASH_TIME: float = 0.12
## Telegraph colour. NOT white — white already means "you damaged it" (the hit
## flash mixes toward solid white), so using it for "it is about to damage you"
## made one colour say two opposite things on the busiest screen in the game.
## That is review finding 17. Hot yellow is what the colour law already reserves
## for incoming enemy damage, so a telegraph and a bolt now speak one language.
const TELEGRAPH: Color = Color(1.0, 0.89, 0.38)
## Knockback. Review finding 26: a non-lethal hit produced a flash and a sound
## and moved NOTHING, so the crowd was physically inert to weapon fire and
## sustained damage on a Bulwark read as a colour blink rather than as pressure.
##
## Modelled as a decaying offset ADDED AFTER the behaviour sets velocity, because
## every behaviour overwrites velocity from scratch each frame — an impulse
## written into velocity would be erased before it moved anything. Scaled down by
## size, so a Bulwark shrugs where a Dart is thrown: weight for free, out of a
## number the enemy data already carries.
const KNOCKBACK_SPEED: float = 150.0
const KNOCKBACK_DECAY: float = 9.0
const KNOCKBACK_REFERENCE_SIZE: float = 13.0
const BOLT_SCENE: PackedScene = preload("res://scenes/enemies/enemy_projectile.tscn")

## BAKED NEON. Playtest 2026-08-03: "enemies are hard to see". They were flat
## unlit fills at 16-23px on a dark navy floor with a busy grid drawn over it —
## nothing separated a body from the background except its own hue.
##
## Real bloom is not available to fix this. `gl_compatibility` fixes the root
## viewport's backbuffer format at boot, so a WorldEnvironment on it is a PROVEN
## no-op — scenes/dev/juice_lab.gd documents the experiment, down to blowing glow
## to threshold 0 / strength 8 and getting a byte-identical frame. The only real
## post-process path is rendering the whole game through a SubViewport, which is
## a renderer migration, not a readability fix.
##
## So the glow is baked: one soft additive dot behind the body, in the body's own
## colour. Same trick `_apply_elite_rim` already uses, and it puts LIGHT around
## the shape rather than asking the shape to be brighter — which would have meant
## re-picking every tint in the colour law to solve a contrast problem.
## MEASURED, twice. The first pass at 2.3 / 0.50 with a wide falloff looked right
## on a lone enemy and turned a twenty-body pack into ONE pink smear with the
## silhouettes dissolved inside it — additive light stacks, so the denser the
## crowd the worse the readability, which is precisely backwards. A halo has to
## be tight enough that N of them overlapping still reads as N things.
const HALO_SCALE: float = 1.75
const HALO_ALPHA: float = 0.38
const HALO_TEXTURE_SIZE: int = 64

## ONE texture and ONE material for every halo in the game. Static because
## MAX_ALIVE is 110 and a per-instance gradient would be 110 allocations of the
## same 64x64 image, rebuilt on every spawn, for the whole run.
static var _halo_texture: GradientTexture2D = null
static var _halo_material: CanvasItemMaterial = null


static func halo_texture() -> GradientTexture2D:
	if _halo_texture != null:
		return _halo_texture
	var grad := Gradient.new()
	# Hot centre, fast falloff, fully transparent at the rim. The middle stop is
	# what stops it reading as a flat disc: a linear ramp looks like a bubble,
	# this looks like light.
	# Tight falloff: nearly all the light is inside the body's own footprint and
	# it is gone by 70% of the radius. A wider ramp is what let neighbouring
	# halos pool into a single glowing mass in a crowd.
	grad.offsets = PackedFloat32Array([0.0, 0.30, 0.72])
	grad.colors = PackedColorArray([
			Color(1.0, 1.0, 1.0, 0.95),
			Color(1.0, 1.0, 1.0, 0.22),
			Color(1.0, 1.0, 1.0, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = HALO_TEXTURE_SIZE
	tex.height = HALO_TEXTURE_SIZE
	_halo_texture = tex
	return _halo_texture


## ADDITIVE, because a glow adds light to what is behind it. Mix-blended, the
## same sprite is a translucent grey disc that DARKENS the floor grid — which is
## the opposite of the problem being solved.
static func halo_material() -> CanvasItemMaterial:
	if _halo_material != null:
		return _halo_material
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_halo_material = mat
	return _halo_material

var stats: EnemyStats
var hp: int
## Kept so subclasses can reason about proportional health (the boss's phase
## threshold) without re-deriving the difficulty multiplier.
var max_hp: int
var target: Node2D
var is_elite: bool = false
var damage: int = 1
var xp_value: int = 1
## Injected by the spawner. Falls back to our parent only if unset.
var bolt_container: Node2D
## Injected too, so a death payload can place its children.
var spawner: Spawner
var _shoot_cd: float = 0.0
## Cryo Rounds. Strongest slow wins and the longest duration wins, rather than
## stacking — otherwise sustained fire freezes everything solid.
var _slow_factor: float = 1.0
var _slow_left: float = 0.0
## CHARGE state: 0 stalking, 1 telegraphing, 2 dashing, 3 recovering.
var _charge_phase: int = 0
var _charge_t: float = 0.0
var _charge_dir: Vector2 = Vector2.ZERO
var _knockback: Vector2 = Vector2.ZERO

var _halo: Sprite2D

@onready var visual: Sprite2D = $Visual
@onready var shape: CollisionShape2D = $CollisionShape2D


## Called by the spawner before add_child (so _ready sees everything).
func setup(p_stats: EnemyStats, p_target: Node2D, hp_mult: float = 1.0,
		p_elite: bool = false) -> void:
	stats = p_stats
	target = p_target
	is_elite = p_elite
	var elite_hp: float = Difficulty.ELITE_HP_MULT if is_elite else 1.0
	max_hp = stats.effective_hp(hp_mult * elite_hp)
	hp = max_hp
	damage = stats.damage + (Difficulty.ELITE_DAMAGE_BONUS if is_elite else 0)
	xp_value = roundi(stats.xp_value * (Difficulty.ELITE_XP_MULT if is_elite else 1.0))


func _ready() -> void:
	# Silhouette and colour are both content (EnemyStats), never code.
	if stats.sprite != null:
		visual.texture = stats.sprite
	_shoot_cd = stats.attack_interval * randf_range(0.4, 1.0)
	var size: float = stats.size * (Difficulty.ELITE_SCALE if is_elite else 1.0)
	# Divisor comes from the TEXTURE, not a hardcoded 16. Sprite canvases differ
	# (enemies 24px, the bosses 32 and 40), and a literal here silently rescaled
	# every boss the moment the enemy sheet changed resolution.
	var native: float = float(visual.texture.get_width()) if visual.texture != null else 16.0
	visual.scale = Vector2.ONE * (size / maxf(1.0, native))
	var rect: RectangleShape2D = shape.shape
	rect.size = Vector2(size - 2.0, size - 2.0)
	_add_halo(size)
	# Set through the helper so the halo starts on the same colour as the body,
	# and keeps matching it through slows and telegraphs.
	_set_tint(stats.tint)
	if is_elite:
		_apply_elite_rim()


## The neon. Sized off the BODY, not the texture, so a Dart glows like a Dart and
## a boss glows like a boss without a second number to keep in sync.
func _add_halo(body_size: float) -> void:
	_halo = Sprite2D.new()
	_halo.texture = halo_texture()
	_halo.material = halo_material()
	_halo.scale = Vector2.ONE * (body_size * HALO_SCALE / float(HALO_TEXTURE_SIZE))
	# Behind the elite rim (-1), which is itself behind the body. The stacking
	# order IS the read: light, then threat marker, then silhouette.
	_halo.z_index = -2
	add_child(_halo)


## One place that owns "what colour is this enemy right now". Before the halo
## existed, three call sites wrote `visual.modulate` directly; with a second node
## to keep in step, that is three chances for the glow to disagree with the body
## — including during a charge telegraph, where disagreeing would actively lie.
func _set_tint(colour: Color) -> void:
	visual.modulate = colour
	if _halo != null:
		_halo.modulate = Color(colour.r, colour.g, colour.b,
				HALO_ALPHA * stats.glow_scale)


## Elites keep their archetype's hue and gain a pulsing bright rim: same
## silhouette, obviously more dangerous. No new sprite, no new colour.
func _apply_elite_rim() -> void:
	var rim := Sprite2D.new()
	rim.texture = visual.texture
	rim.modulate = Difficulty.ELITE_RIM
	rim.scale = Vector2.ONE * 1.35
	rim.z_index = -1
	add_child(rim)
	var pulse: Tween = create_tween().set_loops()
	pulse.tween_property(rim, "modulate:a", 0.35, 0.5).set_trans(Tween.TRANS_SINE)
	pulse.tween_property(rim, "modulate:a", 0.9, 0.5).set_trans(Tween.TRANS_SINE)


## Applied by a Cryo projectile.
func apply_slow(fraction: float, duration: float) -> void:
	_slow_factor = minf(_slow_factor, maxf(0.25, 1.0 - fraction))
	_slow_left = maxf(_slow_left, duration)
	_set_tint(stats.tint.lerp(Color(0.55, 0.85, 1.0), 0.55))


func _tick_slow(delta: float) -> void:
	if _slow_left <= 0.0:
		return
	_slow_left -= delta
	if _slow_left <= 0.0:
		_slow_factor = 1.0
		_set_tint(stats.tint)


func speed_now() -> float:
	return stats.speed * _slow_factor


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target):
		return
	_tick_slow(delta)
	if stats.behavior == EnemyStats.Behavior.RANGED:
		_act_ranged(delta)
	elif stats.behavior == EnemyStats.Behavior.CHARGE:
		_act_charge(delta)  # owns its own facing — the wedge is its telegraph
	else:
		velocity = (target.global_position - global_position).normalized() * speed_now()
		if stats.faces_travel:
			_face(velocity)
	# Applied last: behaviours own velocity, knockback rides on top of it.
	if _knockback.length_squared() > 1.0:
		velocity += _knockback
		_knockback = _knockback.lerp(Vector2.ZERO, minf(1.0, KNOCKBACK_DECAY * delta))
	else:
		_knockback = Vector2.ZERO
	move_and_slide()


## How fast the thing being shot at is actually moving, for leading a shot.
##
## Read defensively rather than typed as Player: `target` is a Node2D by
## contract, the dev harnesses aim enemies at stand-ins that are not the player,
## and a lead that hard-casts would crash the moment one of them did. A target
## with no velocity is simply not led, which is the correct answer for a
## stationary one anyway.
func _target_velocity() -> Vector2:
	var body: CharacterBody2D = target as CharacterBody2D
	return body.velocity if body != null else Vector2.ZERO


## Holds its preferred range and shoots. Backs off when crowded in, closes when
## too far — so the player cannot simply walk away from it either.
func _act_ranged(delta: float) -> void:
	var to_target: Vector2 = target.global_position - global_position
	var dist: float = to_target.length()
	var dir: Vector2 = to_target.normalized()
	if dist > stats.attack_range * 1.15:
		velocity = dir * speed_now()
	elif dist < stats.attack_range * 0.75:
		velocity = -dir * speed_now() * 0.8
	else:
		velocity = dir.orthogonal() * speed_now() * 0.35  # strafe, never static

	_shoot_cd -= delta
	if _shoot_cd <= 0.0 and dist <= stats.attack_range * 1.3:
		_shoot_cd = stats.attack_interval
		# Quiet: with several Lancers alive this fires constantly, and the cue's
		# job is "incoming from off-screen", not percussion.
		Sfx.play(&"bolt", -16.0)
		var profile: BoltProfile = stats.bolt_profile()
		# THE SECOND LAW: light bullets aim where you WILL BE, heavy ones where
		# you ARE. A fast bullet on a line to where you were standing is dodged by
		# walking; being LED is what actually costs you something. So the light
		# tier has to break your rhythm and the heavy tier has to punish standing
		# still, and they are dodged differently rather than at two speeds.
		var aim: Vector2 = target.global_position
		if profile.leads_target:
			aim = BoltProfile.lead_point(global_position, target.global_position,
					_target_velocity(), profile.speed)
		var shot: Vector2 = (aim - global_position).normalized()
		# Degenerate only if the lead lands exactly on the muzzle. Falling back to
		# the unled direction beats firing a zero vector, which is a bolt that
		# sits on the shooter for its whole six-second lifetime.
		if shot.length_squared() < 0.01:
			shot = dir
		var bolt: EnemyProjectile = BOLT_SCENE.instantiate()
		bolt.setup(shot * profile.speed, profile.damage, profile)
		bolt.global_position = global_position
		_bolt_parent().add_child(bolt)


## Stalk, telegraph, dash, recover. The recovery is the point: a charger that
## could turn mid-dash would be unavoidable, and one that never committed would
## be a slightly faster chaser. Standing in an open lane is what it punishes.
func _act_charge(delta: float) -> void:
	_charge_t -= delta
	var to_target: Vector2 = target.global_position - global_position
	match _charge_phase:
		0:
			velocity = to_target.normalized() * speed_now()
			_face(velocity)
			if to_target.length() <= stats.charge_range:
				_charge_phase = 1
				_charge_t = stats.charge_telegraph
				# Flare: the tell has to be visible before it can be fair — and
				# the GLOW flares with it now, which is most of what makes a
				# wind-up readable across a crowded screen.
				_set_tint(TELEGRAPH)
		1:
			velocity = Vector2.ZERO  # planting is part of the tell
			# Keep the point aimed while it winds up: the wedge doubles as a
			# live aiming line, so "where will it go" is answerable on sight.
			_face(to_target)
			if _charge_t <= 0.0:
				_charge_phase = 2
				_charge_t = stats.charge_time
				_charge_dir = to_target.normalized()
				_set_tint(stats.tint)
		2:
			velocity = _charge_dir * stats.charge_speed
			if _charge_t <= 0.0:
				_charge_phase = 3
				_charge_t = stats.charge_recover
		_:
			velocity = velocity.lerp(Vector2.ZERO, 6.0 * delta)
			if _charge_t <= 0.0:
				_charge_phase = 0


## Point the sprite along `dir`. Only CHARGE types use it — the wedge sprite is
## drawn pointing up, so forward is `angle + PI/2`. A shape that TURNS TO FACE
## YOU is the clearest "this one is coming for you" the game can give, and it is
## now most of what separates the Ram from the Dart at 12px in a crowd.
func _face(dir: Vector2) -> void:
	if dir.length_squared() > 0.01:
		visual.rotation = dir.angle() + PI * 0.5


func _bolt_parent() -> Node:
	return bolt_container if is_instance_valid(bolt_container) else get_parent()


## `execute_below` is Executioner: an enemy left under that fraction of its max
## HP dies outright. Passed in per hit rather than read from a global, so the
## enemy stays ignorant of who shot it.
## Push without hurting. Same decaying impulse `take_hit` applies, and scaled the
## same way by enemy size so a Bulwark barely moves and a Dart is flung -- mass
## should read as mass whether the push came from a bullet or from a body check.
##
## Playtest 2026-08-03: enemies "just latch on weirdly" after they land a hit.
## Contact damage has i-frames, so an enemy that connects stays welded to the
## player for the whole invulnerability window, doing nothing and looking stuck.
## Shoving the crowd on hit gives those i-frames a visible meaning: the hit threw
## everything off you, and you have that moment to move.
## `pixels` is the DISTANCE this should actually move a reference-sized enemy,
## not an opaque impulse. The impulse decays exponentially at KNOCKBACK_DECAY, so
## total travel is speed/decay -- multiplying the two back out means the caller
## gets to ask for "80 pixels" and be right, and the number stays right if the
## decay is ever retuned.
func shove(from: Vector2, pixels: float) -> void:
	if hp <= 0 or not from.is_finite():
		return
	var away: Vector2 = global_position - from
	if away.length_squared() <= 0.01:
		return
	# Mass still reads as mass: a Bulwark shifts, a Dart is flung, and a boss at
	# size 70+ barely registers it -- which is what should happen when something
	# five times your size shoulders past you.
	_knockback = away.normalized() * pixels * KNOCKBACK_DECAY 			* (KNOCKBACK_REFERENCE_SIZE / maxf(8.0, stats.size))


## How much of `amount` this body can actually take. Overkill is NOT absorbed:
## 40 damage into a 1 HP Dart spends 1, and the other 39 are what a Ricochet
## carries onward.
##
## Static and pure so the rule is testable without instancing a scene — the same
## reason `GameCamera.shake_pixels` is static. Executioner deliberately gets no
## say here: a shot that triggers it still only paid for the HP that was in
## front of it, so an execute is a free KILL and never a bigger bounce.
static func absorbed_by(hp_before: int, amount: int) -> int:
	return clampi(amount, 0, maxi(0, hp_before))


## `from` is where the hit came from, used only for knockback. Optional and
## defaulted to INF so the many call sites that have no meaningful origin
## (Event Horizon's implosion, Second Wind's screen clear) simply do not push.
##
## RETURNS the damage this body absorbed, which is what Ricochet spends. Most
## callers ignore it; the projectile is the one that cannot.
func take_hit(amount: int, execute_below: float = 0.0,
		from: Vector2 = Vector2.INF) -> int:
	if hp <= 0:
		return 0
	var absorbed: int = absorbed_by(hp, amount)
	hp -= amount
	if from.is_finite():
		var away: Vector2 = global_position - from
		if away.length_squared() > 0.01:
			_knockback = away.normalized() * KNOCKBACK_SPEED \
					* (KNOCKBACK_REFERENCE_SIZE / maxf(8.0, stats.size))
	if hp > 0 and execute_below > 0.0 and float(hp) <= float(max_hp) * execute_below:
		hp = 0
	Sfx.play(&"hit", -17.0)
	if hp <= 0:
		_split()
		died.emit(xp_value, global_position, stats.tint)
		queue_free()
		return absorbed
	_flash()
	return absorbed


## The Splitter's death payload. Deferred because this runs inside a physics
## callback, and adding physics bodies mid-flush is forbidden.
func _split() -> void:
	if stats.split_count <= 0 or spawner == null:
		return
	var child: EnemyStats = stats.resolve_split()
	if child == null:
		return
	var at: Vector2 = global_position
	for i: int in stats.split_count:
		var offset: Vector2 = Vector2.RIGHT.rotated(TAU * float(i) / float(stats.split_count)) * 12.0
		spawner.spawn_at.call_deferred(child, at + offset, 1.0, false)


func _flash() -> void:
	var mat: ShaderMaterial = visual.material
	mat.set_shader_parameter(&"flash", 1.0)
	var tween: Tween = create_tween()
	tween.tween_property(mat, "shader_parameter/flash", 0.0, FLASH_TIME)
