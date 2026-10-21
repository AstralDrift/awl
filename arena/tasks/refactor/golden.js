'use strict';
// Prints every module's output for fixed inputs. Run from a workdir: node $TASK/golden.js
const path = require('node:path');
const r = (p) => require(path.join(process.cwd(), p));
const items = [{ name: 'widget', price: 1999, qty: 2 }, { name: 'bolt', price: 25, qty: 120 }];
const out = [];
for (const cur of ['USD', 'EUR', 'JPY', 'CHF']) {
  out.push(...r('src/cart').cartLines(items, cur), r('src/cart').cartTotal(items, cur));
  out.push(r('src/checkout').summary(items, cur, 499), r('src/checkout').freeShippingHint(4000, 5000, cur));
  out.push(r('src/receipt').receipt({ items, currency: cur, discount: 0.1, subtotal: 6998, paid: 6298 }));
  out.push(r('src/refunds').refundNotice(1234567, cur), r('src/refunds').partialRefund(5000, 1250, cur));
  out.push(r('src/email/order_confirmed')('Ana', 1234567, cur), r('src/email/abandoned_cart')('Bo', items, cur));
  out.push(r('src/email/price_drop')({ name: 'lamp', price: 2999 }, 3999, cur));
  const sales = [{ id: 1, amount: 12000 }, { id: 2, amount: -3000 }, { id: 3, amount: 999 }];
  out.push(r('src/admin/report').dailyReport(sales, cur), r('src/admin/csv').salesCsv(sales));
  const prods = [{ sku: 'A1', stock: 3, cost: 450 }, { sku: 'B2', stock: 40, cost: 1200 }];
  out.push(...r('src/admin/inventory').stockValue(prods, cur), ...r('src/admin/inventory').lowStock(prods, cur));
  out.push(r('src/pricing').bulkQuote(333, 120, cur), r('src/pricing').bulkQuote(333, 3, cur));
}
out.push(r('src/legacy/pos').tillLine('coffee', 350), r('src/legacy/pos').tillLine('refund', -1205), r('src/legacy/pos').tillLine('gum', 5));
const f = r('lib/format');
out.push(f.formatMoney ? [f.formatMoney('EUR', 123456), f.formatMoney('USD', -5), f.formatMoney('JPY', 7)].join(' ') : 'no formatMoney');
console.log(out.join('\n'));
