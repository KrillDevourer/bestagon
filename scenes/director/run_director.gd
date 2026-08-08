class_name RunDirector
extends Node
## SYSTEM CONTRACT — Run Director
##
## Purpose: own the SHAPE of a run — what spawns when, when elites appear, when
##   bosses arrive, and when the run is won.
##
## Data: RunSchedule (.tres) holding Array[WaveResource] (.tres). All pacing is
##   data; this script is policy only and contains no tuning numbers.
##
## Ownership:
##   Owns:      elapsed run time, the active wave, spawn cadence, boss
##              scheduling, victory state, the intensity signal.
##   Does NOT own: how an enemy is instantiated or placed (Spawner), run stats
##              such as kills and XP (Main), or player state (Player).
##   Calls down to: Spawner.spawn().
##   Signals up: wave_changed, intensity_changed, boss_spawned, boss_defeated,
##              victory.
##
## Invariants:
##   1. Boss event i fires exactly once, in order, never before its time.
##   2. `victory` is emitted at most once per run, on the FIRST boss event
##      cleared. Continuing into endless can never revoke it.
##   3. Cadence spawns never push living enemies past Difficulty.MAX_ALIVE.
##      Bosses are scheduled rather than spawned by cadence and are exempt.
##   4. Same seed + same schedule => same spawn sequence.
##
## Failure mode: `can_spawn()` is false at the cap, with no schedule, or when no
##   wave covers the current time. A schedule with a gap degrades to "nothing
##   spawns" — never a crash, never a partially-applied wave.
##
## Done when: a full run reaches the boss and can be won; victory banks and
##   offers Restart or Continue; endless reaches the double boss.

signal wave_changed(wave: WaveResource)
signal intensity_changed(level: int)
signal boss_spawned(boss: Node2D)
signal boss_defeated(bosses_remaining: int)
## Emitted once, the first time a boss event is fully cleared.
signal victory(event_index: int)
## Emitted EVERY time a boss event is fully cleared, including the first.
##
## `victory` is once per run by design — continuing into endless must never be
## able to revoke it — and that had a consequence nobody had noticed: killing
## NOGAXEH produced NOTHING. No screen, no stinger, no acknowledgement that the
## player had just finished the hardest fight in the game, because `victory` had
## already fired at 5:00. The true ending hangs off this.
signal boss_event_cleared(event_index: int)

## Bosses read as the threat only if the adds thin out, so while one is alive the
## normal cadence is stretched. Boss-tier intensity for the audio layer.
const BOSS_INTENSITY: int = 3

@export var schedule: RunSchedule
@export var boss_scene: PackedScene
## NOGAXEH. Spawned instead of a fourth Prism at the 10:00 event.
@export var mirror_scene: PackedScene

## Wired by Main at _ready (call down).
var spawner: Spawner
var target: Node2D
## The player's level, pushed by Main each tick. The director owns pacing and has
## no business reaching into the run's stats; this is a value crossing down, the
## same way the run clock crosses into Telemetry.
var player_level: int = 1
var boss_container: Node2D
var bolt_container: Node2D
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

var elapsed: float = 0.0
var bosses_alive: int = 0

var _cooldown: float = 0.0
var _wave: WaveResource
var _next_boss_event: int = 0
var _intensity: int = -1
var _won: bool = false
## type id -> living count, for EnemyStats.max_alive.
var _alive_by_type: Dictionary = {}


func _physics_process(delta: float) -> void:
	if schedule == null or not is_instance_valid(target):
		return
	elapsed += delta
	_update_wave()
	_check_boss_event()
	_tick_spawns(delta)


## False whenever a cadence spawn must not happen. Checked before every spawn so
## an incomplete schedule degrades quietly instead of erroring.
func can_spawn() -> bool:
	if _wave == null or _wave.types.is_empty() or spawner == null:
		return false
	if mirror_active():
		return false  # the mirror fight is the mirror and its Prisms, nothing else
	return Difficulty.should_spawn(spawner.alive_count())


func _update_wave() -> void:
	var next: WaveResource = schedule.wave_at(elapsed)
	if next == _wave:
		return
	_wave = next
	if _wave != null:
		_cooldown = minf(_cooldown, _wave.spawn_interval)
		wave_changed.emit(_wave)
	_publish_intensity()


## Boss tier overrides the wave's own tier, so the music escalates for the fight
## and settles back to whatever the wave asked for afterwards.
func _publish_intensity() -> void:
	var level: int
	if is_instance_valid(_mirror):
		# The mirror overrides boss tier entirely: its whole texture is dread, and
		# a full four-stem mix arriving with it would say "big fight" when the
		# intent is "something is very wrong and it is not hurrying".
		level = MIRROR_INTENSITY[clampi(_mirror.phase - 1, 0, MIRROR_INTENSITY.size() - 1)]
	elif bosses_alive > 0:
		level = BOSS_INTENSITY
	else:
		level = _wave.intensity if _wave != null else 0
	if level == _intensity:
		return
	_intensity = level
	intensity_changed.emit(level)


