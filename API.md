# Café Orders: API

The order website and the API share one address: the **Web app URL** from Apps Script (Deploy → Manage deployments), ending in `/exec`. Every order recorded through either one is written to the Google Sheet:

| Tab | One row per | Used for |
|---|---|---|
| `Orders` | order | who, when, type, status, total |
| `Order_Items` | item on an order | what was sold |
| `Order_Constituents` | ingredient used by an order | quantity × the item's Recipe_BOM amount, saved when the order is placed |

Changing `Recipe_BOM` later doesn't rewrite past orders; each order keeps the recipe it was made with.

## Keys

Every API call needs a key from the **API_Keys** tab:
- `read` keys can call `menu`, `orders`, `order` and `usage`.
- `write` keys can also call `createOrder` and `updateStatus`.

To add a key, add a row with a long random key (40+ characters). To switch one off, set **Active** to `FALSE`. **Last Used** fills in automatically.

Treat keys like passwords. A `write` key belongs on a server, never in public web pages.

## Calling it

- **Reading:** `GET <url>?action=<action>&key=<key>&…options`
- **Changing:** `POST <url>` with a JSON body: `{"key": "…", "action": "…", …options}`

Google answers a POST with a redirect, so follow it: `curl -L`, or `fetch` (which follows automatically). From a browser, send the body as `text/plain` to avoid a CORS preflight.

Every reply is JSON with `"ok": true`, or `"ok": false, "error": "…"`.

```bash
URL="https://script.google.com/macros/s/…/exec"

# today's orders with items and ingredients
curl -sL "$URL?action=orders&key=$READ_KEY&detail=true"

# ingredients used this week
curl -sL "$URL?action=usage&key=$READ_KEY&from=2026-11-10&to=2026-11-16"

# place an order
curl -sL "$URL" -H "Content-Type: text/plain" -d '{
  "key": "'$WRITE_KEY'", "action": "createOrder", "ref": "pos-10023",
  "customer": "Ana", "type": "Takeout",
  "items": [{"item": "Latte", "qty": 2, "note": "oat milk"}, {"item": "Croissant", "qty": 3}]
}'
```

```js
async function cafe(action, options = {}, write = false) {
  const base = { key: API_KEY, action, ...options };
  const res = write
    ? await fetch(URL, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify(base) })
    : await fetch(URL + '?' + new URLSearchParams(base));
  const data = await res.json();
  if (!data.ok) throw new Error(data.error);
  return data;
}
const { materials } = await cafe('usage', { from: '2026-11-01', to: '2026-11-16' });
```

```python
import requests
r = requests.get(URL, params={"action": "usage", "key": READ_KEY, "date": "2026-11-16"})
print(r.json()["materials"])
```

## Actions

| Action | Method | Options | Returns |
|---|---|---|---|
| `menu` | GET | `recipes=true` (include each item's ingredients), `all=true` (include unavailable items) | `shop, currency, orderTypes, statuses, items: [{category, item, price, available, hasRecipe, recipe?}]` |
| `orders` | GET | `date` or `from`/`to` (`YYYY-MM-DD`, default today), `status` (comma list, e.g. `New,Preparing`), `since` (ISO time; orders created or changed after it, ignoring dates), `detail=true` (items + ingredients), `limit` (default 200, max 1000) | `count, orders: [order]`, newest first |
| `order` | GET | `id` (e.g. `ORD-261116-004`) | `order` with items and ingredients |
| `usage` | GET | `date` or `from`/`to` (default today) | `orders, items: [{item, category, qty}], materials: [{materialId, material, category, unit, total, orders}]` |
| `createOrder` | POST, write key | `items: [{item, qty, note?}]` (required; item names as in the Menu tab, any capitalisation), `customer`, `type` (one of the Settings order types), `notes`, `ref` (your own unique id, so a retry never creates a second order) | `order` with items and ingredients; `warning` if an item has no recipe |
| `updateStatus` | POST, write key | `id`, `status`: `New`, `Preparing`, `Ready`, `Completed` or `Cancelled` | updated `order` |

**Order**
```json
{
  "id": "ORD-261116-001",
  "createdAt": "2026-11-16T21:00:08.798Z",
  "updatedAt": "2026-11-16T21:04:51.120Z",
  "customer": "Ana",
  "type": "Takeout",
  "summary": "2× Latte, 3× Croissant",
  "itemCount": 5,
  "total": null,
  "status": "Preparing",
  "notes": "",
  "source": "Website",
  "items": [{ "line": 1, "category": "Drinks", "item": "Latte", "qty": 2, "unitPrice": null, "lineTotal": null, "note": "oat milk" }],
  "constituents": [{ "item": "Latte", "itemQty": 2, "materialId": "MAT-001", "material": "Coffee beans", "perItem": 0.6, "total": 1.2, "unit": "oz" }]
}
```

Notes on these fields:
- `total` is `null` until every item on the order has a Price in the Menu tab.
- `source` is `Website`, or `API · <key name>`.
- Times are UTC.
- Dates in options (`date`, `from`, `to`) use the script's time zone (Apps Script → Project Settings).

## Using it from the inventory project
- **Ingredient totals for a period:** call `usage`. Cancelled orders are already left out, and amounts use the units in `Recipe_BOM` (convert to stock units with the pack sizes in `Materials`).
- **Keeping a running copy:** poll `orders?since=<last time you checked>&detail=true` every few minutes. Each reply includes new orders and orders whose status changed (for example cancelled), so you can subtract or add back the ingredients.
- **Reading the Sheet directly:** `Order_Constituents` has the same data, one row per ingredient per order, with a `Status` column.

## Limits
- Each call takes about 1–2 seconds, and orders are saved one at a time (a lock prevents two orders getting the same ID). That's plenty for a café counter. For hundreds of orders a minute, move the data to a database.
- A busy café adds roughly 100k ingredient rows a year to `Order_Constituents`, well within Google Sheets' 10 million cell limit. Archive old rows to another tab once a year to keep `usage` fast.
