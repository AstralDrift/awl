# billing

Invoice generation for the shop. Amounts are kept as integer minor units (cents) in `Money`.

    python3 -m billing.cli invoice examples/order_de.json

Tests: `python3 -m unittest discover -s tests`
