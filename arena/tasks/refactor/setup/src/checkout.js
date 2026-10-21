'use strict';
const format = require('../lib/format');
const { cartTotal } = require('./cart');

function summary(items, currency, shipping) {
  return [
    cartTotal(items, currency),
    'Shipping: ' + format.formatPrice(shipping, currency),
    'Due now: ' + format.formatPrice(items.reduce((s, i) => s + i.price * i.qty, 0) + shipping, currency),
  ].join('\n');
}

function freeShippingHint(subtotal, threshold, currency) {
  if (subtotal >= threshold) return 'You get free shipping!';
  return `Add ${format.formatPrice(threshold - subtotal, currency)} more for free shipping`;
}

module.exports = { summary, freeShippingHint };
