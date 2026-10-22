from bank import ledger


def render(txs, account):
    lines = [f"Statement for {account}"]
    for t in txs:
        if t.account == account:
            lines.append(f"  {t.date}  {t.kind:<10} {t.amount:>10}")
    lines.append(f"  closing balance: {ledger.balance(txs, account):.2f}")
    return "\n".join(lines) + "\n"
