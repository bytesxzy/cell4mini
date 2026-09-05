"""Trainer-side tests for the policy exporter.

Run from the repo root: `python3 tests/test_export_policy.py`

The important test here is the golden-file check: it pins the exact bytes
the Python exporter produces against a fixture the Lua parser is separately
tested to read. If either side's format handling drifts, one of the two
suites goes red instead of the mismatch surfacing as a broken agent after a
training run.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

from export_policy import format_policy  # noqa: E402

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..")
GOLDEN = os.path.join(REPO_ROOT, "tests", "fixtures", "golden_policy.cell4")

checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        raise AssertionError(message)


def expect_error(fn, fragment, message):
    try:
        fn()
    except ValueError as exc:
        check(fragment in str(exc), f"{message}: wrong error text: {exc}")
        return
    raise AssertionError(f"{message}: expected a ValueError, none raised")


# --- the golden fixture the Lua side parses ------------------------------
GOLDEN_KWARGS = dict(
    features=["threat", "health"],
    actions=["explore", "flee"],
    layers=[
        ([[0.5, -0.25], [1e-08, 123456.75], [0.0, 1.0]], [0.1, -0.2, 0.3]),
        ([[1.0, 2.0, 3.0], [-1.0, -2.0, -3.0]], [0.0, 0.5]),
    ],
    activation="tanh",
    output_activation="linear",
)

with open(GOLDEN, encoding="utf-8") as handle:
    golden_text = handle.read()

check(
    format_policy(**GOLDEN_KWARGS) == golden_text,
    "exporter output no longer matches tests/fixtures/golden_policy.cell4 "
    "(regenerate it deliberately and re-run the Lua suite if the format "
    "really did change)",
)

# --- float fidelity ------------------------------------------------------
# Quantizing weights on export is silent model drift; the text must carry
# values that read back as the identical double.
text = format_policy(
    features=["f"],
    actions=["a"],
    layers=[([[0.1 + 0.2]], [-1e-300])],
)
check("0.30000000000000004" in text, "exporter preserves full float precision")
check("-1e-300" in text, "exporter preserves denormal-scale values")

# --- shape validation happens on the trainer side too --------------------
expect_error(
    lambda: format_policy(features=["a", "b"], actions=["x"], layers=[([[1.0]], [0.0])]),
    "takes 1 inputs",
    "rejects a first layer that does not match the feature count",
)
expect_error(
    lambda: format_policy(
        features=["a"],
        actions=["x", "y"],
        layers=[([[1.0]], [0.0])],
    ),
    "there are 2 actions",
    "rejects a final layer that does not match the action count",
)
expect_error(
    lambda: format_policy(
        features=["a"],
        actions=["x"],
        layers=[([[1.0], [1.0]], [0.0])],
    ),
    "2 neurons but 1 biases",
    "rejects a bias vector that does not match the neuron count",
)
expect_error(
    lambda: format_policy(
        features=["a", "b"],
        actions=["x"],
        layers=[([[1.0, 2.0], [1.0]], [0.0, 0.0])],
    ),
    "expected 2",
    "rejects a ragged weight matrix",
)
expect_error(
    lambda: format_policy(features=["a"], actions=["x"], layers=[]),
    "at least one layer",
    "rejects a policy with no layers",
)
expect_error(
    lambda: format_policy(
        features=["a"],
        actions=["x"],
        layers=[([[1.0]], [0.0]), ([[1.0, 2.0]], [0.0])],
    ),
    "previous stage",
    "rejects layers whose shapes do not chain",
)

print(f"EXPORTER TESTS PASSED ({checks} checks)")
