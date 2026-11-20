# Strata Systems Architecture (`strata_systems/`)

Modular Godot 4.x GDScript subsystems demonstrating deterministic data validation, state machines, procedural kinematics, volumetric field simulation, and telemetry routing.

## 1. Data Graph and Validation (`data_graph/`)

### `item_channel_registry.gd` (`ItemChannelRegistry`)
- **System Purpose and Engineering Lens**: Canonical single source of truth mapping physical capability channels (force, bandwidth, thermal power, electrical energy, volume, flow, integrity) to authoritative units, domains, and family output contracts.
- **Inputs and Outputs**: Accepts `channel_id`, `domain`, `unit`, and `family` strings; outputs `ChannelSpec` instances, family channel arrays, or deterministic mismatch codes (`unknown_channel`, `domain_mismatch`, `unit_mismatch`).
- **State Transitions and Execution Flow**: Stateless static lookup over `_CHANNEL_ROWS` and family contract dictionaries.
- **Design Trade-Offs**: Embedding channel specs as an immutable constant table eliminates external JSON/resource loading overhead and guarantees startup determinism, trading runtime extensibility for strict static auditability.

### `item_port_contract.gd` (`ItemPortContract`)
- **System Purpose and Engineering Lens**: Enforces directional compatibility (`out` -> `in` or `bidirectional` <-> `bidirectional`), domain/family alignment, unit consistency against `ItemChannelRegistry`, interface revisions, and faction frame constraints between connected modules.
- **Inputs and Outputs**: Accepts a port dictionary in `_init()`; outputs boolean compatibility (`matches()`), granular mismatch codes (`explain_mismatch()`), and canonical JSON strings (`serialize_canonical()`).
- **State Transitions and Execution Flow**: Evaluates contract fields sequentially from coarsest (`direction`, `domain`, `family`, `role`) to finest (`channel_set`, registry-verified `channel_units`, `interface_id`, `interface_revision`, `limits`), returning on the first failed invariant.
- **Design Trade-Offs**: Returning specific mismatch identifiers rather than a bare boolean simplifies upstream validation diagnostics while keeping contract evaluation O(channels).

### `item_catalogue_validator.gd` (`ItemCatalogueValidator`)
- **System Purpose and Engineering Lens**: Pre-runtime static validation gate for hierarchical `Item -> Part -> Component` definition catalogues.
- **Inputs and Outputs**: Accepts a single definition dictionary (`validate_definition()`) or full catalogue array (`validate_catalogue()`); outputs a structured report `{valid, errors, definition_count, canonical, legacy_definition_count}` with sorted error records `{code, definition_id, path, message}`.
- **State Transitions and Execution Flow**: Executes five deterministic passes per catalogue: shape and family check, port contract verification, socket completeness check, output/transfer conservation check, and graph topology validation (detecting duplicate owners, unowned non-roots, and containment cycles via cursor traversal).
- **Design Trade-Offs**: Running full topology and port validation up front rejects malformed catalogue definitions before runtime instantiation, avoiding defensive null-checking inside hot simulation loops at the cost of maintaining explicit `declared_outputs` and `transfers` metadata.

### `hardware_service_tuning.gd` (`HardwareServiceTuning`)
- **System Purpose and Engineering Lens**: Parameterized `Resource` defining quality grade ladders (`F` through `A+`), continuous stat scaling curves (`[-15%, +15%]`), exponential tuning cost curves, repair material ratios, and scrap liquidation yields.
- **Inputs and Outputs**: Accepts quality floats, mass in kilograms, damage fractions, and subsystem roles; outputs deterministic grade strings, floor values, stat deltas, and elemental resource cost dictionaries (`fe_iron`, `ti_titanium`, `cu_copper`, `w_tungsten`, `unthreaded_fasteners`, `power_kwh`).
- **State Transitions and Execution Flow**: Pure functional calculations seeded optionally for repeatable grade-band quality derivation (`derive_quality_from_grade()`).
- **Design Trade-Offs**: Centralizing maintenance formulas in a single `Resource` decouples balancing constants from `RuntimePart` and `RuntimeComponent` state objects.

