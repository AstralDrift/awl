'use strict';
const { formatPrice } = require('../../lib/format');

module.exports = function orderConfirmed(name, total, currency) {
  return `Hi ${name}, thanks for your order of ${formatPrice(total, currency)}.`;
};
