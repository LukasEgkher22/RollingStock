# RollingStock

Rolling stock composition model for a single base day (Danish network, Julia + JuMP + Gurobi).
Timetable data is built in `DataTransformationScripts/`, input data is in `Data/Base Day TUE.xlsx`.

## How to run
- Base model: `julia Models/Main_base.jl` (uses `aggregated_trips.csv`)
- GGV model: `julia Models/Main_GGV.jl` (uses `aggregated_trips_merged_GGV.csv`)
- Model logic is in `Models/FinalModel_functions.jl`. Results go to `Results/Analysis/` with a timestamp.
- The objective is lexicographic: `units` (extra units + balance issues), then `operating` (km cost + shunting).
- Scripts with their own model (`Main_includingGGV.jl`, `Main_simpleModel.jl`, `Main_unitPreservation.jl`) are old
  and in `Models/Archive/`. `Main_includingGGV.jl` needs terminal trip files that were removed.
- After a run: `python Models/Main_assignUnits.py`, then `python Visualization/Main_diagrams.py` (images in
  `Visualization/Output/<scenario>_<timestamp>/`). Old scripts and images: `Visualization/Archive/`, `Output/Old diagrams/`.

## GGV logic (decided with Lukas)
- A GGV lets passengers stay on board: one train ends where another departs, in the same direction, within 20 minutes.
- Preprocessing has two steps: 1:1 connections are merged into one TrainId, and 1:n / n:1 connections become a GGV.
- GGV links are required when identified. Lukas wants to review all links later and decide which ones should count.
- Every link moves at least one ordered unit block directly between the trains. A 1:2 split therefore needs at
  least 2 incoming units, and a 2:1 merge at least 2 departing units.
- Links also occur with through trains (train A continues and gives units, or train B continues and takes units).
- The main unit type rule was dropped. It was only an idea, and the old G4 flow constraint never restricted anything.
- Unit order always matters.

## Shunting and waiting rules (decided with Lukas)
- Coupling takes no time. Units used for another train wait the decoupling time of the `Reallocation` sheet.
- Units coupled directly on the track (GGV link) do not wait.
- Shunting is always allowed where a train ends or starts, also at joints inside a merged TrainId.
- Stored trains: a whole train can stay on the track and continue as a later train without reallocation time.
  - Minimum turnaround is 10 minutes and the standard turning pattern is `V` (both from the `Settings` sheet).
  - With `V` the train turns and no coupling is possible.
  - With a `Trip cutpoints` code for the train and station, coupling is possible as far as the code allows.
  - Decoupling a stored composition is never possible.
  - There is a maximum storage time (`max_storage_time`).

## Assumptions to confirm with Lukas
- `max_storage_time = 120` in `Main_GGV.jl` is a placeholder. Lukas asked for a maximum but gave no value.
- Stations without a turning code count as non-reversing at merged-train joints. Only AR has a turning code.
- Units left between two moved blocks go to the depot, although `Uncouple between` is 0 in the sheet.
- For stored trains, the shunt code is taken from the first train number of the starting train.
- Trains with a GGV link at their end or start cannot be stored or start from a stored composition.
- Stored trains and waiting times apply to the GGV model only. Base keeps `realloc_train_ends = false`.
- Group `2383_875` is still a GGV link, although `pre_merge_train_ids` forbids OD -> ES -> FA and `add_GGV_column` does not.

## Results so far
`Results/Analysis` only holds the newest result per scenario (Base `2026-11-16_171011`, GGV `2026-11-16_162530`).
All older runs below are in `Results/Archive`.