func _tick_spawns(delta: float) -> void:
	if _wave == null:
		return
	_cooldown -= delta
	if _cooldown > 0.0:
		return
	# Burn the cooldown even when we decline to spawn, so a full arena throttles
	# itself rather than banking a backlog to dump the moment space frees up.
	if can_spawn():
		var stats: EnemyStats = _wave.pick_type(rng)
		# Review finding 11: _has_room_for and _track had ZERO callers, so
		# EnemyStats.max_alive was dead data — the Shard's authored cap of 4 was
		# never enforced in any of the four endless waves it appears in, and
		# gen_waves.gd's comment claims the cap "is now data rather than a rule
		# someone has to remember". Re-pick ONCE on a full type rather than
		# skipping the spawn, so a capped type throttles itself instead of
		# throttling the whole wave.
		if stats != null and not _has_room_for(stats):
			stats = _wave.pick_type(rng)
		if stats != null and _has_room_for(stats):
			var spawned: Enemy = spawner.spawn(stats, _wave.hp_mult,
					rng.randf() < _wave.elite_chance)
			if spawned != null:
				_track(stats.id, spawned)
	var interval: float = _wave.spawn_interval
	if bosses_alive > 0:
		interval /= maxf(0.05, schedule.boss_spawn_throttle)
	_cooldown = interval


## Per-type cap. Some types are fun in small numbers and miserable in a swarm.
func _has_room_for(stats: EnemyStats) -> bool:
	if stats.max_alive <= 0:
		return true
	return int(_alive_by_type.get(stats.id, 0)) < stats.max_alive


## Counted on spawn, released on tree_exited — which fires however the enemy
## leaves (killed, freed on restart), so the count cannot drift.
func _track(id: StringName, enemy: Enemy) -> void:
	_alive_by_type[id] = int(_alive_by_type.get(id, 0)) + 1
	enemy.tree_exited.connect(func() -> void:
		_alive_by_type[id] = maxi(0, int(_alive_by_type.get(id, 0)) - 1))


## The 10:00 event is NOGAXEH plus two elite Prisms — not four Prisms.
##
## Four copies of the same boss is not a mirror match, and DECISIONS.md already
## recorded the rule this follows: "when distinct boss types exist, later events
## should swap in new ones rather than stacking more Prisms."
const MIRROR_EVENT: int = 1
## The escorts are FULL-STRENGTH Prisms now (M7.2). `ESCORT_HP = 0.5` is gone,
## and so is the reasoning that produced it: it budgeted the mirror event as a
## RATIO to the 5:00 event, arguing that 1.9x the 5:00 fight is "the ~2 minute
## climax". Measured on the first clean human run, the 5:00 event took 49s and
## the 1.9x-larger 10:00 event took **22 seconds**, because the player's DPS
## roughly quadrupled in between. A fight is budgeted in SECONDS at measured
## DPS or it is not budgeted at all.
##
## Two at the start, four more at the final phase: 6 x 2400 plus Nogaxeh's 4000
## is 18,400 base for the event. Full strength because the thing the player beat
## at 5:00 returning as a MINION only lands unweakened.
##
## 2026-08-03: that base was 11,200 until `prism.tres:max_hp` doubled to 2400 for
## the 5:00 fight. The escorts ARE Prisms, so the climax inherited the change and
## grew 64% — accepted deliberately, not overlooked, but it is UNMEASURED. The
## last soak put a four-weapon run at 212s against a ~120s target; that number
## now describes a fight that no longer exists. Re-soak before trusting it.
const MIRROR_ESCORTS_OPENING: int = 2
const MIRROR_ESCORTS_FINAL: int = 4
## Phase 1 is the opening escort pair; phase 4 is the last stand.
const MIRROR_FINAL_PHASE: int = 4
## Music tier per mirror phase. It THINS OUT to bass on arrival and rebuilds one
## element at a time as the fight escalates — dread first, then the mix fills
## back in. Cheap: Music already crossfades four stems on this signal.
const MIRROR_INTENSITY: Array[int] = [0, 1, 3, 3]

var _mirror: Boss
var _mirror_hp_scale: float = 1.0
var _final_wave_sent: bool = false
var _escorts_alive: int = 0


