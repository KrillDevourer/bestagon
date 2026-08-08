extends GutTest
## The generated boss solid. Pure geometry, so it tests like any other pure
## logic — HexPrism.build returns an ArrayMesh and never touches a scene.
##
## Worth testing at all because a malformed mesh does not error. A prism with an
## inverted cap, a missing face or a radius measured to the wrong reference still
## loads, still renders, and simply looks wrong on one frame of one boss fight —
## which is the most expensive kind of defect this project has, and the reason
## the pause layout gets a measuring harness instead of an eyeball.

const RADIUS: float = 1.0
const HEIGHT: float = 2.0

## Floating point on cos/sin corners: generous enough for trig, tight enough that
## a genuinely misplaced vertex still fails.
const EPS: float = 0.0001


func _mesh() -> ArrayMesh:
	return HexPrism.build(RADIUS, HEIGHT)


func _vertices() -> PackedVector3Array:
	var arrays: Array = _mesh().surface_get_arrays(0)
	return arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array


# --- topology ---------------------------------------------------------------

func test_mesh_has_exactly_one_surface() -> void:
	assert_eq(_mesh().get_surface_count(), 1)


## Six side quads (2 triangles each) plus two six-triangle caps.
func test_triangle_count_matches_the_declared_shape() -> void:
	assert_eq(HexPrism.triangle_count(), 24)
	assert_eq(_vertices().size(), HexPrism.triangle_count() * 3)


## Flat shading depends on vertices NOT being shared between facets. If someone
## "optimises" the builder into an indexed mesh, the silhouette smooths into a
## can and this is the test that says why that is not free.
func test_vertices_are_unshared_so_facets_stay_flat() -> void:
	var arrays: Array = _mesh().surface_get_arrays(0)
	assert_null(arrays[Mesh.ARRAY_INDEX],
			"an index array would mean shared vertices and smooth normals")


# --- dimensions -------------------------------------------------------------

## `radius` is the CIRCUMradius — corner distance, not flat distance. The two
## differ by cos(30) here, and the sprite it has to match is measured corner to
## corner.
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


## Every corner sits on the circle. Catches an off-by-one in the angle step,
## which produces a lopsided hexagon that still looks plausible in a thumbnail.
func test_every_side_vertex_lies_on_the_circumcircle() -> void:
	var off: int = 0
	for v: Vector3 in _vertices():
		var r: float = Vector2(v.x, v.z).length()
		# Cap centres are the one legitimate exception — they sit on the axis.
		if r > EPS and absf(r - RADIUS) > EPS:
			off += 1
	assert_eq(off, 0, "vertices off the circumcircle")


# --- winding ----------------------------------------------------------------

## THE ONE THAT MATTERS. Godot front faces are clockwise seen from outside, and
## the first build wound both caps the other way. Every count above still passed
## — the vertex total, the triangle total, the radius, the height — because the
## solid was the right solid, simply inside out. On screen the boss rendered as
## an open cup, because culling removed the lid and left the camera looking at
## the inside of the far wall.
##
## For any convex solid centred on its origin, an OUTWARD normal always points
## the same general way as the vertex it belongs to, so one dot product covers
## every face at once: sides (radial normal, radial vertex), cap rims and cap
## centres alike.
func test_every_normal_points_away_from_the_centre() -> void:
	var arrays: Array = _mesh().surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
	assert_eq(normals.size(), verts.size(), "every vertex needs a normal")
	var inward: int = 0
	for i: int in verts.size():
		if normals[i].dot(verts[i]) <= 0.0:
			inward += 1
	assert_eq(inward, 0, "inward-facing normals: the solid is inside out")


## The caps specifically, since they are the pair that was wrong and the dot
## product above would still pass if BOTH were flipped to point at each other.
func test_caps_face_opposite_ways() -> void:
	var arrays: Array = _mesh().surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
	var up: int = 0
	var down: int = 0
	for i: int in verts.size():
		# Cap faces are the ones whose normal is along the axis; sides are radial.
		if normals[i].y > 0.5:
			up += 1
		elif normals[i].y < -0.5:
			down += 1
	assert_eq(up, HexPrism.SIDES * 3, "top cap vertices facing +Y")
	assert_eq(down, HexPrism.SIDES * 3, "bottom cap vertices facing -Y")


# --- corner() ---------------------------------------------------------------

## Shards are placed with this, so it has to agree with the body's own corners or
## they orbit half a step out of phase with the shape they belong to.
func test_corner_wraps_around_the_hexagon() -> void:
	assert_almost_eq(HexPrism.corner(0, RADIUS, 0.0).distance_to(
			HexPrism.corner(HexPrism.SIDES, RADIUS, 0.0)), 0.0, EPS)


func test_corner_zero_is_on_the_positive_x_axis() -> void:
	var c: Vector3 = HexPrism.corner(0, RADIUS, 0.0)
	assert_almost_eq(c.x, RADIUS, EPS)
	assert_almost_eq(c.z, 0.0, EPS)


func test_corner_respects_the_y_it_is_given() -> void:
	assert_almost_eq(HexPrism.corner(2, RADIUS, 1.5).y, 1.5, EPS)
