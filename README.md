# Systems Architecture and Automation Code Showcase

Curated engineering modules by Garrett M. Harper ([Portfolio](https://garrett-m-harper.github.io/)) demonstrating deterministic state management, schema validation gates, spatial and volumetric computation, structured compliance tracking, and automated data pipelines.

Target repository: `https://github.com/Garrett-M-Harper/systems-architecture-showcase`

## Engineering Focus: Systems of Logic, Organization, and Data Flow

Across both simulation code and operational automation, these modules share a common architectural approach: explicit data contracts, deterministic validation before execution, bounded computation budgets, and repeatable state convergence.

- **Validation Gates**: Reject malformed schemas, mismatched directional ports, cyclic ownership graphs, and non-compliant vendor invoices before downstream execution.
- **Deterministic State Management**: Encode explicit finite-state transitions, quality degradation ladders, and DOM read-back retry loops so runtime behavior stays predictable under async or failure conditions.
- **Bounded Execution and Data Flow**: Enforce microsecond time-slicing, physics query budgets, HTTP timeouts, and thread-pool caps across volumetric simulation and API ingestion.
- **Structured Compliance Tracking**: Generate formula-driven Excel audit workbooks where invoice release status and inventory variances derive dynamically from cell-level rules.

## Repository Structure

- `strata_systems/`: Modular GDScript (Godot 4.x) subsystems extracted from an autonomous rig simulation codebase, organized into `data_graph/`, `state_kinematics/`, `spatial_fields/`, and `telemetry_routing/`. See [strata_systems/README.md](strata_systems/README.md) for per-module specifications.
- `automation_pipelines/`: Standalone Python 3.11+ pipelines for concurrent ATS API ingestion, Playwright DOM state persistence, and formula-driven Excel compliance reporting. See [automation_pipelines/README.md](automation_pipelines/README.md) for CLI usage and architecture details.

## Subsystem Index

| Subsystem | Location | Core Engineering Pattern | Primary Inputs | Primary Outputs |
|---|---|---|---|---|
| Data Graph and Validation | `strata_systems/data_graph/` | Canonical unit registry, typed port contracts, DFS cycle detection, 3-tier durability cascade | Raw definition dictionaries, service parameters, damage events | Validation error reports, canonical tree digests, resource cost dictionaries |
| State and Kinematics | `strata_systems/state_kinematics/` | 4-state failure FSM, frame-deduplicated phase-locked procedural kinematics | Locomotion velocity, ground contact, thermal/power failure triggers | Joint transforms, shader state updates, acoustic and state-change signals |
| Spatial and Volumetric Fields | `strata_systems/spatial_fields/` | Composite 3D AABB cross-sectioning, toroidal voxel grid with microsecond time-slicing | Scene mesh hierarchies, world-space heat emitters, physics space queries | Longitudinal slice stations, wireframe line descriptors, GPU RH voxel layers |
| Telemetry and Load Routing | `strata_systems/telemetry_routing/` | Amperage ceiling circuit breaker, 5-band raycast and material-attenuated telemetry | Consumer current registrations, 3D rig transforms, emitter groups | Breaker trip alerts, structured per-band sensor sweep payloads |
| Lead Filtering Pipeline | `automation_pipelines/ats_lead_pipeline.py` | Concurrent Greenhouse API polling, regex compensation normalization, deterministic trap filtering | Board slugs, JSON config, public ATS JSON feeds | Deduplicated and normalized `clean_leads.json` plus trap audit logs |
| DOM State Persistence | `automation_pipelines/ats_dom_autofill.py` | Multi-frame Playwright inspection with post-parse DOM read-back retry loop | Target ATS URL, external JSON profile, optional PDF paths | Populated multi-frame DOM inputs, persisted contact fields, execution summary |
| Compliance Workbook Engine | `automation_pipelines/excel_compliance_generator.py` | Deterministic `openpyxl` generation of `TODAY()`, `INDEX/MATCH`, `SUMIF()`, and `COUNTIF()` audit gates | Output directory flag, auditor metadata label | Styled `.xlsx` compliance and inventory reconciliation workbooks |

## Runtime Context and Trade-Offs

- **GDScript Modules (`strata_systems/`)**: Authored for Godot 4.x (`RefCounted`, `Resource`, `Node`). Scene-heavy dependencies from the parent project (`.tscn` prefabs, `.tres` shader materials, and level-specific singletons) were intentionally decoupled into relative `preload()` links, `Node`/`Variant` duck-typing, and guarded `/root/GameEventBus` lookups so each module can be audited and statically inspected standalone. Executing physics or scene-tree nodes requires opening the scripts inside a Godot 4.x project.
- **Python Pipelines (`automation_pipelines/`)**: Executable directly from Python 3.11+ after installing `requirements.txt` (`openpyxl`, `playwright`, `requests`). All applicant profiles, board lists, and output directories are parameterized through CLI flags or environment variables rather than embedded literals, eliminating personal data and workstation path coupling at the cost of requiring callers to supply configuration when running against live endpoints.

## Quick Verification (Python Pipelines)

```powershell
pip install -r requirements.txt
python -m py_compile automation_pipelines/*.py
python automation_pipelines/excel_compliance_generator.py --out-dir ./tmp_out
python automation_pipelines/ats_lead_pipeline.py --help
python automation_pipelines/ats_dom_autofill.py --help
```
