class_name DuelBolt
extends Area3D
## Enemy fire, in the duel. The 3D counterpart to EnemyProjectile.
##
## YELLOW, because the colour law is not negotiable across a scene boundary:
## nothing friendly is ever yellow, so "this can hurt me" reads before the shape
## does. Same Color as EnemyProjectile.GLOW and Enemy.TELEGRAPH, taken from
## EnemyProjectile rather than re-typed, so the two combat models cannot drift
## into disagreeing about what danger looks like.
##
## Lifetime-capped like both 2D projectiles: a bolt that can outlive its shooter
## is an unbounded live set waiting to happen.
##
## EMISSIVE, not lit. gl_compatibility has no glow pass (see enemy.gd), so a bolt
## that relied on bloom to be visible would be a dim dot. Emission plus a size
## that survives being seen edge-on is what carries it.

const LIFETIME: float = 7.0
## Metres. Big enough to read at 20m, small enough that a gap between two of them
## is genuinely a gap.
const RADIUS: float = 0.34

var velocity: Vector3 = Vector3.ZERO
var damage: int = 1

var _life: float = LIFETIME

@onready var shape: CollisionShape3D = $CollisionShape3D
@onready var visual: MeshInstance3D = $Visual


func setup(p_velocity: Vector3, p_damage: int) -> void:
	velocity = p_velocity
	damage = p_damage


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_build_visual()


## Built in code rather than authored, for the same reason the boss solid is: this
## repo's claim is that every asset is regenerable from a clone, and a sphere is
## not worth a file.
func _build_visual() -> void:
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = RADIUS
	mesh.height = RADIUS * 2.0
	# Cheap: a bolt is 12 pixels of screen most of the time, and there can be
	# thirty of them in the air.
	mesh.radial_segments = 8
	mesh.rings = 4
	visual.mesh = mesh

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = EnemyProjectile.GLOW
	mat.emission_enabled = true
	mat.emission = EnemyProjectile.GLOW
	# Hot enough to read as its own light source against a dark floor without a
	# glow pass to help it.
	mat.emission_energy_multiplier = 1.6
	# Unshaded would flatten it to a disc; a little shading keeps it a sphere.
	mat.roughness = 0.4
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


func _on_body_entered(body: Node3D) -> void:
	var duellist: DuelPlayer = body as DuelPlayer
	if duellist == null:
		return
	duellist.take_bolt(damage)
	queue_free()