func _check_boss_event() -> void:
	if boss_scene == null or elapsed < schedule.boss_time(_next_boss_event):
		return
	var event: int = _next_boss_event
	_next_boss_event += 1
	var hp_scale: float = (1.0 + float(event) * 0.4) * _power_mult()
	if event == MIRROR_EVENT and mirror_scene != null:
		# The mirror event's HP is AUTHORED (4000 + 6 x 2400), so it skips the
		# per-event step that scales repeat Prism events in endless — and it
		# scales by LEVEL rather than by weapon count. See _mirror_mult.
		var scale: float = _mirror_mult()
		_mirror = _spawn_boss(mirror_scene, 0, 1, event, scale, false)
		_mirror_hp_scale = scale
		if _mirror != null:
			_mirror.phase_changed.connect(_on_mirror_phase.bind(event))
			# Shielded from the first frame, with the pair already on their way:
			# phase 1 is "kill the two Prisms", and the shield is what says so
			# without a line of text.
			_mirror.raise_shield()
			_spawn_escorts(event, MIRROR_ESCORTS_OPENING)
	else:
		# ONE boss for a duel event. A 1v1 cannot have escorts, and the count is
		# forced HERE rather than by removing extras afterwards: bosses_alive is
		# incremented in _spawn_boss and decremented only by a death, so a boss
		# taken out of the fight any other way would leave the count non-zero and
		# the event would never clear.
		var count: int = 1 if duels(event) else schedule.bosses_at_event(event)
		for i: int in count:
			_spawn_boss(boss_scene, i, count, event, hp_scale, false)
	_publish_intensity()


## Phase 4: four more full Prisms arrive AND the mirror shields itself again.
##
## The shield is what stops the escorts from being ignorable. Without it the
## optimal play is to tunnel the boss and eat the chip damage; with it, the
## pentagon the player beat at 5:00 has to be beaten again, as a minion, before
## the mirror can be touched.
func _on_mirror_phase(new_phase: int, event: int) -> void:
	_publish_intensity()
	if new_phase < MIRROR_FINAL_PHASE or _final_wave_sent:
		return
	_final_wave_sent = true
	# DEFERRED. `phase_changed` is emitted from inside Boss.take_hit, which is
	# itself called from Projectile._on_body_entered — a physics flush. Adding a
	# CharacterBody2D there throws "Can't change this state while flushing
	# queries", which is the exact trap DECISIONS.md records for Prism Core and
	# Chain Lightning. Every boss spawn triggered by damage must be deferred.
	_spawn_final_wave.call_deferred(event)


func _spawn_final_wave(event: int) -> void:
	_spawn_escorts(event, MIRROR_ESCORTS_FINAL)
	# Raised only once the escorts actually exist, or a single frame of
	# "invulnerable with nothing to kill" would read as the game hanging.
	if is_instance_valid(_mirror):
		_mirror.raise_shield()


## Full-strength Prisms, spread around the arena. Elite is FALSE now: an elite
## multiplier on top of full health would put the pair well past the boss the
## player beat at 5:00, and the point is that it is the same boss coming back.
func _spawn_escorts(event: int, count: int) -> void:
	for i: int in count:
		var minion: Boss = _spawn_boss(boss_scene, i, count, event,
				_mirror_hp_scale, false, true)
		if minion != null:
			_escorts_alive += 1
			minion.died.connect(_on_escort_died)


## The gate on both shielded phases. Phase 1 hands the fight over; phase 4 lights
## the fuse and the run is decided in the next five seconds.
func _on_escort_died(_xp_value: int, _at: Vector2, _tint: Color) -> void:
	_escorts_alive = maxi(0, _escorts_alive - 1)
	if _escorts_alive > 0 or not is_instance_valid(_mirror):
		return
	var mirror: Nogaxeh = _mirror as Nogaxeh
	if mirror == null:
		_mirror.drop_shield()
	elif mirror.phase >= MIRROR_FINAL_PHASE:
		mirror.begin_fuse()
	else:
		mirror.escorts_cleared()


## True while the mirror fight is running. NOTHING ELSE SPAWNS for its whole
## duration (spec, M7.2): the six Prisms are the only company, which is what lets
## their guaranteed health drops be the fight's entire sustain and what makes one
## enormous shape holding still opposite you land as dread rather than as noise.
## Boss events that resolve as a FIRST-PERSON DUEL instead of an arena fight.
##
## EVENT 0 ONLY, and that is a deliberate limit rather than an oversight. The
## MIRROR event's escorts are load-bearing: Nogaxeh is invulnerable through phase 1
## until they die, so an event that suppressed them would spawn a boss that cannot
## be damaged in the arena at all. Making 10:00 duel needs its own pass over that
## shield gate, not a wider entry in this array.
##
## Endless repeats of the Prism event (2, 3, ...) stay arena fights too: back-to-
## back duels every five minutes would make the pacing of a long run one shape.
@export var duel_events: PackedInt32Array = PackedInt32Array([0])


func duels(event: int) -> bool:
	return duel_events.has(event)


