'use strict';
const { formatPrice } = require('../../lib/format');

module.exports = function priceDrop(item, oldPrice, currency) {
  const saved = oldPrice - item.price;
  return `${item.name} is now ${formatPrice(item.price, currency)} (was ${formatPrice(oldPrice, currency)}, save ${formatPrice(saved, currency)})`;
};
