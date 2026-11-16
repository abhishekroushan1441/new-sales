/**
 * Café Orders: order website + API on top of this Google Sheet.
 *
 * Setup (once):
 *   1. In the Sheet: Extensions → Apps Script. Replace Code.gs with this file.
 *   2. Add an HTML file named "Index" (File → + → HTML) and paste Index.html into it.
 *   3. Deploy → New deployment → Web app. Execute as: Me. Who has access: Anyone. Deploy.
 *   4. Open the Web app URL: that's the order website. The same URL is the API (see API.md).
 * After changing the code: Deploy → Manage deployments → Edit (pencil) → Version: New version → Deploy.
 *
 * Every order writes:
 *   Orders              one row per order
 *   Order_Items         one row per item ordered
 *   Order_Constituents  one row per ingredient used (qty × Recipe_BOM amount, saved at order time)
 */

var STATUSES = ['New', 'Preparing', 'Ready', 'Completed', 'Cancelled'];
var MAX_QTY = 999;

var HEADERS = {
  Orders: ['Order ID', 'Created At', 'Customer', 'Order Type', 'Items', 'Item Count', 'Total', 'Status', 'Notes', 'Source', 'Updated At', 'Client Ref'],
  Order_Items: ['Order ID', 'Created At', 'Line', 'Category', 'Item', 'Qty', 'Unit Price', 'Line Total', 'Note', 'Status'],
  Order_Constituents: ['Order ID', 'Created At', 'Item', 'Item Qty', 'Material ID', 'Material', 'Usage Per Item', 'Total Usage', 'Unit', 'Status'],
  API_Keys: ['Key', 'Name', 'Scope', 'Active', 'Created', 'Last Used']
};

/* ───────────── entry points ───────────── */

// No action → the order website. ?action=… → JSON API.
function doGet(e) {
  var p = (e && e.parameter) || {};
  if (!p.action) {
    return HtmlService.createHtmlOutputFromFile('Index')
      .setTitle(setting_('Shop Name', 'Café Orders'))
      .addMetaTag('viewport', 'width=device-width, initial-scale=1');
  }
  return json_(api_(p, 'GET'));
}

function doPost(e) {
  var body = {};
  try { body = JSON.parse((e && e.postData && e.postData.contents) || '{}'); }
  catch (err) { return json_({ ok: false, error: 'Body must be JSON' }); }
  return json_(api_(body, 'POST'));
}

// Called by the order website through google.script.run (the page itself is the access check).
function web(req) {
  return safe_(function () { return route_(req || {}, 'write', 'Website'); });
}

/* ───────────── API ───────────── */

function api_(req, method) {
  return safe_(function () {
    var key = checkKey_(req.key);
    if (!key) return { ok: false, error: 'Invalid or inactive API key' };
    var writes = ['createOrder', 'updateStatus'];
    if (writes.indexOf(req.action) >= 0 && method !== 'POST') return { ok: false, error: req.action + ' needs POST' };
    return route_(req, key.scope, 'API · ' + key.name);
  });
}

function route_(req, scope, source) {
  switch (req.action) {
    case 'menu': return getMenu_(req);
    case 'orders': return listOrders_(req);
    case 'order': return getOrder_(req.id);
    case 'usage': return usage_(req);
    case 'createOrder':
      if (scope !== 'write') return { ok: false, error: 'This API key is read-only' };
      return createOrder_(req, source);
    case 'updateStatus':
      if (scope !== 'write') return { ok: false, error: 'This API key is read-only' };
      return updateStatus_(req.id, req.status);
    default:
      return { ok: false, error: 'Unknown action. Use menu, orders, order, usage, createOrder or updateStatus.' };
  }
}

/* ───────────── menu ───────────── */

function getMenu_(req) {
  var menu = readMenu_();
  var recipes = readRecipes_();
  var all = req.all === true || req.all === 'true', withRecipes = req.recipes === true || req.recipes === 'true';
  var items = menu.filter(function (m) { return all || m.available; }).map(function (m) {
    var out = { category: m.category, item: m.item, price: m.price, available: m.available,
                hasRecipe: !!recipes[m.item] };
    if (withRecipes) out.recipe = recipes[m.item] || [];
    return out;
  });
  return {
    ok: true,
    shop: setting_('Shop Name', 'Café Orders'),
    currency: setting_('Currency', '$'),
    orderTypes: String(setting_('Order Types', 'Dine-in, Takeout, Pickup')).split(',')
      .map(function (s) { return s.trim(); }).filter(String),
    statuses: STATUSES,
    items: items
  };
}

