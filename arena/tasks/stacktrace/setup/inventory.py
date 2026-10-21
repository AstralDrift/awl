def restock(stock, deliveries):
    for name, qty in deliveries:
        stock[name] = stock.get(name) + qty
    return stock


if __name__ == "__main__":
    print(restock({"apple": 2}, [("apple", 3), ("pear", 4)]))
