'use strict';
const { formatPrice } = require('../../lib/format');

function stockValue(products, currency) {
  return products.map((p) => `${p.sku}: ${p.stock} units, value ${formatPrice(p.stock * p.cost, currency)}`);
}

function lowStock(products, currency) {
  return products.filter((p) => p.stock < 5).map((p) => `${p.sku} low (reorder at ${formatPrice(p.cost * 10, currency)})`);
}

module.exports = { stockValue, lowStock };
