'use strict';

const SYMBOLS = { USD: '$', EUR: '€', GBP: '£', JPY: '¥' };
const DECIMALS = { JPY: 0 };

/**
 * Format an amount in minor units (cents) for display.
 * formatPrice(1999, 'USD') -> '$19.99'
 */
function formatPrice(amount, currency = 'USD') {
  const d = DECIMALS[currency] ?? 2;
  const major = (amount / 10 ** d).toFixed(d);
  const sign = major.startsWith('-') ? '-' : '';
  const digits = sign ? major.slice(1) : major;
  const [int, frac] = digits.split('.');
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const sym = SYMBOLS[currency] ?? currency + ' ';
  return sign + sym + grouped + (frac ? '.' + frac : '');
}

function formatPercent(x) {
  return (x * 100).toFixed(1) + '%';
}

module.exports = { formatPrice, formatPercent };