### `runtime_component.gd` and `runtime_part.gd` (`RuntimeComponent`, `RuntimePart`)
- **System Purpose and Engineering Lens**: Hierarchical runtime state containers enforcing typed socket installation, recursive mass/stat aggregation, damage mitigation, and permanent destruction scarring.
- **Inputs and Outputs**: Accept definition dictionaries, socket operations (`install_component()`, `swap_component()`, `remove_component()`), and kinetic/thermal damage amounts; output resolved operational stats, assembly snapshots, and canonical tree digests.
- **State Transitions and Execution Flow**:
  - Operational state: `active` when `current_durability > 0` and all required sockets hold operational components; transitions to `destroyed` at `0.0`.
  - Damage cascade: `RuntimePart.take_damage()` mitigates incoming impact via housing defense scaled by health ratio, clamps remaining durability, triggers `apply_destruction_scar()` on zero crossing (dropping one letter grade on the `HardwareServiceTuning` ladder), and propagates 20% residual shock weighted by child fragility multipliers (`control`/`optics` 1.6x, `hydraulic` 1.3x, `structural` 0.6x).
- **Design Trade-Offs**: Computing `get_resolved_stat()` on demand from current health and quality multipliers avoids cache invalidation bugs across nested socket swaps, while `get_canonical_tree_digest()` provides deterministic state hashing for verification.

## 2. State and Kinematics (`state_kinematics/`)

### `mech_breakdown_controller.gd` (`MechBreakdownController`)
- **System Purpose and Engineering Lens**: Finite-state machine governing critical hardware failure postures, shader emission state, movement shutdown, and physical limb detachment.
- **Inputs and Outputs**: Accepts assembly references (`Node`), pose controllers, and failure triggers (`trigger_overheat_seizure()`, `trigger_power_blackout()`, `trigger_catastrophic_destruction()`, `trigger_limb_severance()`); emits `breakdown_state_changed`, `overheat_seizure_triggered`, `power_blackout_triggered`, `catastrophic_destruction_triggered`, and `limb_severed` signals.
- **State Transitions and Execution Flow**:
  - States: `INTACT` -> `OVERHEAT_SEIZURE` (pelvis drop, knee lock, radiator emission ramp), `POWER_BLACKOUT` (head droop, emissive material shutdown), or `CATASTROPHIC_DESTRUCTION` (idempotent guard via `is_destroyed`, disables `CharacterBody3D` processing, activates salvage `Area3D` hitboxes, iterates severable slots).
- **Design Trade-Offs**: Using method checks (`has_method("get_slot")`, `has_method("sever_part")`) and `Node`/`Variant` interfaces removes compile-time coupling to assembly prefab scripts while preserving identical runtime state transitions.

### `mech_procedural_stride_controller.gd` (`MechProceduralStrideController`)
- **System Purpose and Engineering Lens**: Frame-deduplicated procedural gait generator driving hip, knee, ankle, pelvis, and counter-rolled torso transforms from horizontal velocity and ground state.
- **Inputs and Outputs**: Accepts `CharacterBody3D` velocity vector, `is_on_floor()` state, and `delta` timestep; outputs joint rotations/positions, `stride_phase_advanced`, `footstep_struck`, and optional `/root/GameEventBus` or `/root/AcousticBus` broadcasts.
- **State Transitions and Execution Flow**: Discovers leg bone chains once, strips conflicting pelvis/leg tracks from `AnimationPlayer`, advances `stride_phase` in `[0, TAU)` proportional to `PI * horiz_speed / STRIDE_LENGTH`, fires footstep events on `PI` and `TAU` crossings, and smoothly interpolates back to cached rest poses via `blend_weight` when idle or airborne.
- **Design Trade-Offs**: Procedural bone math eliminates baked walk-cycle foot sliding across variable speeds and allows torso counter-roll isolation, while `_last_update_frame` deduplication prevents double-stepping if called from both host and physics loops.

## 3. Spatial and Volumetric Fields (`spatial_fields/`)

