'use strict';
const { formatPrice } = require('../lib/format');

function refundNotice(amount, currency) {
  if (amount <= 0) return 'Nothing to refund';
  return `We refunded ${formatPrice(amount, currency)} to your card`;
}

function partialRefund(paid, kept, currency) {
  return `Refund ${formatPrice(paid - kept, currency)} of ${formatPrice(paid, currency)}`;
}

module.exports = { refundNotice, partialRefund };
