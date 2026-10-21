"""Plain-text invoice."""
from billing import currency


def render(inv):
    out = [f"Invoice for {inv.customer} ({currency.name(inv.code)})", ""]
    for line in inv.lines:
        out.append(f"  {line.sku:<10} x{line.qty:<4} {line.total}")
    out += ["", f"  subtotal  {inv.subtotal()}", f"  tax       {inv.tax()}", f"  total     {inv.total()}"]
    return "\n".join(out) + "\n"
