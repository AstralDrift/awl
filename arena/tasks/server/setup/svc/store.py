"""In-memory order store, seeded with sample data."""

ORDERS = [
    {"id": 1, "item": "widget", "qty": 2, "price": 10},
    {"id": 2, "item": "gadget", "qty": 1, "price": 25},
    {"id": 3, "item": "gizmo", "qty": 3, "price": 5},
]


def all_orders():
    return list(ORDERS)
