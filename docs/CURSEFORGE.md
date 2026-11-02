# Публикация на CurseForge

## Первая публикация

1. Войти на [authors.curseforge.com](https://authors.curseforge.com/) и создать проект:
   игра World of Warcraft, класс Addons.
2. Заполнить форму значениями из раздела «Поля проекта» ниже. Логотип: `docs/curseforge-logo.png`.
3. На вкладке Files загрузить zip из раздела «Сборка zip вручную»: Release, игра 2.5.6, changelog из
   `CHANGELOG.md`. После этого файл уходит на модерацию.
4. Записать Project ID из блока About Project на странице проекта.

## Автоматические релизы

1. В `CheapBids/CheapBids.toc` добавить строку `## X-Curse-Project-ID: <Project ID>`.
2. Создать токен на [странице API tokens](https://authors.curseforge.com/#/settings/api-tokens) и
   сохранить его в GitHub: Settings -> Secrets and variables -> Actions -> `CF_API_TOKEN`.
3. Для релиза дописать `CHANGELOG.md`, закоммитить и запушить тег:
   `git tag v2.1.1 && git push origin main v2.1.1`.

После патча игры обновить `## Interface:` во всех четырёх `.toc`, иначе аддон станет устаревшим.

## Сборка zip вручную

Zip собирает [`scripts/package.ps1`](../scripts/package.ps1). Он кладёт в архив четыре папки аддона,
в каждую добавляет `LICENSE`, а в `.toc` подставляет версию:

```powershell
pwsh scripts/package.ps1 -Version v2.1.0
```

Результат: `dist/CheapBids-v2.1.0.zip`.

## Поля проекта

**Name:** `CheapBids`

**Summary:**

```text
Scan the whole auction house, find the cheapest bids and place them by hand from a fast sortable table.
```

**Class:** Addons. **Main category:** Auction & Economy. **License:** GNU General Public License
version 2 (GPLv2).

**Description:**

```markdown
# CheapBids

CheapBids finds cheap auctions that everyone else missed. It scans the whole auction house at once and lists every lot in your bid range, which is 1-99 copper by default, in a fast sortable table.

Every bid and buyout is your own click. CheapBids is not a bot and never buys anything on its own.

## Features

- **Full scan:** reads the whole auction house in seconds, without freezing the game. The server allows one full scan about every 15 minutes.
- **Filters:** set bid and buyout ranges in gold, silver and copper, and pick the time-left groups to show.
- **Table:** sort by item, rarity, quantity, seller, bid, buyout, market price or time left.
- **Bid and buy:** click a row and press `bid` or `buy`, double-click to bid, or bind a hotkey.
- **Price protection:** asks you to confirm a bid or buyout that looks too expensive for the item.
- **My bids:** shows your bids with outbid lots on top in red, ready to re-bid.
- **Auc min:** shows the lowest buyout from your last full scan in the table and on item tooltips. Hold Shift to price the whole stack.

## Optional modules

All modules come in the same download, and you can turn each one off in the AddOns list.

- **Disenchant:** tooltips show what an item disenchants into, with chances and an estimated value. Also unlocks the `dis. loot` view, which lists lots worth buying out and disenchanting.
- **Prospect:** tooltips show which gems an ore can yield, and which ores a gem comes from.
- **CompactBrowse:** turns the default Browse tab into a dense list of thin rows.

## How to use

1. Open the auction house and pick the **CheapBids** tab.
2. Press `scan auc`.
3. Set your filters and press `search`.
4. Select a row and press `bid` or `buy`. Do this soon after scanning, because scan results go stale.

Type `/cb` to open the tab. Options are in Interface -> AddOns -> CheapBids.

## Compatibility

Disable Auctioneer and Auctionator while bidding. Auction addons share a single auction list, so a second addon overwrites it and your bids fail.

## Credits

CheapBids is free software under the GNU GPL v2 or later. Source code: https://github.com/Reactobus/CheapBid

- The Disenchant and Prospect modules use data and logic from Enchantrix by Norganna's AddOns (http://enchantrix.org/), GPL v2 or later.
- The CompactBrowse module is derived from Auc-Util-CompactUI, part of Auctioneer by Norganna's AddOns (http://auctioneeraddon.com/), GPL v2 or later.
```
