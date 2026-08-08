class_name Health
extends RefCounted
## Pure HP logic with an invulnerability window. Time is INJECTED (callers
## pass `now`) so this is unit-testable without the scene tree or real time.

signal changed(hp: int, max_hp: int)
signal died

var max_hp: int
var hp: int
var invuln_duration: float

## Dev-only escape hatch (--dev-godmode). Damage is ignored entirely, so a soak
## run can observe the difficulty curve without the player dying two minutes in.
var invincible: bool = false

## Temporary protection from a Shield power-up. Kept SEPARATE from `invincible`
## so a dev flag and a gameplay buff can never clobber each other's state.
var shielded: bool = false

var _invuln_until: float = -INF


func _init(p_max_hp: int, p_invuln_duration: float = 0.6) -> void:
	max_hp = p_max_hp
	hp = p_max_hp
	invuln_duration = p_invuln_duration


## Returns true if damage was applied (not blocked by i-frames or death).
func take_damage(amount: int, now: float) -> bool:
	if invincible or shielded or hp <= 0 or now < _invuln_until:
		return false
	hp = maxi(hp - amount, 0)
	_invuln_until = now + invuln_duration
	changed.emit(hp, max_hp)
	if hp == 0:
		died.emit()
	return true


## Write HP directly, clamped, announcing the change.
##
## Exists for ONE caller: handing the result of a first-person duel back to the
## run. The duel fights on its own Health seeded from this one, so that a death in
## there cannot fire this object's `died` mid-scene and stack a game-over screen
## underneath a duel that is still on screen. Coming back, the outcome has to be
## written across, and neither `take_damage` nor `heal` can do it -- take_damage is
## gated by i-frames and would sometimes silently refuse.
##
## Deliberately does NOT emit `died` at zero. A duel loss is routed through the
## run's normal death path by its caller, and having two places able to start a
## game-over is how you get two of them.
func set_hp(value: int) -> void:
	hp = clampi(value, 0, max_hp)
	changed.emit(hp, max_hp)


func heal(amount: int) -> void:
	if hp <= 0:
		return
	hp = mini(hp + amount, max_hp)
	changed.emit(hp, max_hp)


func raise_max(amount: int) -> void:
	max_hp += amount
	hp = mini(hp + amount, max_hp)
	changed.emit(hp, max_hp)


## Invulnerability that is NOT paid for by taking a hit — the dash's i-frames.
## Extends rather than overwrites, so dashing while already invulnerable can
## never SHORTEN the window a hit already bought. Time is injected here for the
## same reason it is everywhere else in this class: so it stays unit-testable.
func grant_invuln(now: float, duration: float) -> void:
	_invuln_until = maxf(_invuln_until, now + duration)


func is_invulnerable(now: float) -> bool:
	return now < _invuln_until


## Cancel any running i-frame window. Note that `grant_invuln` deliberately
## cannot do this — it takes the MAX so a dash can never shorten a window a hit
## already bought — so removing one needs its own door. The only caller is
## NOGAXEH's detonation, which must not be survivable by an accident of timing.
func clear_invuln() -> void:
	_invuln_until = -INF
