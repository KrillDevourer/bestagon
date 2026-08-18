class_name Hud
extends CanvasLayer
## Read-only view of the run. Main pushes values in (call down);
## the HUD never reaches into gameplay.

@onready var hp_bar: ProgressBar = %HpBar
@onready var hp_label: Label = %HpLabel
@onready var xp_bar: ProgressBar = %XpBar
@onready var level_label: Label = %LevelLabel
@onready var time_label: Label = %TimeLabel
@onready var kills_label: Label = %KillsLabel
@onready var buffs_row: HBoxContainer = %BuffsRow
@onready var boss_panel: VBoxContainer = %BossPanel
@onready var boss_name: Label = %BossName
@onready var boss_bar: ProgressBar = %BossBar
@onready var banner: Label = %Banner
@onready var toast: Label = %LevelToast
@onready var dash_label: Label = %DashLabel
@onready var dash_pip: ProgressBar = %DashPip
@onready var target_markers: TargetMarkers = %TargetMarkers

## Buff labels are POOLED, not rebuilt: this updates every frame, and churning
## Controls at 60Hz to show three words is the kind of thing that is invisible
## until it is not.
var _buff_labels: Array[Label] = []
## Guards the shield readout so it is not rebuilt every physics frame.
var _shielded: bool = false
## The boss's NAME, held separately from what the label currently reads. The two
## are not the same thing: while shielded, the label shows the warning instead —
## see render_boss_name.
var _boss_label: String = ""
## Bodies still gating a shielded boss. -1 means "unknown", which keeps the old
## wording rather than printing a count nobody supplied.
var _gate_left: int = -1


func set_health(hp: int, max_hp: int) -> void:
	hp_bar.max_value = max_hp
	hp_bar.value = hp
	hp_label.text = "%d/%d" % [hp, max_hp]


func set_xp(into_level: int, required: int, level: int) -> void:
	xp_bar.max_value = required
	xp_bar.value = into_level
	level_label.text = "LV %d" % level


## `entries` is [{name: String, left: float}], longest-lived first.
func set_buffs(entries: Array) -> void:
	while _buff_labels.size() < entries.size():
		var label := Label.new()
		label.add_theme_color_override(&"font_color", Color(0.62, 1.0, 0.95))
		buffs_row.add_child(label)
		_buff_labels.append(label)
	for i: int in _buff_labels.size():
		var label: Label = _buff_labels[i]
		if i < entries.size():
			label.text = "%s %.0fs" % [entries[i]["name"], ceilf(float(entries[i]["left"]))]
			label.visible = true
		else:
			label.visible = false


func set_run(time_survived: float, kills: int) -> void:
	var minutes: int = int(time_survived) / 60
	var seconds: int = int(time_survived) % 60
	time_label.text = "%02d:%02d" % [minutes, seconds]
	kills_label.text = "%d kills" % kills


## Boss progress. Review finding 3: the 5:00 event — the run's WIN CONDITION —
## arrived with no name, no bar, and no readout of any kind. Two Prisms at 900 HP
## each, and the only progress marker in the whole fight was the shard detach at
## 50%. A player could not tell whether they were winning.
##
## One bar for the whole EVENT, not one per boss: at 10:00 there are three bodies
## on screen and three bars would be noise. "How much of this fight is left" is
## the question being answered.
func set_boss(name_text: String, hp: int, max_hp: int) -> void:
	boss_panel.visible = true
	_boss_label = name_text
	boss_name.text = name_text
	boss_bar.max_value = maxi(1, max_hp)
	boss_bar.value = hp


func hide_boss() -> void:
	boss_panel.visible = false
	_shielded = false
	_gate_left = -1
	target_markers.clear()
	# Cleared with the panel, so the NEXT event cannot inherit the last one's
	# name if it ever hides before its own set_boss lands.
	_boss_label = ""