function readMenu_() {
  var t = table_('Menu');
  return t.rows.map(function (r) {
    var price = r[t.col.Price];
    var avail = r[t.col.Available];
    return {
      category: String(r[t.col.Category] || '').trim(),
      item: String(r[t.col.Item] || '').trim(),
      price: price === '' || price === null || isNaN(Number(price)) ? null : Number(price),
      available: !(avail === false || String(avail).toUpperCase() === 'FALSE')
    };
  }).filter(function (m) { return m.item; });
}

// item name → [{materialId, material, amount, unit}]
function readRecipes_() {
  var t = table_('Recipe_BOM');
  var c = t.col, out = {};
  t.rows.forEach(function (r) {
    var item = String(r[c['Menu Item Name']] || '').trim();
    if (!item) return;
    (out[item] = out[item] || []).push({
      materialId: String(r[c['Material ID']] || '').trim(),
      material: String(r[c['Material Component Name']] || '').trim(),
      amount: Number(r[c['Usage Amount']]) || 0,
      unit: String(r[c.Unit] || '').trim()
    });
  });
  return out;
}

/* ───────────── orders ───────────── */

function createOrder_(req, source) {
  var lines = Array.isArray(req.items) ? req.items : [];
  if (!lines.length) return { ok: false, error: 'Add at least one item' };

  var menu = {};
  readMenu_().forEach(function (m) { menu[m.item.toLowerCase()] = m; });
  var recipes = readRecipes_();

  var clean = [], problems = [];
  lines.forEach(function (l, i) {
    var name = String((l && l.item) || '').trim();
    var m = menu[name.toLowerCase()];
    var qty = Math.floor(Number(l && l.qty));
    if (!m) problems.push('Line ' + (i + 1) + ': "' + name + '" is not on the menu');
    else if (!m.available) problems.push('Line ' + (i + 1) + ': "' + m.item + '" is not available');
    else if (!(qty >= 1 && qty <= MAX_QTY)) problems.push('Line ' + (i + 1) + ': quantity must be 1 to ' + MAX_QTY);
    else clean.push({ m: m, qty: qty, note: String((l && l.note) || '').slice(0, 200) });
  });
  if (problems.length) return { ok: false, error: problems.join('; ') };

  var types = getMenu_({}).orderTypes;
  var type = String(req.type || types[0] || '').trim();

  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    var ref = String(req.ref || '').slice(0, 80);
    if (ref) {
      var existing = findOrderByRef_(ref);
      if (existing) { var o = getOrder_(existing); o.duplicate = true; return o; }
    }

    var now = new Date();
    var id = nextOrderId_(now);
    var priced = clean.every(function (l) { return l.m.price !== null; });
    var total = priced ? round_(clean.reduce(function (s, l) { return s + l.qty * l.m.price; }, 0)) : '';
    var itemCount = clean.reduce(function (s, l) { return s + l.qty; }, 0);
    var summary = clean.map(function (l) { return l.qty + '× ' + l.m.item; }).join(', ');

    appendObjects_('Orders', [{
      'Order ID': id, 'Created At': now, 'Customer': String(req.customer || '').slice(0, 80), 'Order Type': type,
      'Items': summary, 'Item Count': itemCount, 'Total': total, 'Status': 'New',
      'Notes': String(req.notes || '').slice(0, 500), 'Source': source, 'Updated At': now, 'Client Ref': ref
    }]);

    var itemRows = [], consRows = [], missing = [];
    clean.forEach(function (l, i) {
      itemRows.push({
        'Order ID': id, 'Created At': now, 'Line': i + 1, 'Category': l.m.category, 'Item': l.m.item, 'Qty': l.qty,
        'Unit Price': l.m.price === null ? '' : l.m.price, 'Line Total': l.m.price === null ? '' : round_(l.qty * l.m.price),
        'Note': l.note, 'Status': 'New'
      });
      var rec = recipes[l.m.item] || [];
      if (!rec.length) missing.push(l.m.item);
      rec.forEach(function (c) {
        consRows.push({
          'Order ID': id, 'Created At': now, 'Item': l.m.item, 'Item Qty': l.qty, 'Material ID': c.materialId,
          'Material': c.material, 'Usage Per Item': c.amount, 'Total Usage': round_(c.amount * l.qty, 4),
          'Unit': c.unit, 'Status': 'New'
        });
      });
    });
    appendObjects_('Order_Items', itemRows);
    appendObjects_('Order_Constituents', consRows);

    var res = getOrder_(id);
    if (missing.length) res.warning = 'No recipe found for: ' + missing.join(', ') + '. Add them to Recipe_BOM to track their ingredients.';
    return res;
  } finally {
    lock.releaseLock();
  }
}

