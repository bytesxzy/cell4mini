"""Reference exporter: trained weights -> the cell4 policy format.

This is the trainer-side half of the interchange that `Cell4.PolicyFormat`
reads and `Pipeline:loadPolicy` validates. It is deliberately dependency-free
(no numpy required, though numpy arrays work fine since they index the same
way) so it can be dropped into any training setup.

The contract to export against comes from the runtime itself:

    local template = pipeline:policyTemplate({16, 16})
    -- template.features   -> input order   (position IS meaning)
    -- template.actions    -> output order  (index IS the action label)
    -- template.layerSizes -> {#features, 16, 16, #actions}

Export a model whose features or actions have drifted from that template and
`loadPolicy` will refuse it rather than let a confidently-wrong agent run.
That refusal is the feature; don't work around it by editing the header.

Usage:

    write_policy(
        "policy.cell4",
        features=["threat", "health"],
        actions=["explore", "flee"],
        layers=[(W1, b1), (W2, b2)],   # W[out][in], b[out]
        activation="relu",
        output_activation="linear",
    )
"""

from __future__ import annotations

FORMAT_VERSION = 1


def _fmt(x: float) -> str:
    """Format a float so Lua's tonumber() reads back the identical double.

    repr() on a Python float is already the shortest round-tripping form, and
    Lua parses that same decimal text back to the same IEEE double. Rounding
    to fewer digits here would be silent model drift between training and
    inference.
    """
    return repr(float(x))


def format_policy(
    features,
    actions,
    layers,
    activation: str = "relu",
    output_activation: str = "linear",
) -> str:
    """Render a policy to the cell4 text format and sanity-check its shape.

    features: ordered feature names, matching the runtime's perception spec.
    actions:  ordered action names, matching the runtime's action set.
    layers:   list of (weights, biases) where weights[o][i] and biases[o].
    """
    if not layers:
        raise ValueError("a policy needs at least one layer")

    lines = [
        f"cell4-policy {FORMAT_VERSION}",
        "features " + " ".join(features),
        "actions " + " ".join(actions),
        f"activation {activation} {output_activation}",
    ]

    previous_out = len(features)
    for index, (weights, biases) in enumerate(layers, start=1):
        out_size = len(weights)
        if out_size == 0:
            raise ValueError(f"layer {index} has no output neurons")
        in_size = len(weights[0])

        if in_size != previous_out:
            raise ValueError(
                f"layer {index} takes {in_size} inputs but the previous stage "
                f"emits {previous_out}"
            )
        if len(biases) != out_size:
            raise ValueError(
                f"layer {index} has {out_size} neurons but {len(biases)} biases"
            )
        for o, row in enumerate(weights):
            if len(row) != in_size:
                raise ValueError(
                    f"layer {index} neuron {o} has {len(row)} weights, expected {in_size}"
                )

        lines.append(f"layer {in_size} {out_size}")
        for row in weights:
            lines.append("w " + " ".join(_fmt(v) for v in row))
        lines.append("b " + " ".join(_fmt(v) for v in biases))
        previous_out = out_size

    if previous_out != len(actions):
        raise ValueError(
            f"the final layer emits {previous_out} values but there are "
            f"{len(actions)} actions; the runtime will reject this policy"
        )

    return "\n".join(lines) + "\n"


def write_policy(path: str, **kwargs) -> str:
    text = format_policy(**kwargs)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return text


if __name__ == "__main__":
    # Self-check: a tiny two-layer policy over two features and two actions.
    text = format_policy(
        features=["threat", "health"],
        actions=["explore", "flee"],
        layers=[
            ([[0.5, -0.25], [1e-08, 123456.75], [0.0, 1.0]], [0.1, -0.2, 0.3]),
            ([[1.0, 2.0, 3.0], [-1.0, -2.0, -3.0]], [0.0, 0.5]),
        ],
        activation="tanh",
    )
    print(text, end="")
