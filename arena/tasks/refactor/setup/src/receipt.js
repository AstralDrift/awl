'use strict';
const { formatPrice: fp, formatPercent } = require('../lib/format');

function receipt(order) {
  const lines = order.items.map((i) => `${i.name.padEnd(12)} ${fp(i.price * i.qty, order.currency)}`);
  lines.push(`Discount (${formatPercent(order.discount)}) -${fp(Math.round(order.subtotal * order.discount), order.currency)}`);
  lines.push(`Paid ${fp(order.paid, order.currency)}`);
  return lines.join('\n');
}

module.exports = { receipt };
