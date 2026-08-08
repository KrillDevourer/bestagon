class_name DuelWeapon
extends Node3D
## The player's weapon in the duel. FIRES ITSELF, along wherever the player is
## looking.
##
## Auto-fire is not a shortcut, it is the game's premise. The README's first line
## about play is "Move; your weapons fire themselves", and every weapon in
## scenes/weapons/ works that way. A duel that added a trigger button would make
## the boss fight the one place in BESTAGON where aiming is a button, and it is
## also why the duel needs no crosshair: you are not placing a shot, you are
## pointing a stream.
##
## ONE WEAPON, DERIVED FROM THE WHOLE BUILD. The 2D player can be running four
## weapons with stacked upgrades, and rebuilding orbitals, the lance and the
## scattergun as 3D bodies would be four times the work and four times the tuning
## for a fight that lasts a minute. Instead the run's actual loadout is collapsed
## into one number -- see `derive` -- so every upgrade the player took still pays
## out, in the only currency a duel can spend it in.

const SHOT_SCENE: PackedScene = preload("res://scenes/duel/duel_shot.tscn")

## Metres per second. Fast enough that leading the boss is never required, because
## the boss is the size of a house and hitting it is not meant to be the skill --
## surviving the volleys is.
const SHOT_SPEED: float = 55.0

## Fallbacks for standalone inspection. A real duel calls `derive`.
const BASE_DAMAGE: int = 12
const BASE_INTERVAL: float = 0.22

var damage: int = BASE_DAMAGE
var interval: float = BASE_INTERVAL

var _shooter: DuelPlayer
var _shot_parent: Node3D
var _cd: float = 0.0


## Injected, never reached for. Same rule as the 2D weapons, which are handed their
## target and their container rather than searching the tree for them.
func configure(p_shooter: DuelPlayer, p_shot_parent: Node3D) -> void:
	_shooter = p_shooter
	_shot_parent = p_shot_parent


## Collapse the run's loadout into one weapon.
##
## `weapons` is how many are actually firing and `damage_each` is what one of them
## hits for, both already known to the 2D Player. Multiplying rather than summing a
## per-weapon profile keeps this honest about what it is: an ESTIMATE of the build's
## output, not a simulation of it. Stated plainly because a number like this
## invites being trusted more than it deserves -- it is tuned to make upgrades feel
## like they mattered, and it is expected to move once a human plays a duel.
static func derive(weapons: int, damage_each: int) -> Vector2i:
	var dmg: int = maxi(1, damage_each) * maxi(1, weapons)
	# Rate is fixed and damage carries the build, rather than both scaling. Two
	# scaling axes multiply, and a four-weapon build would end up firing a wall of
	# shots for eight times the DPS of a one-weapon build rather than four.
	return Vector2i(dmg, 1)


func _process(delta: float) -> void:
	if not is_instance_valid(_shooter) or _shot_parent == null:
		return
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = interval
	_fire()


func _fire() -> void:
	var shot: DuelShot = SHOT_SCENE.instantiate()
	shot.setup(_shooter.aim_direction() * SHOT_SPEED, damage)
	_shot_parent.add_child(shot)
	# Positioned AFTER add_child: global_position on a node outside the tree is
	# meaningless, and setting it first silently places the shot at the origin.
	shot.global_position = _shooter.muzzle_position()
	# Quiet. This fires four or five times a second for the length of a boss fight,
	# and the cue's job is texture, not percussion. Same reasoning as the Lancer's
	# -16 dB in enemy.gd.
	Sfx.play(&"shoot", -20.0)