// ORD-YYMMDD-001, counting up each day
function nextOrderId_(now) {
  var day = Utilities.formatDate(now, Session.getScriptTimeZone(), 'yyMMdd');
  var props = PropertiesService.getScriptProperties();
  var n = Number(props.getProperty('seq-' + day) || 0);
  // in case the counter was lost, never reuse an ID already in the sheet
  var t = table_('Orders'), prefix = 'ORD-' + day + '-';
  t.rows.forEach(function (r) {
    var v = String(r[t.col['Order ID']] || '');
    if (v.indexOf(prefix) === 0) n = Math.max(n, Number(v.slice(prefix.length)) || 0);
  });
  n += 1;
  props.setProperty('seq-' + day, String(n));
  return prefix + ('00' + n).slice(-3);
}

function findOrderByRef_(ref) {
  var t = table_('Orders');
  for (var i = t.rows.length - 1; i >= 0; i--) {
    if (String(t.rows[i][t.col['Client Ref']]) === ref) return String(t.rows[i][t.col['Order ID']]);
  }
  return null;
}

function getOrder_(id) {
  id = String(id || '').trim();
  if (!id) return { ok: false, error: 'Missing order id' };
  var t = table_('Orders');
  var row = null;
  for (var i = t.rows.length - 1; i >= 0; i--) { if (String(t.rows[i][t.col['Order ID']]) === id) { row = t.rows[i]; break; } }
  if (!row) return { ok: false, error: 'Order not found' };
  var details = orderDetails_([id]);
  return { ok: true, order: orderObj_(t, row, details[id]) };
}

// orders: date (yyyy-MM-dd), from/to (yyyy-MM-dd), status, since (ISO, updated after), detail, limit
function listOrders_(req) {
  var range = dateRange_(req);
  var since = req.since ? new Date(req.since) : null;
  var statuses = req.status ? String(req.status).split(',').map(function (s) { return s.trim().toLowerCase(); }) : null;
  var limit = Math.min(Math.max(Number(req.limit) || 200, 1), 1000);
  var t = table_('Orders');
  var rows = t.rows.filter(function (r) {
    var created = asDate_(r[t.col['Created At']]);
    var updated = asDate_(r[t.col['Updated At']]) || created;
    if (since) { if (!updated || updated <= since) return false; }
    else if (!created || created < range.from || created >= range.to) return false;
    if (statuses && statuses.indexOf(String(r[t.col.Status]).toLowerCase()) < 0) return false;
    return true;
  });
  rows = rows.slice(-limit).reverse();   // newest first
  var detail = req.detail === true || req.detail === 'true';
  var details = detail ? orderDetails_(rows.map(function (r) { return String(r[t.col['Order ID']]); })) : {};
  return {
    ok: true,
    from: range.fromStr, to: range.toStr,
    count: rows.length,
    orders: rows.map(function (r) { return orderObj_(t, r, details[String(r[t.col['Order ID']])]); })
  };
}

function orderObj_(t, r, d) {
  var c = t.col, total = r[c.Total];
  var o = {
    id: String(r[c['Order ID']]),
    createdAt: iso_(r[c['Created At']]),
    updatedAt: iso_(r[c['Updated At']]),
    customer: String(r[c.Customer] || ''),
    type: String(r[c['Order Type']] || ''),
    summary: String(r[c.Items] || ''),
    itemCount: Number(r[c['Item Count']]) || 0,
    total: total === '' || total === null ? null : Number(total),
    status: String(r[c.Status] || ''),
    notes: String(r[c.Notes] || ''),
    source: String(r[c.Source] || '')
  };
  if (d) { o.items = d.items; o.constituents = d.constituents; }
  return o;
}

