# Café Orders

An order website for the counter. Staff tap items, place the order, and move it through **New → Preparing → Ready → Completed**. Every order is saved to a Google Sheet along with the ingredients it used (taken from the recipe sheet), so the inventory project can see exactly how much coffee, milk and so on went out.

- **Website:** https://abhishekroushan1441.github.io/new-sales/
- **API:** see [API.md](API.md)

## What's in here

| File | What it is |
|---|---|
| `index.html` | The website (GitHub Pages serves this) |
| `apps-script/Code.gs` | The backend and API, runs inside the Google Sheet |
| `apps-script/Index.html` | The same website, served from Apps Script |
| `API.md` | API keys, actions and examples |

The Google Sheet itself (menu, recipes, materials, orders, API keys) isn't in this repo, because the repo is public.

## The Sheet

It needs these tabs (column names matter, column order doesn't):

- **Menu:** Category, Item, Price, Available
- **Recipe_BOM:** the ingredients for each menu item
- **Materials:** the raw material list
- **Orders**, **Order_Items**, **Order_Constituents:** filled in automatically
- **API_Keys:** Key, Name, Scope (`read` or `write`), Active, Last Used
- **Settings:** Shop Name, Currency, Order Types

## Setup

1. Open the Sheet → **Extensions → Apps Script**.
2. Paste `apps-script/Code.gs` into `Code.gs`. Add an HTML file named `Index` and paste `apps-script/Index.html` into it.
3. **Deploy → New deployment → Web app.** Execute as: *Me*. Who has access: *Anyone*. Copy the URL ending in `/exec`.

That URL is already a working order website. The GitHub Pages site is the same page, and it works once a device is connected.

## Connecting a device to the GitHub Pages site

No key is stored in the code. Each staff phone or tablet connects once, in one of two ways:

- **Setup link (easiest):** send staff this link, with your own values:
  ```
  https://abhishekroushan1441.github.io/new-sales/#api=<exec URL>&key=<write key>
  ```
  The device saves the connection and the key is cleared from the address bar.
- **Connect screen:** open the site, then paste the `/exec` URL and a `write` key from the API_Keys tab.

To disconnect a device, use **Disconnect** at the bottom of the page (tap twice). To lock out a lost device, set that key's **Active** to `FALSE` in the Sheet.

## After changing the code

Apps Script → **Deploy → Manage deployments → Edit → Version: New version → Deploy.** The `/exec` URL stays the same.
