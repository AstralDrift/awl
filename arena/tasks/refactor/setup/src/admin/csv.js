'use strict';

// Plain machine-readable number for CSV exports (not the display formatter).
const formatPrice = (n) => (n / 100).toFixed(2);

function salesCsv(sales) {
  return ['id,amount', ...sales.map((s) => `${s.id},${formatPrice(s.amount)}`)].join('\n');
}

module.exports = { salesCsv };
