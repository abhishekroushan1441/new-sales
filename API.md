# Café Orders: API

Orders are stored in Supabase (schema `cafe`). Every order placed on the website or through the API is saved as:

| Table | One row per | Used for |
|---|---|---|
| `cafe.orders` | order | who, when, type, status, total, `version` |
| `cafe.order_items` | item on an order | what was sold |
| `cafe.order_constituents` | ingredient used by an order | quantity × the item's `recipe_bom` amount, saved when the order is placed |

Changing `cafe.recipe_bom` later doesn't rewrite past orders; each order keeps the recipe it was made with.

## What you need

| | Value |
|---|---|
| Base URL | `https://dnvfeihwxhxcoroicblr.supabase.co/rest/v1/rpc/` |
| Publishable key | `sb_publishable_7GFBgbOec5crx3J1f0uvvQ_mBNnsdzo` (public; send it as `?apikey=` or an `apikey` header) |
| API key | from the owner. `ck_r_…` keys read; `ck_w_…` keys can also place orders and change status |

Every reply is JSON with `"ok": true`, or `"ok": false, "error": "…"`. Times are UTC (ISO 8601). Dates you send as `YYYY-MM-DD` use the shop's time zone (`America/Indiana/Indianapolis`), and an end date includes that whole day.

## Reading: plain links (GET)

These work in a browser, `curl`, `fetch`, Python, anything.

```
BASE=https://dnvfeihwxhxcoroicblr.supabase.co/rest/v1/rpc
PK=sb_publishable_7GFBgbOec5crx3J1f0uvvQ_mBNnsdzo

# 20 newest orders, with items and ingredients
$BASE/cafe_orders?apikey=$PK&key=ck_r_…&max_rows=20&detail=true

# today's orders that are still open
$BASE/cafe_orders?apikey=$PK&key=ck_r_…&date_from=2026-11-16&date_to=2026-11-16&status=New,Preparing,Ready

# between two exact times
$BASE/cafe_orders?apikey=$PK&key=ck_r_…&date_from=2026-11-16T08:00:00-05:00&date_to=2026-11-16T12:00:00-05:00

# everything that changed since you last checked (see "Never double-count" below)
$BASE/cafe_orders?apikey=$PK&key=ck_r_…&after=0&detail=true

# one order
$BASE/cafe_order?apikey=$PK&key=ck_r_…&id=ORD-261116-004

# ingredient totals for a period (cancelled orders left out)
$BASE/cafe_usage?apikey=$PK&key=ck_r_…&date_from=2026-11-10&date_to=2026-11-16

# menu, with each item's recipe
$BASE/cafe_menu?apikey=$PK&key=ck_r_…&recipes=true
```

| Endpoint | Options | Returns |
|---|---|---|
| `cafe_orders` | `after` (version number, see below), `date_from`, `date_to` (`YYYY-MM-DD` or ISO time), `status` (comma list: `New`, `Preparing`, `Ready`, `Completed`, `Cancelled`), `max_rows` (default 100, max 1000), `detail=true` (items + ingredients) | `count, orders, more, latestVersion`, and `nextAfter` when you sent `after`. Without `after`: newest first. With `after`: oldest change first. |
| `cafe_order` | `id` | `order` with items and ingredients |
| `cafe_usage` | `date_from`, `date_to` (default today) | `orders, items: [{item, category, qty}], materials: [{materialId, material, category, unit, total, orders}]` |
| `cafe_menu` | `recipes=true`, `show_all=true` (include unavailable items) | `shop, currency, timeZone, orderTypes, statuses, items: [{category, item, price, available, hasRecipe, recipe?}]` |

## Never double-count

