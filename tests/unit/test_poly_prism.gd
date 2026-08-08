extends GutTest
## The generated boss solid. Pure geometry, so it tests like any other pure logic
## — PolyPrism.build returns an ArrayMesh and never touches a scene.
##
## Worth testing at all because a malformed mesh does not error. A prism with an
## inverted cap, a missing face, a radius measured to the wrong reference or the
## WRONG NUMBER OF SIDES still loads, still renders, and simply looks wrong on one
## frame of one boss fight — the most expensive kind of defect this project has,
## and the reason the pause layout gets a measuring harness instead of an eyeball.

const RADIUS: float = 1.0
const HEIGHT: float = 2.0

## Floating point on cos/sin corners: generous enough for trig, tight enough that
## a genuinely misplaced vertex still fails.
const EPS: float = 0.0001

## The two side counts the game actually builds.
const PRISM_SIDES: int = 5
const NOGAXEH_SIDES: int = 6


func _mesh(sides: int = PRISM_SIDES) -> ArrayMesh:
	return PolyPrism.build(RADIUS, HEIGHT, sides)


func _vertices(sides: int = PRISM_SIDES) -> PackedVector3Array:
	var arrays: Array = _mesh(sides).surface_get_arrays(0)
	return arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array


# --- the silhouette law -----------------------------------------------------

## THE ONE THAT CAUGHT A REAL BUG. This shipped hardcoded to six sides, which put
## a HEXAGON under THE PRISM — whose sprite is a pentagon, and whose six-sided
## solid also stole the one silhouette gen_assets.py reserves for the player
## ("nothing else may claim six sides") five minutes before NOGAXEH is supposed to
## break that rule as its reveal.
##
## So the default is five, and six has to be asked for on purpose.
func test_the_default_solid_is_a_pentagon_not_a_hexagon() -> void:
	assert_eq(PolyPrism.DEFAULT_SIDES, PRISM_SIDES,
			"the default boss solid must match THE PRISM's pentagon sprite")
	assert_ne(PolyPrism.DEFAULT_SIDES, NOGAXEH_SIDES,
			"six sides belong to the player and to Nogaxeh's reveal")


func test_side_count_is_honoured() -> void:
	for sides: int in [3, 4, 5, 6, 8, 12]:
		assert_eq(PolyPrism.triangle_count(sides), sides * 4)
		assert_eq(_vertices(sides).size(), sides * 4 * 3,
				"vertex total for %d sides" % sides)


## Corners must be DISTINCT, or a "pentagon" with a duplicated vertex still
## reports the right counts while rendering as a quad.
func test_a_pentagon_has_five_distinct_corners() -> void:
	var seen: Dictionary = {}
	for v: Vector3 in _vertices(PRISM_SIDES):
		# Cap centres sit on the axis and are not corners.
		if Vector2(v.x, v.z).length() < EPS:
			continue
		seen[Vector2(snappedf(v.x, 0.001), snappedf(v.z, 0.001))] = true
	assert_eq(seen.size(), PRISM_SIDES)


## Below 3 there is no polygon. Clamped rather than asserted, so bad authored data
## produces a triangle instead of taking the run down mid-boss.
func test_degenerate_side_counts_clamp_instead_of_crashing() -> void:
	assert_eq(PolyPrism.triangle_count(0), PolyPrism.MIN_SIDES * 4)
	assert_eq(_vertices(1).size(), PolyPrism.MIN_SIDES * 4 * 3)
	assert_eq(_vertices(-7).size(), PolyPrism.MIN_SIDES * 4 * 3)


# --- topology ---------------------------------------------------------------

func test_mesh_has_exactly_one_surface() -> void:
	assert_eq(_mesh().get_surface_count(), 1)


## Flat shading depends on vertices NOT being shared between facets. If someone
## "optimises" the builder into an indexed mesh, the silhouette smooths into a
## can and this is the test that says why that is not free.
func test_vertices_are_unshared_so_facets_stay_flat() -> void:
	var arrays: Array = _mesh().surface_get_arrays(0)
	assert_null(arrays[Mesh.ARRAY_INDEX],
			"an index array would mean shared vertices and smooth normals")


