class_name HexPrism
extends RefCounted
## Procedural hexagonal prism — THE PRISM, as an actual solid.
##
## Named HexPrism and not PrismMesh because Godot already ships a `PrismMesh`
## (a wedge), and shadowing an engine class is the kind of thing that reads fine
## until someone types the built-in name and gets this instead.
##
## WHY GENERATED AND NOT MODELLED. The repo's headline claim is that every asset
## is regenerable from a clone — sprites from Pillow, every note from Strudel
## source. A committed .glb would be the first thing here that a stranger could
## not rebuild, and it would quietly falsify the sentence the README leads with.
## A hexagonal prism is six quads and two fans; it does not need an art pipeline.
##
## ORIENTATION: the hex lies in XZ with the axis along Y, so viewed from straight
## above it is exactly the hexagon the 2D game has always shown. That is the whole
## trick of the boss transition — at zero tilt the solid is indistinguishable from
## the sprite it replaces, and leaning the camera is what reveals it was a solid
## the entire time.
##
## Flat-shaded on purpose: vertices are duplicated per face and never shared, so
## `generate_normals` produces one normal per facet rather than smoothing the
## silhouette into a cylinder. The Prism is a cut gem, not a can.

const SIDES: int = 6


## A closed hexagonal prism, centred on its own origin.
##
## `radius` is the circumradius — the distance to a CORNER, not to a flat. Stated
## because the two differ by cos(30) = 0.866 here, and picking the wrong one is
## how a boss ends up 13% smaller than the sprite it replaced.
static func build(radius: float, height: float) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# FLAT SHADING IS NOT THE DEFAULT, and not adding an index array does not buy
	# it. `generate_normals` averages across every vertex that shares a POSITION,
	# so the cap rims and the side walls meeting at the same six corners had their
	# normals blended together — 33 vertices ended up facing +Y where 18 should
	# have, and the crisp edge between lid and wall rounded off into a bevel.
	# Smooth group -1 means "this facet smooths with nothing".
	st.set_smooth_group(-1)
	var half: float = height * 0.5
	_add_sides(st, radius, half)
	_add_cap(st, radius, half, true)
	_add_cap(st, radius, -half, false)
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


## Corner `i` of the hexagon, on the XZ plane.
##
## Public and static so a caller can place something ON a corner — the orbiting
## shards need exactly this — without re-deriving the angle convention and
## landing half a step out of phase with the body.
static func corner(index: int, radius: float, y: float) -> Vector3:
	var angle: float = TAU * float(index) / float(SIDES)
	return Vector3(cos(angle) * radius, y, sin(angle) * radius)


static func _add_sides(st: SurfaceTool, radius: float, half: float) -> void:
	for i: int in SIDES:
		var top_a: Vector3 = corner(i, radius, half)
		var top_b: Vector3 = corner(i + 1, radius, half)
		var bot_a: Vector3 = corner(i, radius, -half)
		var bot_b: Vector3 = corner(i + 1, radius, -half)
		# U walks the band once around; V is 0 at the top so the texture is not
		# upside down on a solid whose "up" is meaningful.
		var u0: float = float(i) / float(SIDES)
		var u1: float = float(i + 1) / float(SIDES)
		_tri(st, top_a, bot_a, bot_b, Vector2(u0, 0.0), Vector2(u0, 1.0), Vector2(u1, 1.0))
		_tri(st, top_a, bot_b, top_b, Vector2(u0, 0.0), Vector2(u1, 1.0), Vector2(u1, 0.0))


## One end, as a fan from the centre. `up` flips the winding so both caps face
## outward — a cap wound the same way as the other is invisible from outside and
## visible from within, which looks like a hole rather than like a bug.
##
## GODOT FRONT FACES ARE CLOCKWISE, viewed from outside. Both fans were wound the
## other way in the first pass and the boss rendered as an open cup: back-face
## culling removed the caps, so the camera looked straight through the lid at the
## INSIDE of the far wall. It threw no error and passed every topology test in
## the suite — the counts were all correct, the solid was simply inside out.
## `test_every_normal_points_away_from_the_centre` is the test that now fails
## instead of a screenshot looking odd.
##
## Viewed from above, increasing corner index runs clockwise, so the top fan is
## (centre, i, i+1) and the bottom — seen from below, where the same order looks
## anticlockwise — is its mirror.
static func _add_cap(st: SurfaceTool, radius: float, y: float, up: bool) -> void:
	var centre: Vector3 = Vector3(0.0, y, 0.0)
	for i: int in SIDES:
		var a: Vector3 = corner(i, radius, y)
		var b: Vector3 = corner(i + 1, radius, y)
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


## Triangles in a built prism: 6 side quads plus two 6-triangle fans.
##
## Exists so the unit test asserts against a DERIVED number rather than a literal
## 24 someone would have to recount by hand after changing SIDES.
static func triangle_count() -> int:
	return SIDES * 2 + SIDES * 2
