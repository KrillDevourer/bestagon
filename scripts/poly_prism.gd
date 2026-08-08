class_name PolyPrism
extends RefCounted
## Procedural n-sided prism — the solid body a boss gets when the arena tilts.
##
## PARAMETERISED, and it was not at first. This shipped as `HexPrism` with a
## hardcoded six sides, which put a HEXAGON under THE PRISM. Two things wrong
## with that, and neither of them errors:
##
##   1. The Prism's sprite is a PENTAGON. tools/gen_assets.py says why -- "five
##      sides, the shape that came closest to being a hexagon and did not". A
##      six-sided solid standing on a five-sided footprint is simply the wrong
##      boss.
##   2. Worse, the hexagon is RESERVED. gen_assets.py: the player is the only
##      hexagon in the game, "nothing else may claim six sides", until NOGAXEH at
##      10:00 -- "and the break IS the reveal". A hexagonal Prism at 5:00 hands
##      the player's own silhouette to a boss and spends the reveal five minutes
##      before the game means to.
##
## So the side count is data, and it comes from the boss. Named PolyPrism and not
## PrismMesh because Godot already ships a `PrismMesh` (a wedge), and shadowing an
## engine class reads fine right up until someone types the built-in name.
##
## WHY GENERATED AND NOT MODELLED. The repo's headline claim is that every asset
## is regenerable from a clone -- sprites from Pillow, every note from Strudel
## source. A committed .glb would be the first thing here a stranger could not
## rebuild, and it would quietly falsify the sentence the README leads with. An
## n-gon prism is n quads and two fans; it does not need an art pipeline.
##
## ORIENTATION: the polygon lies in XZ with the axis along Y, so viewed from
## straight above it is exactly the shape the 2D game has always shown. That is
## the whole trick of the boss transition -- at zero tilt the solid is
## indistinguishable from the sprite it replaces, and leaning the camera is what
## reveals it was a solid the entire time.
##
## Flat-shaded: vertices are duplicated per facet AND smooth group -1, so
## `generate_normals` gives one normal per face rather than smoothing the
## silhouette into a cylinder. A boss is a cut gem, not a can.

## The Prism, which is the boss this exists for. Nogaxeh overrides it to 6.
const DEFAULT_SIDES: int = 5
## Below 3 there is no polygon. Clamped rather than asserted so a bad authored
## value produces a triangle instead of taking the run down mid-boss.
const MIN_SIDES: int = 3


## A closed prism, centred on its own origin.
##
## `radius` is the circumradius -- the distance to a CORNER, not to a flat. Stated
## because picking the wrong one is how a boss ends up visibly smaller than the
## sprite it replaced.
static func build(radius: float, height: float, sides: int = DEFAULT_SIDES) -> ArrayMesh:
	var n: int = maxi(MIN_SIDES, sides)
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# FLAT SHADING IS NOT THE DEFAULT, and not adding an index array does not buy
	# it. `generate_normals` averages across every vertex that shares a POSITION,
	# so the cap rims and the side walls meeting at the same corners had their
	# normals blended together -- 33 vertices ended up facing +Y where 18 should
	# have, and the crisp edge between lid and wall rounded off into a bevel.
	# Smooth group -1 means "this facet smooths with nothing".
	st.set_smooth_group(-1)
	var half: float = height * 0.5
	_add_sides(st, n, radius, half)
	_add_cap(st, n, radius, half, true)
	_add_cap(st, n, radius, -half, false)
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


## Corner `index` of the polygon, on the XZ plane.
##
## Public and static so a caller can place something ON a corner without
## re-deriving the angle convention and landing out of phase with the shape it
## belongs to.
static func corner(index: int, radius: float, y: float,
		sides: int = DEFAULT_SIDES) -> Vector3:
	var n: int = maxi(MIN_SIDES, sides)
	var angle: float = TAU * float(index) / float(n)
	return Vector3(cos(angle) * radius, y, sin(angle) * radius)


static func _add_sides(st: SurfaceTool, n: int, radius: float, half: float) -> void:
	for i: int in n:
		var top_a: Vector3 = corner(i, radius, half, n)
		var top_b: Vector3 = corner(i + 1, radius, half, n)
		var bot_a: Vector3 = corner(i, radius, -half, n)
		var bot_b: Vector3 = corner(i + 1, radius, -half, n)
		# U walks the band once around; V is 0 at the top so the texture is not
		# upside down on a solid whose "up" is meaningful.
		var u0: float = float(i) / float(n)
		var u1: float = float(i + 1) / float(n)
		_tri(st, top_a, bot_a, bot_b, Vector2(u0, 0.0), Vector2(u0, 1.0), Vector2(u1, 1.0))
		_tri(st, top_a, bot_b, top_b, Vector2(u0, 0.0), Vector2(u1, 1.0), Vector2(u1, 0.0))


## One end, as a fan from the centre. `up` flips the winding so both caps face
## outward -- a cap wound the same way as the other is invisible from outside and
## visible from within, which looks like a hole rather than like a bug.
##
## GODOT FRONT FACES ARE CLOCKWISE, viewed from outside. Both fans were wound the
## other way in the first pass and the boss rendered as an open cup: back-face
## culling removed the caps, so the camera looked straight through the lid at the
## INSIDE of the far wall. It threw no error and passed every topology test in the
## suite -- the counts were all correct, the solid was simply inside out.
## `test_every_normal_points_away_from_the_centre` is the test that now fails
## instead of a screenshot looking odd.
##
## Viewed from above, increasing corner index runs clockwise, so the top fan is
## (centre, i, i+1) and the bottom -- seen from below, where the same order looks
## anticlockwise -- is its mirror.
static func _add_cap(st: SurfaceTool, n: int, radius: float, y: float,
		up: bool) -> void:
	var centre: Vector3 = Vector3(0.0, y, 0.0)
	for i: int in n:
		var a: Vector3 = corner(i, radius, y, n)
		var b: Vector3 = corner(i + 1, radius, y, n)
		var uv_c: Vector2 = Vector2(0.5, 0.5)
		var uv_a: Vector2 = Vector2(a.x, a.z) / (radius * 2.0) + uv_c
		var uv_b: Vector2 = Vector2(b.x, b.z) / (radius * 2.0) + uv_c
		if up:
			_tri(st, centre, a, b, uv_c, uv_a, uv_b)
		else:
			_tri(st, centre, b, a, uv_c, uv_b, uv_a)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		uv_a: Vector2, uv_b: Vector2, uv_c: Vector2) -> void:
	st.set_uv(uv_a)
	st.add_vertex(a)
	st.set_uv(uv_b)
	st.add_vertex(b)
	st.set_uv(uv_c)
	st.add_vertex(c)


## Triangles in a built prism: n side quads plus two n-triangle fans.
##
## Exists so the unit test asserts against a DERIVED number rather than a literal
## someone would have to recount by hand after changing the side count.
static func triangle_count(sides: int = DEFAULT_SIDES) -> int:
	var n: int = maxi(MIN_SIDES, sides)
	return n * 2 + n * 2
