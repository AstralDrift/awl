'use strict';
const fmt = require('../../lib/format');

module.exports = function abandonedCart(name, items, currency) {
  const value = items.reduce((s, i) => s + i.price, 0);
  const top = items.slice().sort((a, b) => b.price - a.price)[0];
  return `${name}, your cart (${fmt.formatPrice(value, currency)}) is waiting. Don't forget the ${top.name} for ${fmt.formatPrice(top.price, currency)}!`;
};
