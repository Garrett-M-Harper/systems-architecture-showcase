class_name ThermalVoxelField
extends RefCounted

## ════════════════════════════════════════════════════════════════════════════
## STRATA 7X: Thermal Voxel Field (heat stored IN THE AIR)
## ════════════════════════════════════════════════════════════════════════════
## Every cell is a parcel of air that can hold heat. Nothing here knows about
## "plumes", "trails" or "objects": emitters only deposit heat into air cells,
## and the field itself diffuses, rises (hot) / sinks (cold), pools under solid
## ceilings, is blocked by solid cells, and decays. The renderer just reads it.
##
## Two layers per cell:
##   heat  signed, 1.0 == +100 C over ambient. Fast. Fresh mech wakes, steam, cryo.
##   soak  0..1, slow. Slowly integrates heat that has been present for a long time
##         (machinery that has run for minutes). Does not rise, barely diffuses.
##
## Storage is toroidal (world cell coordinate wrapped into the array), so the
## window follows the camera by clearing only the slabs that scroll out.
## Index layout: idx = x + W * (z + D * y)   (one image layer per y level).

const W := 64
const H := 24
const D := 64
const CELL := 0.75
const N := W * H * D
const EPS := 0.0004
const HEAT_CAP := 1.5

# Tunables (units per second unless noted)
var diffusion_rate := 3.0        ## fraction of a cell's heat shared with neighbours per second
var buoyancy_speed := 0.2        ## m/s hot air rises / cold air sinks
var heat_decay := 0.05           ## heat -> ambient (e-fold ~20 s)
var soak_feed := 0.010           ## fraction of positive heat integrated into soak per second
var soak_decay := 0.0015         ## e-fold ~11 min
var soak_diffusion := 0.25
var tick_interval := 0.1
var solid_query_budget := 500    ## new physics point queries allowed per tick

var win_min := Vector3i.ZERO     ## world cell coordinate of the window's min corner
var heat := PackedFloat32Array()
var soak := PackedFloat32Array()
var solid := PackedByteArray()   ## 0 unknown, 1 air, 2 solid

var space: PhysicsDirectSpaceState3D = null
var collision_mask := 1
var dirty := false
var ticks := 0

var _active: Dictionary = {}
var _buf_h := PackedFloat32Array()
var _buf_s := PackedFloat32Array()
var _touched: Dictionary = {}
var _keys: Array = []
var _cursor := 0
var _running := false
var _acc_dt := 0.0
var _step_dt := 0.1
var _queries_left := 0
var _inj_idx := PackedInt32Array()
var _inj_heat := PackedFloat32Array()
var _qparams := PhysicsPointQueryParameters3D.new()

func _init() -> void:
	heat.resize(N)
	soak.resize(N)
	solid.resize(N)
	_buf_h.resize(N)
	_buf_s.resize(N)
	_qparams.collide_with_bodies = true
	_qparams.collide_with_areas = false

# ── Coordinates ─────────────────────────────────────────────────────────────
static func world_to_cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / CELL), floori(p.y / CELL), floori(p.z / CELL))

static func cell_to_idx(c: Vector3i) -> int:
	return posmod(c.x, W) + W * (posmod(c.z, D) + D * posmod(c.y, H))

func in_window(c: Vector3i) -> bool:
	var l := c - win_min
	return l.x >= 0 and l.y >= 0 and l.z >= 0 and l.x < W and l.y < H and l.z < D

func window_origin_world() -> Vector3:
	return Vector3(win_min) * CELL

func _idx_to_cell(idx: int) -> Vector3i:
	# Recover the world cell from the wrapped idx using the current window.
	var x := idx % W
	var t := idx / W
	var z := t % D
	var y := t / D
	return Vector3i(
		win_min.x + posmod(x - win_min.x, W),
		win_min.y + posmod(y - win_min.y, H),
		win_min.z + posmod(z - win_min.z, D))

# ── Window scrolling ────────────────────────────────────────────────────────
func set_window_min(new_min: Vector3i) -> void:
	if new_min == win_min or _running:
		return # never scroll mid-tick; caller retries next frame
	var d := new_min - win_min
	if absi(d.x) >= W or absi(d.y) >= H or absi(d.z) >= D:
		clear_all()
		win_min = new_min
		return
	# Clear the wrapped slots whose old world cells are leaving the window.
	for axis in 3:
		var dd: int = d[axis]
		if dd == 0:
			continue
		var size: int = [W, H, D][axis]
		var start: int = win_min[axis] if dd > 0 else win_min[axis] + size + dd
		for k in absi(dd):
			_clear_slab(axis, posmod(start + k, size))
	win_min = new_min
	dirty = true