Every order has a `version`. It is set when the order is placed and **raised again every time the order changes** (for example when it's cancelled). So:

1. First run: call `cafe_orders?after=0&detail=true`. Save each order **by its `id`** (insert or replace, never add twice).
2. Remember `nextAfter` from the reply.
3. Every few minutes: call `cafe_orders?after=<nextAfter you saved>&detail=true`. You get only new orders and orders that changed since then. Replace them by `id` and save the new `nextAfter`.
4. If `more` is `true`, call again straight away with the new `nextAfter`; there were more than `max_rows` changes.

To count ingredients, leave out orders whose `status` is `Cancelled`. When an order you already counted comes back as `Cancelled`, take its ingredients off again. Or just call `cafe_usage` for the period, which does this for you.

```js
const BASE = 'https://dnvfeihwxhxcoroicblr.supabase.co/rest/v1/rpc/';
const PK = 'sb_publishable_7GFBgbOec5crx3J1f0uvvQ_mBNnsdzo';
const KEY = 'ck_r_…';

let after = Number(localStorage.getItem('cafe_after') || 0);
const orders = {};                         // id → order (use your own database here)

async function sync() {
  let more = true;
  while (more) {
    const r = await fetch(`${BASE}cafe_orders?apikey=${PK}&key=${KEY}&after=${after}&detail=true&max_rows=500`).then(r => r.json());
    if (!r.ok) throw new Error(r.error);
    for (const o of r.orders) orders[o.id] = o;   // replace by id: never counted twice
    after = r.nextAfter; more = r.more;
  }
  localStorage.setItem('cafe_after', after);
}
```

```python
import requests
BASE = "https://dnvfeihwxhxcoroicblr.supabase.co/rest/v1/rpc/"
PK = "sb_publishable_7GFBgbOec5crx3J1f0uvvQ_mBNnsdzo"

r = requests.get(BASE + "cafe_orders", params={"apikey": PK, "key": READ_KEY, "after": last_after, "detail": "true"}).json()
for o in r["orders"]:
    upsert(o["id"], o)          # replace by id
last_after = r["nextAfter"]
```

## Changing: POST

Place an order or change its status with a `ck_w_…` key.

```
POST https://dnvfeihwxhxcoroicblr.supabase.co/rest/v1/rpc/cafe_api
Headers: apikey: sb_publishable_…     Content-Type: application/json
Body:    {"payload": {"key": "ck_w_…", "action": "…", …options}}
```

```bash
curl -s https://dnvfeihwxhxcoroicblr.supabase.co/rest/v1/rpc/cafe_api \
  -H "apikey: sb_publishable_7GFBgbOec5crx3J1f0uvvQ_mBNnsdzo" -H "Content-Type: application/json" \
  -d '{"payload": {"key": "ck_w_…", "action": "createOrder", "ref": "pos-10023",
       "customer": "Ana", "type": "Takeout",
       "items": [{"item": "Latte", "qty": 2, "note": "oat milk"}, {"item": "Croissant", "qty": 3}]}}'
```

| Action | Options | Returns |
|---|---|---|
| `createOrder` | `items: [{item, qty, note?}]` (required; names as on the menu, any capitalisation; qty 1–999), `customer`, `type` (one of the menu's `orderTypes`), `notes`, `ref` (your own unique id, so a retry never creates a second order) | `order` with items and ingredients; `warning` if an item has no recipe; `duplicate: true` if that `ref` was already used |
| `updateStatus` | `id`, `status`: `New`, `Preparing`, `Ready`, `Completed` or `Cancelled` | updated `order` |
| `menu`, `orders`, `order`, `usage` | same as the GET versions, with `from` / `to` / `limit` in place of `date_from` / `date_to` / `max_rows` | same |

## Order

```json
{
  "id": "ORD-261116-001",
  "version": 14,
  "createdAt": "2026-11-16T21:00:08.798+00:00",
  "updatedAt": "2026-11-16T21:04:51.120+00:00",
  "customer": "Ana",
  "type": "Takeout",
  "summary": "2× Latte, 3× Croissant",
  "itemCount": 5,
  "total": null,
  "status": "Preparing",
  "notes": "",
  "source": "Website",
  "ref": "w-lx2k…",
  "items": [{ "line": 1, "category": "Drinks", "item": "Latte", "qty": 2, "unitPrice": null, "lineTotal": null, "note": "oat milk" }],
  "constituents": [{ "item": "Latte", "itemQty": 2, "materialId": "MAT-001", "material": "Coffee beans", "perItem": 0.6, "total": 1.2, "unit": "oz" }]
}
```

- `total` is `null` until every item on the order has a price in `cafe.menu_items`.
- `source` is `Website`, or `API · <key name>`.
- `items` and `constituents` are included with `detail=true`, and always for `cafe_order` and `createOrder`.

## Keys

Keys live in `cafe.api_keys`. Only a hash of each key is stored, so copy a new key when you make it. In the Supabase SQL Editor:

```sql
-- 1. make a key and copy it (use ck_w_ instead of ck_r_ for a key that can place orders)
select 'ck_r_' || encode(extensions.gen_random_bytes(16), 'hex');
-- 2. save it, with a name and 'read' or 'write'
select cafe.add_key('ck_r_paste-it-here', 'Teammate dashboard', 'read');
```

To switch a key off: Table Editor → schema `cafe` → `api_keys` → set `active` to false.
