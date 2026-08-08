class_name DuelShot
extends Area3D
## The PLAYER's fire, in the duel. The 3D counterpart to scenes/weapons/projectile.
##
## CYAN, because the colour law is not negotiable across a scene boundary: cyan is
## yours, the hostile band is magenta through orange, and yellow is enemy fire.
## A player shot that borrowed the enemy's yellow would break the one read the
## whole game's readability rests on.
##
## Lifetime-capped like every other projectile in the project. A shot that can
## outlive its shooter is an unbounded live set waiting to happen.

const LIFETIME: float = 3.0
## Metres. Smaller than an enemy bolt on purpose -- enemy fire is bigger and hotter
## than the player's in 2D too, because it is the thing that has to read as a
## threat across a busy screen.
const RADIUS: float = 0.16
## The player's own cyan, matching the 2D bullet's core.
const GLOW: Color = Color(0.55, 1.0, 1.0)

var velocity: Vector3 = Vector3.ZERO
var damage: int = 1

var _life: float = LIFETIME

@onready var shape: CollisionShape3D = $CollisionShape3D
@onready var visual: MeshInstance3D = $Visual


func setup(p_velocity: Vector3, p_damage: int) -> void:
	velocity = p_velocity
	damage = p_damage


func _ready() -> void:
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)
	_build_visual()


func _build_visual() -> void:
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = RADIUS
	mesh.height = RADIUS * 2.0
	# Cheap: there can be dozens in the air and each is a few pixels.
	mesh.radial_segments = 6
	mesh.rings = 3
	visual.mesh = mesh

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = GLOW
	mat.emission_enabled = true
	mat.emission = GLOW
	# gl_compatibility has no glow pass (enemy.gd), so emission is the only thing
	# making a 16cm sphere visible at 20 metres.
	mat.emission_energy_multiplier = 2.0
	visual.material_override = mat

	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = RADIUS
	shape.shape = sphere


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	global_position += velocity * delta


## The boss is an Area3D hitbox, so this is the path that actually fires. Kept
## alongside the body check because a future duel boss built as a body should not
## silently become invulnerable -- which is precisely the failure boss.gd records
## from the 2D game, where anything that merely resembled an Enemy could not be hit.
func _on_area_entered(area: Area3D) -> void:
	_try_hit(area.get_parent())


func _on_body_entered(body: Node3D) -> void:
	_try_hit(body)


func _try_hit(who: Node) -> void:
	var boss: DuelBoss = who as DuelBoss
	if boss == null:
		return
	boss.take_hit(damage)
	queue_free()
