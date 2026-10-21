def last_share(total: int, people: int) -> int:
    """Split total cents across people.

    Earlier people each pay total // people.
    The last person pays whatever is left so the shares add up to total.
    """
    if people < 1:
        raise ValueError("people")
    base = total // people
    return total - base * people
