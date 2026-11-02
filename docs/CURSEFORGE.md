# Публикация на CurseForge

## Первая публикация

1. Войти на [authors.curseforge.com](https://authors.curseforge.com/) и создать проект:
   игра World of Warcraft, класс Addons.
2. Заполнить форму значениями из раздела «Поля проекта» ниже. Логотип: `docs/curseforge-logo.png`.
3. На вкладке Files загрузить zip из раздела «Сборка zip вручную»: Release, игра 2.5.6, changelog из
   `CHANGELOG.md`. После этого файл уходит на модерацию.
4. Записать Project ID из блока About Project на странице проекта.

Особенности редактора CurseForge:

- Логотип должен быть не шире 850 px. Кнопка Upload image на вкладке General единственный способ его
  заменить: скрытое поле `input[type=file]` на странице вставляет картинку в описание.
- После Discard changes редактор описания переходит в WYSIWYG, и Markdown сохраняется как простой текст.
  Перед Save нужно проверить, что выбран режим Markdown и предпросмотр показывает форматирование.
- URL нельзя писать в круглых скобках: закрывающая скобка попадает в ссылку.

## Автоматические релизы

1. В `CheapBids/CheapBids.toc` добавить строку `## X-Curse-Project-ID: 1780581`.
2. Создать токен на [странице API tokens](https://authors.curseforge.com/#/settings/api-tokens) и
   сохранить его в GitHub: Settings -> Secrets and variables -> Actions -> `CF_API_TOKEN`.
3. Для релиза дописать `CHANGELOG.md`, закоммитить и запушить тег:
   `git tag v2.1.2 && git push origin main v2.1.2`.

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
Scans the whole auction house and lists lots with a bid of 1-99 copper, so you can snipe them by hand.
```

**Class:** Addons. **Main category:** Auction & Economy. **License:** GNU General Public License
version 2 (GPLv2).

**Description:**

```markdown
# CheapBids

Now and then someone lists an item with a 1 copper starting bid and nobody notices. CheapBids is built to find those lots. It scans the whole auction house in one go and shows everything in your bid range (1-99 copper by default) in a table you can sort.

You place every bid and buyout yourself, one click at a time. It's not a bot and it won't buy anything on its own.

![The CheapBids tab in the auction house](https://media.forgecdn.net/attachments/2140/174/curseforge-screenshot-png.png)

## What it does

- Scans the whole auction house in one pass without freezing the game. The server only allows a full scan about every 15 minutes.
- Filters by bid and buyout range (gold, silver, copper), rarity and time left.
- Sorts by item, rarity, quantity, seller, bid, buyout, market price or time left.
- Click a row and press `bid` or `buy`. Double-clicking a row also bids, and you can bind a hotkey.
- Asks first if a bid or buyout looks too expensive for the item.
- The `my bids` view lists your bids with the outbid ones on top in red, so you can re-bid.

## Prices on your items

Every full scan remembers the lowest buyout of each item. That price then shows up as "Auc min" in the table and on item tooltips, including your bags, recipes, loot and mail, so you can see what things are worth without opening the auction house.

Prices stay saved after you log out and update with your next full scan. Hold Shift over an item to see the price for the whole stack.

## Optional modules

They come in the same download. If you don't want one, untick it in the AddOns list.

- **Disenchant** adds to the tooltip what an item disenchants into, with chances and an estimated value. It also unlocks the `dis. loot` view, which lists lots worth buying out and disenchanting.
- **Prospect** shows which gems an ore can give and which ores a gem comes from.
- **CompactBrowse** turns the default Browse tab into a dense list of thin rows.

## How to use it

1. Open the auction house and pick the **CheapBids** tab.
2. Press `scan auc`.
3. Set your filters and press `search`.
4. Select a row and press `bid` or `buy`. Don't wait too long after the scan, because the results go stale.

`/cb` opens the tab. Options are in Interface -> AddOns -> CheapBids.

## Using it with other auction addons

CheapBids works fine next to Auctionator, so you can leave it on. Auctioneer is different: turn it off while you bid, because it overwrites the auction list and your bids fail.

## Credits

CheapBids is free software under the GNU GPL v2 or later. Source code: https://github.com/Reactobus/CheapBid

- The Disenchant and Prospect modules use data and logic from [Enchantrix](http://enchantrix.org/) by Norganna's AddOns, GPL v2 or later.
- The CompactBrowse module is derived from Auc-Util-CompactUI, part of [Auctioneer](http://auctioneeraddon.com/) by Norganna's AddOns, GPL v2 or later.
```
