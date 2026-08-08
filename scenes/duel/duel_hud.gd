class_name DuelHud
extends CanvasLayer
## The duel's only UI: how much health each side has left. NO CROSSHAIR.
##
## The weapon fires itself along the view, so there is no shot to place and nothing
## for a reticle to promise. A crosshair would also be the first pixel in this game
## that exists to help you aim, in a game whose first line about play is "Move;
## your weapons fire themselves".
##
## A CanvasLayer, so it renders in screen space and is untouched by the 3D camera.
## Built in code rather than authored because it is two bars and two labels, and a
## .tscn of that is four nodes of anchor arithmetic nobody will ever read.
##
## SIZED FOR 640x360, like every other screen in this project. The viewport is 640
## wide and the window is a canvas_items stretch of it, so a bar specified in
## fractions of the viewport survives any window size -- and anything specified in
## window pixels would be half the size it should be at 1280x720.

## Bar geometry as fractions of the viewport, so nothing here is a window pixel.
const BOSS_BAR_WIDTH: float = 0.56
const PLAYER_BAR_WIDTH: float = 0.30
const BAR_HEIGHT: float = 7.0
const MARGIN: float = 10.0

## The player's cyan and a boss's own tint from the colour law. The player bar is
## never the boss's colour and vice versa -- hue carries allegiance in this game,
## and a health bar is the one place the player must never have to think about it.
const PLAYER_TINT: Color = Color(0.35, 0.95, 1.0)
## Drained portion. Dark rather than red: red is not in this game's palette, and a
## red remainder would introduce a hue the colour law has no slot for.
const EMPTY_TINT: Color = Color(0.14, 0.14, 0.22)

var boss_tint: Color = Color(1.0, 0.42, 0.85)
var boss_title: String = "THE PRISM"

var _boss_fill: ColorRect
var _boss_back: ColorRect
var _boss_label: Label
var _player_fill: ColorRect
var _player_back: ColorRect
var _player_label: Label

var _boss_max: int = 1
var _player_max: int = 1


func _ready() -> void:
	# ALWAYS, so the bars stay drawn while the tree is paused. A death or a modal
	# pauses the game and a HUD that vanishes at that moment takes the one piece of
	# information the player needs to understand what just happened.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_boss_bar()
	_build_player_bar()


func _build_boss_bar() -> void:
	_boss_label = Label.new()
	_boss_label.text = boss_title
	_boss_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_label.anchor_left = 0.5 - BOSS_BAR_WIDTH * 0.5
	_boss_label.anchor_right = 0.5 + BOSS_BAR_WIDTH * 0.5
	_boss_label.offset_top = MARGIN
	_boss_label.offset_bottom = MARGIN + 14.0
	_boss_label.modulate = boss_tint
	add_child(_boss_label)

	_boss_back = ColorRect.new()
	_boss_back.color = EMPTY_TINT
	_boss_back.anchor_left = 0.5 - BOSS_BAR_WIDTH * 0.5
	_boss_back.anchor_right = 0.5 + BOSS_BAR_WIDTH * 0.5
	_boss_back.offset_top = MARGIN + 15.0
	_boss_back.offset_bottom = MARGIN + 15.0 + BAR_HEIGHT
	add_child(_boss_back)

	# A child of the backing rect, so setting anchor_right is all that drains it and
	# no arithmetic has to know where the bar sits on screen.
	_boss_fill = ColorRect.new()
	_boss_fill.color = boss_tint
	_boss_fill.anchor_right = 1.0
	_boss_fill.anchor_bottom = 1.0
	_boss_back.add_child(_boss_fill)


func _build_player_bar() -> void:
	_player_back = ColorRect.new()
	_player_back.color = EMPTY_TINT
	_player_back.anchor_left = 0.0
	_player_back.anchor_right = PLAYER_BAR_WIDTH
	_player_back.anchor_top = 1.0
	_player_back.anchor_bottom = 1.0
	_player_back.offset_left = MARGIN
	_player_back.offset_top = -(MARGIN + BAR_HEIGHT)
	_player_back.offset_bottom = -MARGIN
	add_child(_player_back)

	_player_fill = ColorRect.new()
	_player_fill.color = PLAYER_TINT
	_player_fill.anchor_right = 1.0
	_player_fill.anchor_bottom = 1.0
	_player_back.add_child(_player_fill)

	_player_label = Label.new()
	_player_label.anchor_left = PLAYER_BAR_WIDTH
	_player_label.anchor_right = PLAYER_BAR_WIDTH
	_player_label.anchor_top = 1.0
	_player_label.anchor_bottom = 1.0
	_player_label.offset_left = MARGIN + 6.0
	_player_label.offset_top = -(MARGIN + BAR_HEIGHT + 6.0)
	_player_label.offset_bottom = -MARGIN
	_player_label.modulate = PLAYER_TINT
	add_child(_player_label)


## Both setters take max as well as current, so the bars cannot be initialised in
## one place and updated in another with two different ideas of full. Carapace
## raises the player's max mid-run and the 2D HUD had to learn that the hard way.
func set_boss_health(hp: int, max_hp: int) -> void:
	_boss_max = maxi(1, max_hp)
	_boss_fill.anchor_right = clampf(float(hp) / float(_boss_max), 0.0, 1.0)


func set_player_health(hp: int, max_hp: int) -> void:
	_player_max = maxi(1, max_hp)
	_player_fill.anchor_right = clampf(float(hp) / float(_player_max), 0.0, 1.0)
	_player_label.text = "%d/%d" % [maxi(0, hp), _player_max]


## What the player sees when it is over. Deliberately the only two words this HUD
## says beyond numbers: the run's own victory and game-over screens own everything
## that happens next, and a duel that editorialised would be a second voice.
func show_outcome(won: bool) -> void:
	var banner: Label = Label.new()
	banner.text = "PRISM SHATTERED" if won else "YOU DIED"
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.anchor_left = 0.0
	banner.anchor_right = 1.0
	banner.anchor_top = 0.42
	banner.anchor_bottom = 0.42
	banner.offset_bottom = 24.0
	banner.modulate = PLAYER_TINT if won else boss_tint
	add_child(banner)
