class_name EnemyProjectile
extends Area2D
## Boss and Lancer fire. Yellow by the colour law — nothing friendly is ever
## yellow, so "this can hurt me" reads before the shape does.
##
## Lifetime-capped like the player's projectile: a bullet that can outlive its
## shooter is an unbounded live set waiting to happen.
##
## GLOW AND STREAK, and that pairing is the whole point. Playtest 2026-08-03:
## "orange dart looks more like a projectile". It did — a Dart and a bolt were
## the same construction, a small flat rotated triangle differing only in hue,
## so hue was the ONLY thing telling a body apart from a bullet on the busiest
## screen in the game. Hue is the weakest signal available and it was carrying
## the whole load.
##
## Enemies now glow and do NOT streak; a bolt glows and streaks. Motion is the
## discriminator, because motion is what actually differs: a thing that leaves a
## tracer is flying, and a thing that does not is walking at you. That reads at
## 12px in a crowd in a way a colour swap never could — and it left every enemy
## tint in the colour law untouched.

const LIFETIME: float = 6.0

## Points in the streak. One per physics frame, so at 60Hz this is ~0.12s of
## history — long enough to read as a tracer, short enough that a boss's 22-bolt
## ring is 22 short dashes and not a plate of spaghetti.
const TRAIL_POINTS: int = 7
## Diameter of the glow in pixels. The bolt sprite is 12px, so the halo reads as
## light spilling off a hot object rather than as a second, bigger object.
const HALO_PIXELS: float = 15.0
const HALO_ALPHA: float = 0.42
## The colour law's "incoming enemy damage" yellow, shared with Enemy.TELEGRAPH.
const GLOW: Color = Color(1.0, 0.85, 0.32)

## DEFLECTED bolts are cyan, and that is the colour law, not decoration. Nothing
## friendly is ever yellow, so a bolt that now belongs to the player cannot stay
## the colour that means "this can hurt me" — the player has to be able to read
## a screen full of bolts and know instantly which half is theirs.
const DEFLECTED_GLOW: Color = Color(0.35, 0.95, 1.0)
## What a deflect does to the bolt's speed. It leaves faster than it arrived,
## because a deflect that returns a slow bullet slowly reads as a fumble rather
## than as a parry.
const DEFLECT_SPEED_MULT: float = 1.65
## Collision layers, by NAME in Project Settings: 2 = enemies, 3 = projectiles,
## 6 = enemy_projectiles. Written as shifted bits rather than the literals 4/32
## so the mapping to those names stays legible at the call site.
const LAYER_ENEMIES: int = 1 << 1
const LAYER_PROJECTILES: int = 1 << 2
const LAYER_ENEMY_PROJECTILES: int = 1 << 5

var velocity: Vector2 = Vector2.ZERO
var damage: int = 1
## Null for the boss, which authors its own bolts rather than deriving them: a
## boss's shape is deliberate, not a consequence of its stat block.
var profile: BoltProfile

var _life: float = LIFETIME
var _trail_points: PackedVector2Array = PackedVector2Array()
## Once true this bolt belongs to the player and hunts enemies instead.
var _deflected: bool = false
var _halo: Sprite2D

@onready var trail: Line2D = $Trail
@onready var shape: CollisionShape2D = $CollisionShape2D
@onready var visual: Sprite2D = $Visual


func setup(p_velocity: Vector2, p_damage: int, p_profile: BoltProfile = null) -> void:
	velocity = p_velocity
	damage = p_damage
	profile = p_profile


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	rotation = velocity.angle() + PI * 0.5  # sprite points 'up'
	_apply_profile()
	_add_halo()


## Bullet size IS the damage tell. A bolt derived from a heavy enemy is visibly
## fatter than one from a light enemy, and because both come from the same
## formula the two can never disagree about which hurts more.
##
## The hitbox scales with the sprite. A bullet that looks big and hits small is
## the single most infuriating thing a bullet can be, and it is BRIEF defect #4
## — a run that ends without the player understanding why.
## DUPLICATED, NOT MUTATED. The CircleShape2D in the scene is a plain
## sub-resource with no `resource_local_to_scene`, so every bolt in the game
## shares one instance of it — resizing "this" bolt's hitbox would silently
## resize every bolt already in flight, including the boss's. Same trap as the
## trail Gradient in _recolour. The scene could be marked local instead, but
## duplicating here keeps the fix next to the code that depends on it rather
## than in a .tscn line nobody reads.
func _apply_profile() -> void:
	if profile == null:
		return
	var circle: CircleShape2D = (shape.shape as CircleShape2D).duplicate() as CircleShape2D
	if circle != null:
		circle.radius = profile.radius
		shape.shape = circle
	# The sprite is authored at 12px across, so radius 3 is scale 1 and the art
	# grows from there rather than from an arbitrary base.
	visual.scale = Vector2.ONE * (profile.radius / BoltProfile.RADIUS_LIGHT)


