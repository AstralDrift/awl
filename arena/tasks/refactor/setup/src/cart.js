'use strict';
const { formatPrice } = require('../lib/format');

function cartLines(items, currency) {
  return items.map((i) => `${i.qty} x ${i.name} @ ${formatPrice(i.price, currency)} = ${formatPrice(i.price * i.qty, currency)}`);
}

function cartTotal(items, currency) {
  const total = items.reduce((s, i) => s + i.price * i.qty, 0);
  return `Total: ${formatPrice(total, currency)}`;
}

module.exports = { cartLines, cartTotal };