function orderDetails_(ids) {
  var want = {}; ids.forEach(function (id) { want[id] = { items: [], constituents: [] }; });
  var ti = table_('Order_Items'), c = ti.col;
  ti.rows.forEach(function (r) {
    var d = want[String(r[c['Order ID']])]; if (!d) return;
    d.items.push({ line: Number(r[c.Line]), category: String(r[c.Category] || ''), item: String(r[c.Item]),
      qty: Number(r[c.Qty]), unitPrice: r[c['Unit Price']] === '' ? null : Number(r[c['Unit Price']]),
      lineTotal: r[c['Line Total']] === '' ? null : Number(r[c['Line Total']]), note: String(r[c.Note] || '') });
  });
  var tc = table_('Order_Constituents'), k = tc.col;
  tc.rows.forEach(function (r) {
    var d = want[String(r[k['Order ID']])]; if (!d) return;
    d.constituents.push({ item: String(r[k.Item]), itemQty: Number(r[k['Item Qty']]), materialId: String(r[k['Material ID']]),
      material: String(r[k.Material]), perItem: Number(r[k['Usage Per Item']]), total: Number(r[k['Total Usage']]),
      unit: String(r[k.Unit] || '') });
  });
  return want;
}

function updateStatus_(id, status) {
  id = String(id || '').trim();
  var s = STATUSES.filter(function (x) { return x.toLowerCase() === String(status || '').trim().toLowerCase(); })[0];
  if (!s) return { ok: false, error: 'Status must be one of: ' + STATUSES.join(', ') };
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    var t = table_('Orders'), found = false, now = new Date();
    for (var i = 0; i < t.rows.length; i++) {
      if (String(t.rows[i][t.col['Order ID']]) === id) {
        t.sheet.getRange(i + 2, t.col.Status + 1).setValue(s);
        t.sheet.getRange(i + 2, t.col['Updated At'] + 1).setValue(now);
        found = true;
      }
    }
    if (!found) return { ok: false, error: 'Order not found' };
    ['Order_Items', 'Order_Constituents'].forEach(function (name) {
      var tt = table_(name);
      for (var j = 0; j < tt.rows.length; j++) {
        if (String(tt.rows[j][tt.col['Order ID']]) === id) tt.sheet.getRange(j + 2, tt.col.Status + 1).setValue(s);
      }
    });
    return getOrder_(id);
  } finally {
    lock.releaseLock();
  }
}

/* ───────────── ingredient usage ───────────── */

// usage: from/to or date (yyyy-MM-dd). Totals per material and items sold, cancelled orders left out.
function usage_(req) {
  var range = dateRange_(req);
  var mats = {};
  var tm = table_('Materials');
  tm.rows.forEach(function (r) { mats[String(r[tm.col['Material ID']])] = String(r[tm.col.Category] || ''); });

  var t = table_('Order_Constituents'), c = t.col, by = {}, orders = {};
  t.rows.forEach(function (r) {
    var at = asDate_(r[c['Created At']]);
    if (!at || at < range.from || at >= range.to) return;
    if (String(r[c.Status]).toLowerCase() === 'cancelled') return;
    var key = r[c['Material ID']] + '|' + r[c.Unit];
    var m = by[key] || (by[key] = { materialId: String(r[c['Material ID']]), material: String(r[c.Material]),
      category: mats[String(r[c['Material ID']])] || '', unit: String(r[c.Unit] || ''), total: 0, orders: 0 });
    m.total += Number(r[c['Total Usage']]) || 0;
    var ok = r[c['Order ID']] + '|' + key;
    if (!orders[ok]) { orders[ok] = 1; m.orders += 1; }
  });

  var ti = table_('Order_Items'), k = ti.col, sold = {}, orderIds = {};
  ti.rows.forEach(function (r) {
    var at = asDate_(r[k['Created At']]);
    if (!at || at < range.from || at >= range.to) return;
    if (String(r[k.Status]).toLowerCase() === 'cancelled') return;
    var name = String(r[k.Item]);
    var s = sold[name] || (sold[name] = { item: name, category: String(r[k.Category] || ''), qty: 0 });
    s.qty += Number(r[k.Qty]) || 0;
    orderIds[r[k['Order ID']]] = 1;
  });

  var materials = Object.keys(by).map(function (x) { by[x].total = round_(by[x].total, 4); return by[x]; })
    .sort(function (a, b) { return a.category.localeCompare(b.category) || a.material.localeCompare(b.material); });
  var items = Object.keys(sold).map(function (x) { return sold[x]; }).sort(function (a, b) { return b.qty - a.qty; });
  return { ok: true, from: range.fromStr, to: range.toStr, orders: Object.keys(orderIds).length, items: items, materials: materials };
}

/* ───────────── API keys ───────────── */

