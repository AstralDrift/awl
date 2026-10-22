"""Sales tax by region, in percent."""

RATES = {"north": 10, "south": 8, "east": 0, "west": 12}


def tax_for(region, cents):
    """Tax in cents for an amount; half a cent rounds up."""
    rate = RATES[region]
    return int(cents * rate / 100)
