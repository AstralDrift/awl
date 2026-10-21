'use strict';
const { formatPrice, formatPercent } = require('../../lib/format');

function dailyReport(sales, currency) {
  const revenue = sales.reduce((s, x) => s + x.amount, 0);
  const refunds = sales.filter((x) => x.amount < 0).reduce((s, x) => s + x.amount, 0);
  return [
    `Revenue: ${formatPrice(revenue, currency)}`,
    `Refunds: ${formatPrice(refunds, currency)}`,
    `Refund rate: ${formatPercent(revenue ? -refunds / revenue : 0)}`,
    `Average sale: ${formatPrice(Math.round(revenue / Math.max(1, sales.length)), currency)}`,
  ].join('\n');
}

module.exports = { dailyReport };