## The third layer of the shield indicator, after the membrane on the boss and
## the dull grey thud on blocked hits.
##
## A locked bar with an instruction, because a player watching a health bar
## refuse to move needs to be told WHY in the place they are already looking.
## Without this, "invulnerable boss" and "the game is broken" are the same
## experience, which is BRIEF defect #4.
## The shield state and the boss's NAME share one label, and they used to fight
## over it — with the shield always losing, at the only fight that has one.
## `set_boss_shielded` wrote its warning once and then latched `_shielded`, so it
## never wrote again; `flip_boss_name`'s tween fired ~0.6s later and overwrote
## the same label with NOGAXEH. The shield warning was destroyed at the exact
## moment it was needed, every single run (playtest 2026-08-03: "need indicator
## of invulnerability at the start of boss fight too").
##
## Fixed by making one function own what that label says, and having BOTH the
## flip and the shield toggle re-render through it. The reveal still plays — the
## name flip owns the label for its ~0.75s and then hands it back — so the
## sequence reads HEXAGON -> NOGAXEH -> SHIELDED, which is also the right order
## dramatically: who it is, then what to do about it.
func set_boss_shielded(shielded: bool, label: String = "",
		gate_left: int = -1) -> void:
	if label != "":
		_boss_label = label
	# The COUNT changes while `shielded` does not, so it cannot sit behind the
	# early-out below -- that guard exists to stop the label being rebuilt every
	# frame, and a counter that only refreshed when the shield toggled would show
	# the number the fight started with until the last escort died.
	var count_changed: bool = gate_left != _gate_left
	_gate_left = gate_left
	if shielded == _shielded and not count_changed:
		return
	_shielded = shielded
	render_boss_name()


## The single writer. Anything that changes either half calls this.
func render_boss_name() -> void:
	if _shielded:
		# The count is the difference between an instruction and PROGRESS. "DESTROY
		# THE PRISMS" tells the player what to do and nothing about whether they
		# are getting anywhere; the arrows say where, and this says how many are
		# left to find.
		if _gate_left > 1:
			boss_name.text = "SHIELDED — %d PRISMS LEFT" % _gate_left
		elif _gate_left == 1:
			boss_name.text = "SHIELDED — 1 PRISM LEFT"
		else:
			boss_name.text = "SHIELDED — DESTROY THE PRISMS"
		boss_name.add_theme_color_override(&"font_color", Color(0.78, 0.75, 1.0))
		boss_bar.modulate = Color(0.55, 0.5, 0.62)
	else:
		boss_name.text = _boss_label
		boss_name.add_theme_color_override(&"font_color", Color(1, 0.6, 0.87))
		boss_bar.modulate = Color.WHITE


## The NOGAXEH reveal. The banner spells HEXAGON and then flips — a mirror boss
## whose name is the word mirrored, so the reveal is typography rather than a
## line of dialogue nobody reads mid-fight.
func flip_boss_name(from_text: String, to_text: String) -> void:
	_boss_label = from_text
	boss_name.text = from_text
	var tween: Tween = create_tween()
	tween.tween_interval(0.45)
	tween.tween_property(boss_name, "modulate:a", 0.0, 0.12)
	tween.tween_callback(func() -> void: boss_name.text = to_text)
	tween.tween_property(boss_name, "modulate:a", 1.0, 0.18)
	# Hand the label back to whoever owns it now. If the boss is shielded — and
	# NOGAXEH always is when this reveal plays — the warning returns instead of
	# staying buried under the name for the rest of the phase.
	tween.tween_callback(func() -> void:
		_boss_label = to_text
		render_boss_name())


## Centre-screen announcement. Exists because `Meta.unlocked` had ZERO listeners
## project-wide (review finding 2): unlocks were earned, saved and applied in
## total silence. The dash in particular MUST be announced — a player who wins
## and continues would otherwise walk into a bullet-hell boss never knowing they
## had been handed the dodge.
func announce(text: String) -> void:
	banner.text = text
	banner.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(banner, "modulate:a", 1.0, 0.22)
	tween.tween_interval(2.1)
	tween.tween_property(banner, "modulate:a", 0.0, 0.5)


## The quiet counterpart to `announce`. Two levels in three hand out no card, and
## before this the only evidence a level had happened at all was the level number
## changing — so the drip, which is most of the run's power, read as nothing.
## Deliberately small, deliberately beside the XP bar, deliberately short-lived:
## it must be readable without being an interruption, because it fires constantly.
func show_level_toast(level_reached: int, gains: Array[String]) -> void:
	toast.text = "LV %d   %s" % [level_reached, "  ".join(gains)]
	toast.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(toast, "modulate:a", 1.0, 0.12)
	tween.tween_interval(1.1)
	tween.tween_property(toast, "modulate:a", 0.0, 0.45)


## -1 means "not unlocked", which hides the readout entirely rather than showing
## a permanently empty pip a first-time player cannot interpret.
func set_dash(fraction: float) -> void:
	var owned: bool = fraction >= 0.0
	dash_label.visible = owned
	dash_pip.visible = owned
	if owned:
		dash_pip.value = fraction * 100.0
