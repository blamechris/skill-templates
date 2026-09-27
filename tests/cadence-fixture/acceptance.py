"""Product checks for the local fixture. No model-behavior scoring lives here."""
import importlib.util
import json
import subprocess
import sys


def load_app(workspace):
    spec = importlib.util.spec_from_file_location("stocknote", workspace / "stocknote.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(workspace, feature):
    app = load_app(workspace)
    records = [
        {"name": " Red  Pen ", "category": " OFFICE ", "quantity": 2},
        {"name": "red pen", "category": "office", "quantity": 3},
        {"name": "Tape", "category": " Office", "quantity": 0},
        {"name": "Cup", "category": " Kitchen ", "quantity": 8},
    ]
    if feature == "category-totals":
        assert app.category_totals(records) == {"kitchen": 8, "office": 5}
        assert list(app.category_totals(records)) == ["kitchen", "office"]
        assert app.category_totals([]) == {}
        function = lambda rows: app.category_totals(rows)
        command = ["category-totals"]
        expected = {"kitchen": 8, "office": 5}
    else:
        assert app.low_stock(records, 5) == [
            {"name": "red pen", "quantity": 5}, {"name": "tape", "quantity": 0}]
        assert app.low_stock(records, 0) == [{"name": "tape", "quantity": 0}]
        assert app.low_stock([], 0) == []
        for bad in (-1, True, 1.5):
            try:
                app.low_stock([], bad)
            except ValueError:
                pass
            else:
                raise AssertionError("invalid threshold accepted")
        function = lambda rows: app.low_stock(rows, 5)
        command = ["low-stock", "--threshold", "5"]
        expected = [{"name": "red pen", "quantity": 5}, {"name": "tape", "quantity": 0}]
    for bad in (-1, True, "3"):
        try:
            function([{"name": "Pen", "category": "Office", "quantity": bad}])
        except ValueError:
            pass
        else:
            raise AssertionError("invalid quantity accepted")
    assert records[0]["name"] == " Red  Pen ", "input records were mutated"
    process = subprocess.run([sys.executable, "stocknote.py", *command], cwd=workspace,
                             input=json.dumps(records), text=True, capture_output=True, timeout=10)
    assert process.returncode == 0, "feature CLI failed: " + process.stderr
    assert json.loads(process.stdout) == expected, "feature CLI returned wrong result"
    process = subprocess.run([sys.executable, "stocknote.py", "count"], cwd=workspace,
                             input=json.dumps(records), text=True, capture_output=True, timeout=10)
    assert process.returncode == 0 and json.loads(process.stdout) == 13, "count CLI regressed"
