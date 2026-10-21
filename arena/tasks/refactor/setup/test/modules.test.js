'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { cartTotal } = require('../src/cart');
const { refundNotice } = require('../src/refunds');

test('cart total', () => {
  assert.strictEqual(cartTotal([{ name: 'a', price: 250, qty: 4 }], 'USD'), 'Total: $10.00');
});

test('refund notice', () => {
  assert.strictEqual(refundNotice(1234, 'EUR'), 'We refunded €12.34 to your card');
});
