'use strict';

class Store {
  constructor() {
    this.items = new Map();
    this.nextId = 1;
  }

  list() {
    return [...this.items.values()];
  }

  get(id) {
    return this.items.get(id);
  }

  create({ name, qty = 1 }) {
    const item = { id: this.nextId++, name, qty };
    this.items.set(item.id, item);
    return item;
  }

  update(id, fields) {
    const item = this.items.get(id);
    if (!item) return undefined;
    Object.assign(item, fields);
    return item;
  }
}

module.exports = { Store };
