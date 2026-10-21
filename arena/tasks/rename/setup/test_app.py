from app.cart import checkout
from app.report import summary

assert checkout([{"price": 2, "qty": 3}]) == "total=6"
assert summary([[{"price": 1, "qty": 1}], []]) == [1, 0]
print("ok")
