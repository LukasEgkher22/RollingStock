Visualization
=============

Diagrams to analyse a solution after the unit assignment.

Files
-----

- `Main_diagrams.py`: runs the diagrams. Settings (result, list of diagrams) at the top of the file.
- `Diagram_functions.py`: all diagrams and shared helpers (loading, colours, time axis).
- `Output/<scenario>_<timestamp>/`: the images, one folder per result.
- `Output/Old diagrams/`: images of the old scripts.
- `Archive/`: old scripts (replaced by the two files above) and example data.

Workflow
--------

1. Solve a model: `julia Models/Main_GGV.jl` (or `Main_base.jl`)
2. Assign units: `python Models/Main_assignUnits.py`
3. Diagrams: `python Visualization/Main_diagrams.py`

Without arguments, `Main_diagrams.py` makes the diagrams in `DIAGRAMS` for the newest result.
One diagram from the command line:

```powershell
python Visualization/Main_diagrams.py train 10_910 --result GGV_2026-11-16_162530
```

Diagrams
--------

| Kind | Value | Shows |
|---|---|---|
| `train` | TrainId (`10`) or GGVId (`10_910`) | Unit order per trip (front at the top), units coming over a GGV link or from a stored train are hatched |
| `unit` | Unit (`ICA_5`), several (`ICA_5, ERF_17`) or a type (`MGA`) | Day plan: trips with TrainId and position, time on the train, GGV links, stored trains, depot |
| `fleet` | Type (`ICA`) or `all` | All units over the day, one thin lane per unit |
| `station` | Station (`FA/86`) | Units available in the inventory over the day per type, after reallocation times |

Value `all` makes one diagram per train, GGV group, unit or station.

Environment
-----------

Needs `pandas` and `matplotlib` (Python 3.11 or newer):

```powershell
conda env create -f .\environment.yml
conda activate rollingstock-viz
```