| Run | Date | Result |
|---|---|---|
| Base | 2026-11-08 | Optimal, 1 extra unit, km cost 3.90M, 2 shunting operations, 91 s |
| GGV, main unit type rule | 2026-11-08 | Optimal, 4 extra units (all ICA), km cost 4.98M, 5 shunting operations, 637 s |
| GGV, links + order + waiting, no stored trains | 2026-11-08 | Stopped at about 1180 s, no solution found, bound about 2.9M (at least 29 units) |
| GGV, links + order + waiting + stored trains, full storage | 2026-11-08 | Stopped at 4360 s (limit 1800 s), no solution found, bound about 629,000 (roughly 6 units) |
| GGV, same with reduced storage and first-solution settings | 2026-11-08 | NOT optimal: stage 1 hit its limit at 3600 s with 95 extra units + 22 balance issues, bound about 811,000 (about 8 units). Km cost 4.42M, 40 shunting operations |
| GGV, new code with only the old rules (switches: `main_unit_type = true`, rest off) | 2026-11-16 | Optimal, 4 extra units, km cost 4.97M, 5 shunting operations, 588 s. Reproduces the old GGV run (km cost within the 0.5% gap) |
| GGV, old rules + `joint_shunting = true` | 2026-11-16 | Optimal, 4 extra units, km cost 4.97M, 5 shunting operations, 1636 s (stage 1 slower: 1007 s) |
| GGV, links instead of main unit type + `joint_shunting` (`*_GGV_2026-11-16_162530`) | 2026-11-16 | Optimal, 6 extra units, km cost 5.15M, 42 shunting operations, 3042 s (stage 1: 2649 s) |

## Unit assignment (post-solution step)
- `write_results` also writes `UnitFlows_*.csv`: source and destination of every unit position (continue, link,
  stored, depot_in/out with the reallocation ready time). For older results: `julia Models/Export_unitFlows.jl <scenario> <timestamp>`.
- `python Models/Main_assignUnits.py` gives the units IDs (FIFO from the station inventory), runs 9 checks against
  the model and writes `UnitAssignment_*`, `UnitTimeline_*` and `UnitSummary_*` with the timestamp of the result.
- GGV `2026-11-16_162530`, GGV `2026-11-08_214855` (stored trains, now archived) and Base `2026-11-16_171011` pass all checks.
- Visualization: `Main_diagrams.py` (runner) + `Diagram_functions.py` with the diagrams train/GGV group (unit order),
  unit (day plan), fleet and station (inventory). The old scripts were replaced and are in `Visualization/Archive/`.

## Current status
GGV now produces a feasible solution, but a poor one: 117 units against a bound of about 8, so the true value is
still unknown. It cannot be compared with Base or the older GGV run yet. The changes are not committed yet.

## Latest run
- Base regression check on 2026-11-08: passed, same stage values and key figures as before the changes.
  Base was not rerun after the later `Status` change in `write_results`.
- GGV with reduced storage on 2026-11-08 (`*_GGV_2026-11-08_214855`, 4833 s in total):
  - Used a scratch copy of `Main_GGV.jl` with `time_limit = 3600`, `MIPFocus = 1` and `NoRelHeurTime = 900`.
    `Main_GGV.jl` does not have these settings. With them, the first solution came at about 1981 s.
  - Stage 1 explored only 1 node. Its last improvement was at about 3185 s, so more time may still help.
  - Stage 2 is optimal only for the units fixed by stage 1. `Summary_GGV_2026-11-08_214855.txt` still says
    `Status OPTIMAL` from before the fix. `Status` now reports the first stage that is not optimal.
  - Model size: 95,506 rows, 156,187 columns, 1.7M nonzeros.
- Checks on that output, with a separate script: all 134 links have their block at the stated side of both trains,
  with gaps of 2-20 minutes. All 101 stored trains match the composition, station and time rules, with waits of
  10-117 minutes. All use `V`, so none coupled. End minus start inventory matches the trips per station and type.
  Not checked separately: inventory over the day, reallocation timing, and seats against demand.
- The 33 trips missing from `CompAssignments` are unused material trains with zero demand. Base leaves out similar rows.

## Next steps
- Switch the new rules on one at a time in `Main_GGV.jl`: `joint_shunting`, then `ggv_constraints` instead of
  `main_unit_type`, then `realloc_train_ends`, then `max_storage_time`.
- Get a better GGV solution: add the solver settings to `Main_GGV.jl`, allow more time, or start from a known solution.
- Run GGV with `realloc_train_ends = false` to separate the effect of the waiting times from the links.
- Future scenario (Lukas, 2026-11-16, not now): keep 1:1 GGVs forced (merged TrainId), make 1:2 / 2:1 links
  optional and choose them by situation and extra costs (needs a value per link, e.g. own lexicographic stage).
- Shunting at the joints inside a merged TrainId stays allowed (`joint_shunting = true`), decided 2026-11-16.
- Lukas: decide `max_storage_time`, whether Base gets the same rules, and review the links in `GGVLinks_*.csv`.
