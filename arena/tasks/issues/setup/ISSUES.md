# Open issues

1. **Refunds print wrong.** `format_cents(-5)` prints `-1.95`; it should print `-0.05`. Same for any negative amount (`-1250` -> `-12.50`).
2. **Coupons take off far too much.** A 10% coupon on a cart of three 10.00 items should make the subtotal 27.00; it comes out much lower.
3. **Tax rounds down.** In the north (10%), tax on 1.05 is 0.10; it should be 0.11 because half a cent rounds up. Other amounts round to the nearest cent.
4. **Overselling.** With 5 in stock, `reserve(sku, 6)` succeeds and leaves -1. It must raise `OutOfStock`.
5. **CSV with commas in names crashes.** `products.csv` has `"Pens, blue"`; `python3 -m shop products.csv` dies with a ValueError. Quoted fields must work.
6. **Days between dates is wrong across months.** `days_between("2026-01-31", "2026-02-01")` should be 1. Leap years must be right too (`2028-02-28` to `2028-03-01` is 2).
7. **Search is case-sensitive and ignores SKUs.** `find(products, "note")` should find "Notebook", and `find(products, "p3")` should find the product with SKU P3.
8. **Top sellers come out in arbitrary order.** `top_sellers` must list the most units first, ties by SKU A-Z.
