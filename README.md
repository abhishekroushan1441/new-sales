# Café Orders

An order website for the counter. Staff tap items, place the order, and move it through **New → Preparing → Ready → Completed**. Every order is saved in Supabase along with the ingredients it used (taken from the recipes), so the inventory project can see exactly how much coffee, milk and so on went out.

- **Website:** https://abhishekroushan1441.github.io/new-sales/
- **API:** see [API.md](API.md). Reading is a plain link, e.g. latest orders, orders between two dates, or everything that changed since last time (so nothing is counted twice).

## What's in here

| File | What it is |
|---|---|
| `index.html` | The website (GitHub Pages serves this) |
| `supabase/setup.sql` | Creates the `cafe` schema: tables, the API functions and security |
| `API.md` | Endpoints, examples and how to sync without double counting |

The menu, recipes, materials and API keys are loaded with a separate seed file that isn't in this repo, because the repo is public.

## Where the data lives

Supabase → **Table Editor** → pick the **cafe** schema at the top:

- `menu_items`: what can be ordered. Fill in `price` to get totals; set `available` to false to hide an item.
- `recipe_bom`: what each menu item uses. Orders save these amounts at the moment they're placed.
- `materials`: raw materials with categories and units.
- `orders`, `order_items`, `order_constituents`: filled in automatically.
- `api_keys`: who can call the API (`read` or `write`).
- `settings`: shop name, currency, order types, time zone.

The tables aren't reachable from the internet directly. The website and the API go through a few database functions that check the API key first.

## Setup (already done for this shop)

1. Supabase → **SQL Editor** → paste `supabase/setup.sql` → **Run**.
2. Run the private seed file the same way.
3. The Supabase URL and publishable key are in `index.html`. They're safe to be public: they can only call the order functions, and those need an API key.

## Connecting a staff device

No key is stored in the code. Each staff phone or tablet connects once, in one of two ways:

- **Setup link (easiest):** send staff `https://abhishekroushan1441.github.io/new-sales/#key=<write key>`. The device saves the key and it's cleared from the address bar.
- **Connect screen:** open the site and paste a `ck_w_…` key.

To disconnect a device, use **Disconnect** at the bottom of the page (tap twice). To lock out a lost device, set that key's `active` to false in `cafe.api_keys` and give everyone a new key.