## Which boss event is currently live, or -1 before the first one.
##
## `_next_boss_event` is incremented BEFORE the bosses spawn, so the live event is
## always one behind it. Public because Main has to know whether the boss it was
## just handed belongs to a duel, and the boss_spawned signal deliberately carries
## only the boss.
func active_boss_event() -> int:
	return _next_boss_event - 1


func mirror_active() -> bool:
	return is_instance_valid(_mirror)


## Returns the boss so callers can keep a handle on it — the mirror fight needs
## one to hang its phase logic, escorts and shield off.
func _spawn_boss(scene: PackedScene, index: int, count: int, event: int,
		hp_mult: float, elite: bool, escort: bool = false) -> Boss:
	var boss: Boss = scene.instantiate()
	# Spread multiple bosses evenly around the arena so a double-boss event is a
	# positioning problem rather than one overlapping blob of hitboxes.
	var angle: float = TAU * (float(index) / float(maxi(1, count))) - PI * 0.5
	boss.position = spawner.ring_position(angle)
	boss.configure(target, hp_mult, elite)
	# Never let an event's bosses fire as one — see Boss.stagger.
	boss.stagger(float(index) * 0.45)
	boss.bolt_container = bolt_container
	# BEFORE the signal: Main's `boss_spawned` handler accumulates the boss bar's
	# denominator, so a flag set after the emit would arrive one boss too late.
	boss.is_escort = escort
	bosses_alive += 1
	boss.died.connect(_on_boss_died.bind(event))
	boss_container.add_child(boss)
	boss_spawned.emit(boss)
	return boss


## Boss HP scales with how many weapons the player actually has.
##
## It previously scaled by EVENT INDEX ALONE, which meant a first-timer holding
## only the blaster and a returning player with four stacked weapons fought the
## identical 1800 HP. Those profiles are several times apart in DPS, so one
## number could not serve both: measured 2026-08-02, a three-weapon profile
## deleted the 5:00 boss in SEVEN seconds, while the same wall would be
## unwinnable for the stranger the prime directive is written about.
##
## Only the BOSS scales this way. Trash HP stays on the time curve — enemies that
## grow because you got stronger read as the game cheating, whereas a boss doing
## it reads as the boss rising to meet you.
##
## The 0.75 step and prism.tres's base HP are first estimates. They are meant to
## produce a ~60s fight and are expected to move after the next human playtest;
## the MECHANISM is the part that matters here, not the constant.
const POWER_STEP: float = 0.75


func _power_mult() -> float:
	if target == null or not target.has_method(&"active_weapon_count"):
		return 1.0
	var weapons: int = int(target.call(&"active_weapon_count"))
	return 1.0 + POWER_STEP * float(maxi(0, weapons - 1))


## The mirror event scales by LEVEL, not by weapon count, and that change was
## forced by measurement rather than argued.
##
## Weapon count was a fair proxy for DPS while weapons came from the PROFILE: a
## player either owned three or owned one, all run, and the number was known the
## instant a boss spawned. M7.3 made weapons drafted, and the proxy came apart in
## both directions at once. Soaked 2026-08-02, when the event's base was 11,200
## (six 1200 HP escorts) — the ratio between the two rows is the finding, and it
## survives the rebase; the absolute seconds do not:
##
##   blaster only, level 91 -> 11,200 HP died in **32 seconds** (target ~120)
##   four weapons, level 77 -> 36,400 HP took **212 seconds**
##
## The one-weapon player was not weak, they had spent all 30 picks on the blaster;
## the four-weapon player was not four times stronger, they had spent picks
## acquiring weapons instead of sharpening one. LEVEL sees all of that at once —
## it counts the drip, the picks, and how well the run has actually gone — and it
## is still discrete, known at spawn time, and unable to drift mid-fight.
##
## Below MIRROR_LEVEL_BASE the fight is exactly the authored base — 18,400 since
## the 2026-08-03 Prism doubling, 11,200 when the 4.5% step was fitted. Every
## level above it adds 4.5%, which against the measured ~350 DPS of a level-90
## run put the climax near the two minutes the spec asked for AT THE OLD BASE.
## The step was never re-fitted, so it is now aimed at a fight 64% larger.
const MIRROR_LEVEL_BASE: int = 40
const MIRROR_LEVEL_STEP: float = 0.045


func _mirror_mult() -> float:
	return 1.0 + MIRROR_LEVEL_STEP * float(maxi(0, player_level - MIRROR_LEVEL_BASE))


func _on_boss_died(_xp_value: int, _at: Vector2, _tint: Color, event: int) -> void:
	bosses_alive = maxi(0, bosses_alive - 1)
	boss_defeated.emit(bosses_alive)
	if bosses_alive == 0:
		boss_event_cleared.emit(event)
		if not _won:
			_won = true
			victory.emit(event)
	_publish_intensity()