func _clear_slab(axis: int, slot: int) -> void:
	var x0 := 0
	var x1 := W
	var y0 := 0
	var y1 := H
	var z0 := 0
	var z1 := D
	match axis:
		0:
			x0 = slot
			x1 = slot + 1
		1:
			y0 = slot
			y1 = slot + 1
		2:
			z0 = slot
			z1 = slot + 1
	for y in range(y0, y1):
		for z in range(z0, z1):
			var row := W * (z + D * y)
			for x in range(x0, x1):
				var i := row + x
				heat[i] = 0.0
				soak[i] = 0.0
				solid[i] = 0

func clear_all() -> void:
	heat.fill(0.0)
	soak.fill(0.0)
	solid.fill(0)
	_buf_h.fill(0.0)
	_buf_s.fill(0.0)
	_active.clear()
	_touched.clear()
	_running = false
	_inj_idx.clear()
	_inj_heat.clear()
	dirty = true

# ── Solid (wall) knowledge ──────────────────────────────────────────────────
func _is_solid_cell(c: Vector3i, idx: int, allow_query: bool) -> bool:
	var s := solid[idx]
	if s != 0:
		return s == 2
	if space == null:
		return false
	if not allow_query:
		return true # unknown + out of budget: treat as blocked this tick, do not cache
	_qparams.position = (Vector3(c) + Vector3(0.5, 0.5, 0.5)) * CELL
	_qparams.collision_mask = collision_mask
	var hit := space.intersect_point(_qparams, 1)
	solid[idx] = 2 if not hit.is_empty() else 1
	return not hit.is_empty()

func is_solid_world(p: Vector3) -> bool:
	var c := world_to_cell(p)
	return in_window(c) and _is_solid_cell(c, cell_to_idx(c), true)

# ── Emitters (the ONLY way heat enters) ─────────────────────────────────────
const _NEIGH27_W := [1.0, 0.6, 0.4, 0.25] # by manhattan distance 0..3

## Add heat (signed) into the air cells around a world point. Solid cells (e.g.
## the pipe's own collider) receive nothing; the heat leaks into adjacent air.
func deposit(p: Vector3, amount: float) -> void:
	_emit(p, amount, 0.0, 0.0, false)

## Drive air around a point toward `target` heat at `rate` per second (continuous
## machinery). Slowly fills the surrounding air, never exceeds target.
func relax(p: Vector3, target: float, rate: float, dt: float) -> void:
	_emit(p, target, rate, dt, true)

func _emit(p: Vector3, value: float, rate: float, dt: float, is_relax: bool) -> void:
	var c0 := world_to_cell(p)
	var weights: Array = []
	var cells: Array[Vector3i] = []
	var sum_w := 0.0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var c := c0 + Vector3i(dx, dy, dz)
				if not in_window(c):
					continue
				var idx := cell_to_idx(c)
				if _is_solid_cell(c, idx, true):
					continue
				var w: float = _NEIGH27_W[absi(dx) + absi(dy) + absi(dz)]
				cells.append(c)
				weights.append(w)
				sum_w += w
	if cells.is_empty():
		return
	for i in cells.size():
		var idx := cell_to_idx(cells[i])
		var w: float = weights[i]
		var add := 0.0
		if is_relax:
			var tgt := value * w
			var h := heat[idx]
			if (value > 0.0 and h < tgt) or (value < 0.0 and h > tgt):
				add = (tgt - h) * clampf(rate * dt, 0.0, 1.0)
		else:
			add = value * (w / sum_w)
		if absf(add) > 0.0:
			_inj_idx.append(idx)
			_inj_heat.append(add)

func _apply_injections() -> void:
	for i in _inj_idx.size():
		var idx := _inj_idx[i]
		heat[idx] = clampf(heat[idx] + _inj_heat[i], -HEAT_CAP, HEAT_CAP)
		_active[idx] = true
	if _inj_idx.size() > 0:
		dirty = true
	_inj_idx.clear()
	_inj_heat.clear()

# ── Simulation (time-sliced so a frame never pays for a whole tick) ─────────
func update(delta: float, budget_us: int = 3000) -> void:
	_acc_dt += delta
	if not _running:
		_apply_injections()
		if _acc_dt < tick_interval:
			return
		_step_dt = minf(_acc_dt, 0.5)
		_acc_dt = 0.0
		_keys = _active.keys()
		_cursor = 0
		_queries_left = solid_query_budget
		_touched.clear()
		_running = true
	var t0 := Time.get_ticks_usec()
	var dt := _step_dt
	var dif := minf(diffusion_rate * dt, 0.6)
	var sdif := minf(soak_diffusion * dt, 0.5)
	var rise := minf(buoyancy_speed * dt / CELL, 0.4)
	var keep := 1.0 - heat_decay * dt
	var skeep := 1.0 - soak_decay * dt
	var n_keys := _keys.size()
	while _cursor < n_keys:
		var idx: int = _keys[_cursor]
		_cursor += 1
		_step_cell(idx, dt, dif, sdif, rise, keep, skeep)
		if (_cursor & 31) == 0 and Time.get_ticks_usec() - t0 > budget_us:
			return
	_commit()

