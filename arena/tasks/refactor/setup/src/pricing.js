'use strict';
const { formatPrice } = require('../lib/format');

const tiers = [[100, 0.15], [50, 0.1], [10, 0.05]];

function bulkQuote(unit, qty, currency) {
  const [, off] = tiers.find(([min]) => qty >= min) || [0, 0];
  const total = Math.round(unit * qty * (1 - off));
  return `${qty} @ ${formatPrice(unit, currency)}${off ? ` less ${off * 100}%` : ''} = ${formatPrice(total, currency)}`;
}

module.exports = { bulkQuote };
