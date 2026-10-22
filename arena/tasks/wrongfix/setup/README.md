# bank

Statements from the daily feed (`data/feed.csv`). Kinds: deposit (money in), withdrawal
(money out), refund (a merchant refund paid back TO the customer: money in).

    python3 -m bank statement A-17
    python3 -m unittest discover -s tests
