Visualization Environment Setup
===============================

These visualization scripts do not activate a Conda environment themselves.
They run with whichever Python interpreter is active in the terminal.

Required package
----------------

The visualization scripts in this folder require:

- matplotlib

All other imports used by the current runner scripts are part of the Python
standard library.

Recommended Python version
--------------------------

Use Python 3.11.

Option 1: Conda
---------------

Create and activate an isolated environment:

```powershell
conda env create -f .\environment.yml
conda activate rollingstock-viz
```

Run the GGV runner from this folder:

```powershell
python .\ggv_diagram_runner.py
```

Option 2: Python venv
---------------------

Create and activate a local virtual environment:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install matplotlib
```

Run the GGV runner from this folder:

```powershell
python .\ggv_diagram_runner.py
```

Interpreter check
-----------------

To verify which Python environment is currently being used:

```powershell
python -c "import sys; print(sys.executable)"
```

Current runner defaults
-----------------------

The current hardcoded source CSV in ggv_diagram_runner.py is:

- UnitAssignment_GGV_2026-06-15_160425.csv

If that file changes, update HARDCODED_SOURCE_CSV in ggv_diagram_runner.py or
pass --source explicitly.

