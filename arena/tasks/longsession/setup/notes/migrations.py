"""Schema migrations. Each step takes the raw dict at version N and returns version N+1."""

CURRENT = 2


def v0_to_v1(data):
    # v0 was a bare list of notes
    return {"version": 1, "notes": data}


def v1_to_v2(data):
    for n in data["notes"]:
        n.setdefault("tags", [])
    data["version"] = 2
    return data


STEPS = {0: v0_to_v1, 1: v1_to_v2}


def migrate(data):
    if isinstance(data, list):
        data = {"version": 0, "notes": data}
    v = data.get("version", 0)
    if v > CURRENT:
        raise ValueError(f"data version {v} is newer than this program ({CURRENT})")
    while v < CURRENT:
        data = STEPS[v](data if v else data["notes"])
        v = data["version"]
    return data
