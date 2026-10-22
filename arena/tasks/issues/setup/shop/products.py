"""Products."""
from dataclasses import dataclass


@dataclass
class Product:
    sku: str
    name: str
    price_cents: int