# --- dimensions -------------------------------------------------------------

## `radius` is the CIRCUMradius — corner distance, not flat distance. The sprite
## it has to match is measured corner to corner.
func test_radius_is_the_distance_to_a_corner() -> void:
	var far: float = 0.0
	for v: Vector3 in _vertices():
		far = maxf(far, Vector2(v.x, v.z).length())
	assert_almost_eq(far, RADIUS, EPS)


func test_height_is_total_not_half() -> void:
	var low: float = INF
	var high: float = -INF
	for v: Vector3 in _vertices():
		low = minf(low, v.y)
		high = maxf(high, v.y)
	assert_almost_eq(high - low, HEIGHT, EPS)


## Centred on its own origin, so a caller positions the boss by its middle and
## does not have to know the mesh's internal convention.
func test_prism_is_centred_on_its_origin() -> void:
	var low: float = INF
	var high: float = -INF
	for v: Vector3 in _vertices():
		low = minf(low, v.y)
		high = maxf(high, v.y)
	assert_almost_eq(low, -high, EPS)


## Catches an off-by-one in the angle step, which produces a lopsided polygon that
## still looks plausible in a thumbnail.
func test_every_side_vertex_lies_on_the_circumcircle() -> void:
	var off: int = 0
	for v: Vector3 in _vertices():
		var r: float = Vector2(v.x, v.z).length()
		# Cap centres are the one legitimate exception — they sit on the axis.
		if r > EPS and absf(r - RADIUS) > EPS:
			off += 1
	assert_eq(off, 0, "vertices off the circumcircle")


# --- winding ----------------------------------------------------------------

## Godot front faces are clockwise seen from outside, and the first build wound
## both caps the other way. Every count above still passed — the vertex total, the
## triangle total, the radius, the height — because the solid was the right solid,
## simply inside out. On screen the boss rendered as an open cup, because culling
## removed the lid and left the camera looking at the inside of the far wall.
##
## For any convex solid centred on its origin, an OUTWARD normal always points the
## same general way as the vertex it belongs to, so one dot product covers every
## face at once: sides, cap rims and cap centres alike.
func test_every_normal_points_away_from_the_centre() -> void:
	for sides: int in [PRISM_SIDES, NOGAXEH_SIDES]:
		var arrays: Array = _mesh(sides).surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
		assert_eq(normals.size(), verts.size(), "every vertex needs a normal")
		var inward: int = 0
		for i: int in verts.size():
			if normals[i].dot(verts[i]) <= 0.0:
				inward += 1
		assert_eq(inward, 0, "inward normals at %d sides: solid is inside out" % sides)


## The caps specifically, since they are the pair that was wrong and the dot
## product above would still pass if BOTH were flipped to point at each other.
func test_caps_face_opposite_ways() -> void:
	var arrays: Array = _mesh(PRISM_SIDES).surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
	var up: int = 0
	var down: int = 0
	for n: Vector3 in normals:
		if n.y > 0.5:
			up += 1
		elif n.y < -0.5:
			down += 1
	assert_eq(up, PRISM_SIDES * 3, "top cap vertices facing +Y")
	assert_eq(down, PRISM_SIDES * 3, "bottom cap vertices facing -Y")


# --- corner() ---------------------------------------------------------------

## Shards are placed with this, so it has to agree with the body's own corners or
## they orbit half a step out of phase with the shape they belong to.
func test_corner_wraps_around_the_polygon() -> void:
	for sides: int in [PRISM_SIDES, NOGAXEH_SIDES]:
		assert_almost_eq(PolyPrism.corner(0, RADIUS, 0.0, sides).distance_to(
				PolyPrism.corner(sides, RADIUS, 0.0, sides)), 0.0, EPS)


func test_corner_zero_is_on_the_positive_x_axis() -> void:
	var c: Vector3 = PolyPrism.corner(0, RADIUS, 0.0)
	assert_almost_eq(c.x, RADIUS, EPS)
	assert_almost_eq(c.z, 0.0, EPS)


func test_corner_respects_the_y_it_is_given() -> void:
	assert_almost_eq(PolyPrism.corner(2, RADIUS, 1.5).y, 1.5, EPS)
