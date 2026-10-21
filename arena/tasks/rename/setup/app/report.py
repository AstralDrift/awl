from app import util


def summary(orders):
    return [util.calc_total(o) for o in orders]
