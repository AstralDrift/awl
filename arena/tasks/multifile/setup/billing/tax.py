"""VAT / sales tax by region (see billing/regions)."""
import importlib


def rule(region):
    return importlib.import_module(f"billing.regions.{region.lower()}")


def tax_for(subtotal, region):
    return subtotal.scale(rule(region).RATE)