## Borrows Enemy's shared halo texture and material rather than building its own.
## One soft-dot image and one additive material serve every glowing thing in the
## game — a second copy here would be a second thing to keep in sync for no gain.
func _add_halo() -> void:
	var halo := Sprite2D.new()
	halo.texture = Enemy.halo_texture()
	halo.material = Enemy.halo_material()
	halo.modulate = Color(GLOW.r, GLOW.g, GLOW.b, HALO_ALPHA)
	# Scaled with the bolt, or a heavy shell would wear a light bolt's halo and
	# the glow would stop meaning size.
	var spread: float = 1.0 if profile == null \
			else profile.radius / BoltProfile.RADIUS_LIGHT
	halo.scale = Vector2.ONE * (HALO_PIXELS * spread / float(Enemy.HALO_TEXTURE_SIZE))
	halo.z_index = -1
	add_child(halo)
	_halo = halo


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	global_position += velocity * delta
	_update_trail()


## The streak. Points are GLOBAL because the Line2D is top_level — see the scene.
func _update_trail() -> void:
	_trail_points.append(global_position)
	while _trail_points.size() > TRAIL_POINTS:
		_trail_points.remove_at(0)
	# Below two points a Line2D draws nothing anyway, and assigning a 1-point
	# array every frame for the bolt's first frame is pure churn.
	if _trail_points.size() < 2:
		return
	trail.points = _trail_points


## THE DEFLECT. Dashing INTO a bullet sends it back.
##
## Only during the dash's MOVEMENT window, never its full i-frame window. The
## i-frames outlast the movement by design (0.26s against 0.15s) so a dash that
## ends next to a bullet still saves you — but if deflection used that same
## generous window, every dash would deflect and the dash would stop being an
## aimed act. Player.is_deflecting draws the line; see the constants there.
##
## THE TRAP THIS AVOIDS. A deflect that is always worth doing turns the dash into
## a free damage button and deletes the entire ranged roster: every Lancer
## becomes a damage pickup with extra steps. Two things keep it honest. The
## window above, and BoltProfile's SQUARED return — a needle comes back for 2 and
## a shell for 32, so the play is catching the heavy thing on purpose, and
## flailing at chaff earns nothing worth the cooldown.
func deflect(toward: Vector2) -> void:
	if _deflected:
		return
	_deflected = true
	damage = profile.deflect_damage if profile != null else damage
	velocity = toward.normalized() * velocity.length() * DEFLECT_SPEED_MULT
	rotation = velocity.angle() + PI * 0.5
	# Change sides. It stops being able to touch the player at all, which matters
	# because a deflected bolt that could still come back and hit you would make
	# the parry a gamble rather than a reward.
	set_collision_layer_value(6, false)
	set_collision_layer_value(3, true)
	set_collision_mask_value(1, false)
	set_collision_mask_value(2, true)
	_recolour(DEFLECTED_GLOW)
	Sfx.play(&"crit", -4.0)


## Repaint every part of the bolt at once — sprite, halo and streak. Split across
## three nodes, so doing it in one place is what stops a deflected bolt from
## keeping a yellow tracer and reading as hostile while it flies home.
func _recolour(tint: Color) -> void:
	visual.modulate = tint
	if is_instance_valid(_halo):
		_halo.modulate = Color(tint.r, tint.g, tint.b, HALO_ALPHA)
	# Duplicated for the same reason as the hitbox in _apply_profile: the scene's
	# Gradient is shared by every bolt alive, so recolouring it in place would
	# turn the whole screen's tracers cyan the instant one bolt was parried.
	var ramp: Gradient = trail.gradient
	if ramp != null:
		ramp = ramp.duplicate() as Gradient
		for i: int in ramp.get_point_count():
			var was: Color = ramp.get_color(i)
			ramp.set_color(i, Color(tint.r, tint.g, tint.b, was.a))
		trail.gradient = ramp


func _on_body_entered(body: Node2D) -> void:
	if _deflected:
		var enemy: Enemy = body as Enemy
		if enemy != null:
			enemy.take_hit(damage, 0.0, global_position)
			queue_free()
		return
	var player: Player = body as Player
	if player == null:
		return
	if player.is_deflecting():
		# Back the way the player is dashing, not simply reversed. Reversing sends
		# it at whoever fired it, which sounds right and plays badly — the shooter
		# is usually the one enemy already at a safe distance. Dash direction lets
		# the player CHOOSE the target, which is what makes it a skill.
		deflect(player.dash_direction())
		return
	player.apply_damage(damage, &"bolt")
	queue_free()
