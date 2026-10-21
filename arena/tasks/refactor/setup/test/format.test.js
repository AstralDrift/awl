'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { formatPrice } = require('../lib/format');

test('formats', () => {
  assert.strictEqual(formatPrice(1999, 'USD'), '$19.99');
  assert.strictEqual(formatPrice(123456789, 'EUR'), '€1,234,567.89');
  assert.strictEqual(formatPrice(-500, 'GBP'), '-£5.00');
  assert.strictEqual(formatPrice(5000, 'JPY'), '¥5,000');
  assert.strictEqual(formatPrice(100, 'CHF'), 'CHF 1.00');
  assert.strictEqual(formatPrice(250), '$2.50');
});