func _step_cell(idx: int, dt: float, dif: float, sdif: float, rise: float, keep: float, skeep: float) -> void:
	var h := heat[idx] * keep
	var s := soak[idx] * skeep + maxf(h, 0.0) * soak_feed * dt
	var x := idx % W
	var t := idx / W
	var z := t % D
	var y := t / D
	var c := _idx_to_cell(idx)
	var l := c - win_min

	# Collect open neighbours (air cells inside the window).
	var nb: Array[int] = []
	var up_idx := -1
	var down_idx := -1
	for dir in 6:
		var nx := x
		var ny := y
		var nz := z
		var ok := true
		match dir:
			0:
				ok = l.x + 1 < W
				nx = (x + 1) % W
			1:
				ok = l.x - 1 >= 0
				nx = (x + W - 1) % W
			2:
				ok = l.z + 1 < D
				nz = (z + 1) % D
			3:
				ok = l.z - 1 >= 0
				nz = (z + D - 1) % D
			4:
				ok = l.y + 1 < H
				ny = (y + 1) % H
			5:
				ok = l.y - 1 >= 0
				ny = (y + H - 1) % H
		if not ok:
			continue
		var nidx := nx + W * (nz + D * ny)
		var nc := c + Vector3i(
			1 if dir == 0 else (-1 if dir == 1 else 0),
			1 if dir == 4 else (-1 if dir == 5 else 0),
			1 if dir == 2 else (-1 if dir == 3 else 0))
		var allow := _queries_left > 0 or solid[nidx] != 0
		if solid[nidx] == 0 and allow:
			_queries_left -= 1
		if _is_solid_cell(nc, nidx, allow):
			continue
		nb.append(nidx)
		if dir == 4:
			up_idx = nidx
		elif dir == 5:
			down_idx = nidx

	var out_h := h
	var out_s := s
	var n_nb := nb.size()
	if n_nb > 0:
		# Heat that wants to rise but is capped by a ceiling spreads sideways harder (pooling).
		var d_eff := dif
		if h > 0.0 and up_idx < 0:
			d_eff = minf(dif * 1.8, 0.7)
		elif h < 0.0 and down_idx < 0:
			d_eff = minf(dif * 1.8, 0.7)
		var share := h * d_eff / 6.0
		for nidx in nb:
			_add_h(nidx, share)
		out_h -= share * n_nb
		var ssh := s * sdif / 6.0
		for nidx in nb:
			_add_s(nidx, ssh)
		out_s -= ssh * n_nb
	# Buoyancy
	if h > 0.0 and up_idx >= 0:
		var mv := out_h * rise
		_add_h(up_idx, mv)
		out_h -= mv
	elif h < 0.0 and down_idx >= 0:
		var mv2 := out_h * rise
		_add_h(down_idx, mv2)
		out_h -= mv2
	_add_h(idx, out_h)
	_add_s(idx, out_s)

func _add_h(idx: int, v: float) -> void:
	_buf_h[idx] += v
	_touched[idx] = true

func _add_s(idx: int, v: float) -> void:
	_buf_s[idx] += v
	_touched[idx] = true

func _commit() -> void:
	# All previously active cells wrote themselves into _touched, so overwriting is safe.
	for k in _keys:
		heat[k] = 0.0
		soak[k] = 0.0
	var next_active: Dictionary = {}
	for k in _touched:
		var idx: int = k
		var hv := _buf_h[idx]
		var sv := minf(_buf_s[idx], 1.0)
		_buf_h[idx] = 0.0
		_buf_s[idx] = 0.0
		if absf(hv) < EPS and sv < EPS:
			heat[idx] = 0.0
			soak[idx] = 0.0
			continue
		heat[idx] = hv
		soak[idx] = sv
		next_active[idx] = true
	_active = next_active
	_touched.clear()
	_keys = []
	_running = false
	ticks += 1
	dirty = true

# ── Queries ─────────────────────────────────────────────────────────────────
func heat_at(p: Vector3) -> float:
	var c := world_to_cell(p)
	return heat[cell_to_idx(c)] if in_window(c) else 0.0

func soak_at(p: Vector3) -> float:
	var c := world_to_cell(p)
	return soak[cell_to_idx(c)] if in_window(c) else 0.0

func active_cell_count() -> int:
	return _active.size()

func total_heat() -> float:
	var s := 0.0
	for k in _active:
		s += heat[k]
	return s

# ── GPU upload layers (one RH image per y level, W x D) ─────────────────────
func build_layers(source: PackedFloat32Array) -> Array[Image]:
	var layers: Array[Image] = []
	for y in H:
		var bytes := source.slice(y * W * D, (y + 1) * W * D).to_byte_array()
		var img := Image.create_from_data(W, D, false, Image.FORMAT_RF, bytes)
		img.convert(Image.FORMAT_RH)
		layers.append(img)
	return layers