function checkKey_(key) {
  key = String(key || '').trim();
  if (!key) return null;
  var t = table_('API_Keys');
  for (var i = 0; i < t.rows.length; i++) {
    var r = t.rows[i];
    if (String(r[t.col.Key]).trim() !== key) continue;
    var active = r[t.col.Active];
    if (active === false || String(active).toUpperCase() === 'FALSE') return null;
    try { t.sheet.getRange(i + 2, t.col['Last Used'] + 1).setValue(new Date()); } catch (e) {}
    return { name: String(r[t.col.Name] || 'API key'), scope: String(r[t.col.Scope]).toLowerCase() === 'write' ? 'write' : 'read' };
  }
  return null;
}

/* ───────────── sheet helpers ───────────── */

// Reads a tab by its header names, so columns can be moved around in the sheet.
function table_(name) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(name);
  if (!sheet) {
    if (!HEADERS[name]) throw new Error('Missing tab "' + name + '" in the sheet');
    sheet = ss.insertSheet(name);
    sheet.getRange(1, 1, 1, HEADERS[name].length).setValues([HEADERS[name]]).setFontWeight('bold');
    sheet.setFrozenRows(1);
  }
  var lastRow = sheet.getLastRow(), lastCol = sheet.getLastColumn();
  var headers = lastCol ? sheet.getRange(1, 1, 1, lastCol).getValues()[0].map(function (h) { return String(h).trim(); }) : [];
  var col = {};
  headers.forEach(function (h, i) { if (h && col[h] === undefined) col[h] = i; });
  (HEADERS[name] || []).forEach(function (h) {
    if (col[h] === undefined) throw new Error('Tab "' + name + '" is missing the column "' + h + '"');
  });
  var rows = lastRow > 1 ? sheet.getRange(2, 1, lastRow - 1, lastCol).getValues() : [];
  return { sheet: sheet, headers: headers, col: col, rows: rows };
}

function appendObjects_(name, objs) {
  if (!objs.length) return;
  var t = table_(name);
  var values = objs.map(function (o) { return t.headers.map(function (h) { return o[h] === undefined ? '' : o[h]; }); });
  t.sheet.getRange(t.sheet.getLastRow() + 1, 1, values.length, t.headers.length).setValues(values);
}

function setting_(name, fallback) {
  try {
    var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName('Settings');
    if (!sheet || sheet.getLastRow() < 2) return fallback;
    var rows = sheet.getRange(2, 1, sheet.getLastRow() - 1, 2).getValues();
    for (var i = 0; i < rows.length; i++) {
      if (String(rows[i][0]).trim().toLowerCase() === name.toLowerCase() && String(rows[i][1]).trim() !== '') return rows[i][1];
    }
  } catch (e) {}
  return fallback;
}

// from/to are dates (yyyy-MM-dd) in the script's time zone; "to" is inclusive. Default: today.
function dateRange_(req) {
  var tz = Session.getScriptTimeZone();
  var today = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd');
  var fromStr = String(req.from || req.date || today);
  var toStr = String(req.to || req.date || fromStr);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fromStr) || !/^\d{4}-\d{2}-\d{2}$/.test(toStr)) throw new Error('Dates must look like 2026-11-16');
  return { from: dayStart_(fromStr, tz), to: new Date(dayStart_(toStr, tz).getTime() + 86400000), fromStr: fromStr, toStr: toStr };
}

// midnight of a yyyy-MM-dd day in the given time zone
function dayStart_(d, tz) {
  var guess = new Date(d + 'T00:00:00Z');
  var shown = Utilities.formatDate(guess, tz, "yyyy-MM-dd'T'HH:mm");
  var offset = (new Date(shown + ':00Z').getTime() - guess.getTime());
  return new Date(guess.getTime() - offset);
}

function asDate_(v) {
  if (v instanceof Date) return v;
  if (v === '' || v === null || v === undefined) return null;
  var d = new Date(v);
  return isNaN(d.getTime()) ? null : d;
}

function iso_(v) { var d = asDate_(v); return d ? d.toISOString() : null; }
function round_(n, places) { var f = Math.pow(10, places || 2); return Math.round(n * f) / f; }

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// Never let an error escape as an HTML error page; Dates become ISO strings for google.script.run.
function safe_(fn) {
  try { return JSON.parse(JSON.stringify(fn())); }
  catch (err) { return { ok: false, error: String(err && err.message || err) }; }
}