### `salvage_mesh_silhouette_analyzer.gd` (`SalvageMeshSilhouetteAnalyzer`)
- **System Purpose and Engineering Lens**: Geometry inspection pipeline computing composite local AABBs, longitudinal cross-sectional slice stations, asymmetry metrics, interior traversal scaling, and wireframe line descriptors from arbitrary 3D node trees.
- **Inputs and Outputs**: Accepts a target `Node`, optional `source_item` metadata (`Variant`), and `station_count`; outputs a structured descriptor dictionary containing `raw_bounds`, `scale_factor`, `stations`, `scaled_stations`, `is_asymmetric`, `distal_width_ratio`, and `wireframe_lines`.
- **State Transitions and Execution Flow**: Collects visible `MeshInstance3D` bounds (falling back to `CollisionShape3D` primitives or default bounding boxes), transforms corners into target-local space, slices along the Z axis across `station_count` stations, and normalizes transverse scale to maintain `3.5m` to `5.0m` clearance.
- **Design Trade-Offs**: Sampling transformed AABB corners rather than per-triangle mesh buffers keeps analysis O(meshes * stations) and deterministic across both `ArrayMesh` and primitive collider fallbacks.

### `thermal_voxel_field.gd` (`ThermalVoxelField`)
- **System Purpose and Engineering Lens**: Time-sliced 3D cellular automata simulating fast convective air heat (`heat`) and slow structural thermal retention (`soak`) inside a camera-centered toroidal grid (`64 x 24 x 64` at `0.75m` resolution).
- **Inputs and Outputs**: Accepts world-space emitters (`deposit()`, `relax()`), window shifts (`set_window_min()`), and frame microsecond budgets (`update(delta, budget_us)`); outputs point queries (`heat_at()`, `soak_at()`) and 24 `Image.FORMAT_RH` GPU upload slices (`build_layers()`).
- **State Transitions and Execution Flow**:
  - Idle phase: accumulates `delta`, flushes pending injection arrays (`_inj_idx`, `_inj_heat`) into `_active`, and snapshots active cell keys when `tick_interval` elapses.
  - Active step phase: processes cells using double-buffered `_buf_h`/`_buf_s` arrays, checking `Time.get_ticks_usec() - t0 > budget_us` every 32 cells and halting physics wall queries once `solid_query_budget` is exhausted.
  - Commit phase: prunes cells below `EPS` (`0.0004`) from `_active` so idle regions consume zero CPU.
- **Design Trade-Offs**: Toroidal index wrapping (`posmod`) avoids array reallocation when scrolling (`_clear_slab()` clears only exited boundary slabs), and microsecond time-slicing guarantees bounded frame times even during large thermal bursts.

## 4. Telemetry and Load Routing (`telemetry_routing/`)

### `electrical_bus.gd` (`ElectricalBus`)
- **System Purpose and Engineering Lens**: Amperage ceiling monitor implementing deterministic highest-draw load shedding with cooldown hysteresis.
- **Inputs and Outputs**: Accepts `register_consumer(name, amps)`, `deregister_consumer(name)`, and `reset_breaker(name)`; emits `breaker_tripped(consumer_name)` and guarded `/root/GameEventBus` `system_alert` signals.
- **State Transitions and Execution Flow**: Each `_process` tick sums active consumer draws; if `total > bus_limit_amps` and `_cooldown <= 0.0`, isolates the single highest-draw consumer into `_tripped_consumers`, sets a `0.5s` cooldown so remaining loads settle before re-evaluating, and emits fault telemetry.
- **Design Trade-Offs**: Shedding only the highest-draw consumer per cooldown window prevents cascading brownouts across all subsystems simultaneously.

### `sensor_processor.gd` (`SensorProcessor`)
- **System Purpose and Engineering Lens**: Multi-band spatial telemetry aggregator unifying raycast (`OPTICAL`, `LIDAR`) and group-based distance/occlusion attenuation (`THERMAL`, `ACOUSTIC`, `EM`) behind a single normalized payload schema.
- **Inputs and Outputs**: Accepts sensor `band`, `Transform3D` origin, and `range_m`; returns `Array[Dictionary]` hits `{position, type, intensity}` or a combined 5-band dictionary from `full_sweep()` emitted to `/root/GameEventBus`.
- **State Transitions and Execution Flow**: Dispatches by band; `LIDAR` fans 8 rays across a 30-degree arc and discards `lidar_absorbent` surfaces, while `EM` raycasts line-of-sight occlusion and applies material attenuation (`0.08x` through steel bulkheads, `0.40x` through standard obstructions).
- **Design Trade-Offs**: Computing occlusion only for emitters already within `range_m` bounds physics raycasts to nearby sources instead of running full-scene queries every sweep.
