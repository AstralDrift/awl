'use strict';
// Old point-of-sale printer format. Kept for the till in store #4; has its own rules.

function formatPrice(cents) {
  const s = String(Math.abs(cents)).padStart(3, '0');
  return (cents < 0 ? 'CR ' : '') + s.slice(0, -2) + '.' + s.slice(-2);
}

function tillLine(name, cents) {
  return name.toUpperCase().padEnd(16, '.') + formatPrice(cents).padStart(10);
}

module.exports = { tillLine };
