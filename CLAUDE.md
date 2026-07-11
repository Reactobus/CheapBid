# CheapBids — гид по проекту (для Claude Code)

Аддон для **WoW TBC Classic 2.5.5** (юбилейный клиент `_anniversary_`). Сканирует
весь аукцион (GetAll), показывает лоты со **ставкой 1–99 медью**, и даёт ставить
по ним **вручную** (игрок жмёт кнопку/строку — это НЕ бот).

> Видимый текст в самом аддоне — **английский** (по требованию игрока).
> Ответы в чат игроку — **русский**.

---

## ⚠️ Самообучение и ошибки — ЧИТАЙ ПЕРВЫМ

Журнал ошибок и чеклист «перед готово» — в **[`docs/LESSONS.md`](docs/LESSONS.md)**. Это
**единственный** источник для регистрации факапов (НЕ persistent-память: она не под git и не видна
человеку/воркерам).

**Протокол (обязателен):**

1. **Перед тем как сказать «готово/работает/протестировано»** — пройти весь чеклист из начала
   `docs/LESSONS.md` (тесты → покрыт путь игрока → задеплоено → деплой проверен `grep` → `/reload`).
2. **После любой ошибки** (регресс, потеря золота/данных, ложное «готово») — добавить запись
   `ERR-NNNN` в реестр `docs/LESSONS.md`; если ошибка нового класса — дописать пункт в чеклист.
3. Чеклист — живой: каждое правило выведено из конкретной записи реестра.

«Тесты прошли» ≠ «готово». Готово = задеплоено в игру + проверено + игроку сказано `/reload`.

---

## Где что лежит

| Что | Путь |
|-----|------|
| Игра, папка аддонов | `C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\CheapBids\` |
| Этот репозиторий | `C:\Users\Skullcrusher\Documents\GitHub\CheapBid\` |
| Исходник аддона в репо | `CheapBid\CheapBids\` (`CheapBids.lua`, `CheapBids.toc`, `Bindings.xml`) |
| Модуль-плагин CompactBrowse | `CheapBid\CheapBids_CompactBrowse\` (`CompactBrowse.lua`, `CheapBids_CompactBrowse.toc`) |
| Модуль-плагин Disenchant | `CheapBid\CheapBids_Disenchant\` (`Disenchant.lua`, `CheapBids_Disenchant.toc`) |
| Модуль-плагин Prospect | `CheapBid\CheapBids_Prospect\` (`Prospect.lua`, `CheapBids_Prospect.toc`) |
| Remote | `https://github.com/Reactobus/CheapBid.git` |

**Плагин-модули (каждый — отдельный аддон, `## Dependencies: CheapBids`, деплой своей папкой;
новая папка → нужен полный рестарт игры, не `/reload`):**
- **Disenchant** (`/cbde`) — тултип распыла + строка «Disenchanted from» + money-строка
  «Disenchant price» под «Auc min»: матожидание распыла (Σ шанс × ср.кол-во × Auc min рега)
  по ценам последнего GetAll. Цены/формат берёт из `CheapBidsPublic` (крошечный публичный
  API главного аддона: `UnitPrice`, `CoinText`).
- **Prospect** (`/cbpr`) — тултип «руда→самоцветы» + строка «Prospected from».

Тумблеры и параметры — в **панели настроек игры** (Interface → AddOns → CheapBids): проценты
защиты, fallback, вкл/выкл тултипов и Compact Browse. Всё пишется в `CheapBidsDB`.

> **Selling/Shopping-вкладки (история решения, 2026-07-09):** свои модули CB Shop/CB Sell были
> написаны и **удалены** — вышли сырыми, а «просто скопировать» вкладки Auctionator нельзя:
> его лицензия — **All Rights Reserved** (читать/изучать можно, копировать код — нет; это не
> GPL, как у Enchantrix). Если возвращаться к идее — писать своё с нуля, подглядывая только
> алгоритмы, либо ужиться с включённым Auctionator, проверив конфликт ставок.

**Деплой в игру:** скопировать папку `CheapBids\` из репо в `...\Interface\AddOns\`
(имя папки обязано совпадать с именем `.toc` — `CheapBids`), затем в игре `/reload`.
Папка репо называется `CheapBid` (без `s`), поэтому **клонировать прямо в AddOns
нельзя** — копируется именно вложенная `CheapBids\`. Модули CompactBrowse и Disenchant —
**отдельные аддоны**: копируются своими папками (`CheapBids_CompactBrowse\`,
`CheapBids_Disenchant\`) рядом с `CheapBids\` (зависят через `## Dependencies: CheapBids`).

**Цикл разработки:** правим `CheapBid\CheapBids\CheapBids.lua` → копируем в AddOns →
`/reload` в игре → тест. (Lua-интерпретатора на машине нет — синтаксис проверяем
чтением/ревью, ошибки видны в игре при включённом `/console scriptErrors 1`.)

---

## Файлы

- **`CheapBids.lua`** — весь аддон (self-contained, без внешних либ; своя таблица).
- **`CheapBids.toc`** — `## Interface: 20506` (bump per game patch — 2.5.6 = 20506), `SavedVariables: CheapBidsDB`.
- **`Bindings.xml`** — хоткей `CHEAPBIDS_BIDTOP` → `CheapBids_KeyBid()` (= ставка по выбранному/верхнему валидному лоту).

Слэш: `/cb`, `/cheapbids` — открыть/переключить вкладку. `/cb debug` — логировать
каждый `PlaceAuctionBid` (для диагностики ставок).

**Модуль-плагин `CheapBids_CompactBrowse`** (отдельный аддон, порт Auctioneer
`Auc-Util-CompactUI`): делает **дефолтную** вкладку Browse аука компактной — 14 тонких
строк (19px) вместо ~8, имена лотов окрашены по редкости (рисуются как item-link).
Самодостаточен, кода CheapBids не трогает; ставки идут через штатную `BrowseBidButton`.
Подменяет **глобальную функцию** `AuctionFrameBrowse_Update` (taint ограничен путём
Browse — не путать с классом ERR-0003, где заражалась глобальная *таблица*). Слэш
`/cbrowse` — вкл/выкл (пишется в `CheapBidsDB.compactBrowse`, применяется после `/reload`).

**Модуль-плагин `CheapBids_Disenchant`** (отдельный аддон, порт disenchant-тултипа
Enchantrix): при наведении на uncommon/rare/epic оружие или броню тултип показывает
блок `Disenchants into:` — реагенты, шанс и среднее количество. Данные —
`baseDisenchantTable` Enchantrix (classic-ветка `EnxConstants.lua`, скопирована 1:1),
брекет = первый bound `>= ilvl`, weapon у rare/epic падает на armor-таблицу. Без
LibStub/Babylonian/Stubby, чисто статическая таблица. Хуки только через `HookScript`
на стандартные тултипы (аддитивно, taint не создаёт). Слэш `/cbde` — вкл/выкл
(пишется в `CheapBidsDB.disenchantTip`, применяется сразу, без `/reload`). Тесты:
`tests/spec_disenchant.lua` (запускаются общим `node tests/run.js`).

---

## Как устроен аукцион (legacy API 2.5.5)

Клиент Lua 5.1, **legacy** аукционный API (НЕ retail `C_AuctionHouse`).

### Сканирование
- **GetAll (быстрый, нужен для ставок):**
  `QueryAuctionItems("", nil,nil, 0, nil,nil, true, false, nil)` — 7-й аргумент `getAll=true`.
  Разрешён только когда **2-е** возвращаемое значение `CanSendAuctionQuery()` (`canQueryAll`) = true.
  **Серверный кулдаун ~15 мин (900с)** между GetAll. Это единственный реальный
  числовой лимит сервера.
- **Постраничный (медленный, для ставок НЕ годится):** `getAll=false`, по странице
  (`NUM_AUCTION_ITEMS_PER_PAGE`=50). У постранично прочитанных лотов **нет валидного
  `idx`** (в `"list"` живёт только последняя страница) → ставить по ним нельзя.

### Снимок (snapshot) — КЛЮЧЕВОЕ
- После GetAll данные лежат в `"list"`; читаем `GetAuctionItemInfo("list", i)` по
  `i = 1..GetNumAuctionItems("list")`.
- **Снимок ТРАНЗИЕНТНЫЙ:** валиден лишь **короткое время** после скана, индексы
  быстро «протухают», умирает при закрытии АГ. → **ставить надо сразу после скана.**
- Мы кэшируем данные в свою таблицу (`scanCache`/`cheapItems`) и храним `it.idx` =
  позиция в снимке (только при GetAll, `storeIdx=true`). Таблица показывает НАШУ
  копию, а ставка идёт по живому `"list"` через `it.idx`.

### Поля `GetAuctionItemInfo("list", i)` (TBC/legacy)
```
1 name  2 texture  3 count  4 quality  5 canUse  6 level  7 levelColHeader
8 minBid  9 minIncrement  10 buyout  11 bidAmount  12 highBidder
13 bidderFullName  14 owner  15 saleStatus  16 ...  17 itemID
```
- Эффективная ставка: `eff = (bidAmount>0) and bidAmount+minIncrement or minBid`.
- `highBidder` (12) = ты уже лидируешь по лоту (тогда ставить не нужно).

### Время до конца — `GetAuctionItemTimeLeft("list", i)`
Возвращает **код 1–4**, НЕ точное время:
`1 = <30м`, `2 = 30м–2ч`, `3 = 2–12ч`, `4 = >12ч`.
**Различить 12/24/48ч у покупателя НЕЛЬЗЯ** — всё >12ч это один код `4`.
Срок 12/24/48 выбирает продавец; покупателю не отдаётся.

### Ставка
- `PlaceAuctionBid("list", index, eff)`.
- Подтверждение: монетный звук + `CHAT_MSG_SYSTEM` == `ERR_AUCTION_BID_PLACED`
  («Bid accepted»).
- Отказ: `UI_ERROR_MESSAGE` == `ERR_AUCTION_DATABASE_ERROR` («Internal auction
  error.») — лот изменился/ушёл/индекс протух.

---

## ⚠️ Жёсткие ограничения (проверено на практике)

1. **HARDWARE EVENT.** `PlaceAuctionBid` срабатывает ТОЛЬКО из реального клика/нажатия
   клавиши. Ставки из `C_Timer`/обработчиков событий клиент **молча отбрасывает**.
   → **Автобид «одной кнопкой на все» невозможен** в принципе (у Auctioneer та же
   история — его «Yes» = один клик на ставку).
2. **Только один АГ-аддон.** Auctioneer/Auctionator постоянно шлют свои
   `QueryAuctionItems` и **затирают общий `"list"`** → наши ставки бьют по чужому
   снимку и падают. **Для ставок их надо ОТКЛЮЧИТЬ.** Поэтому аддон self-contained.
3. **Снимок живёт секунды.** Бить сразу после скана. Через время индексы протухают —
   ставка не проходит.
4. **GetAll на 15-мин кулдауне.** Пока кулдаун — снимок не обновить, ставки
   ненадёжны. Лимита «ставок в минуту» официально НЕТ; темп режет серверный
   анти-спам (после серии — `ERR_AUCTION_DATABASE_ERROR`) + латентность подтверждения
   каждой ставки. Реально — десятки/мин, но дешёвые 1c-лоты разбирают быстро.
5. **Тайм-лефт — 4 корзины**, точного времени нет.

---

## Методики: что РАБОТАЕТ ✅

- **Прямая ставка из свежего GetAll-снимка** по `it.idx`:
  `PlaceAuctionBid("list", it.idx, eff)` внутри клика. Это путь, при котором ставки
  реально вставали (сервер даже резал по анти-спаму от количества).
- **Перебор до первого валидного лота** (`TryBid`/`NextBiddable`): если у выбранного
  лота `idx` протух — бить следующий валидный из `cheapItems`. Так клик почти всегда
  попадает, пока окно снимка открыто.
- **Подтверждение по состоянию игры** (`highBidder`) + по чату (`ERR_AUCTION_BID_PLACED`),
  и удаление лота из таблицы только после реального подтверждения.
- **Своя таблица** (`FauxScrollFrame`, кастомные строки) — без внешних либ, чтобы
  отключать Auctioneer/Auctionator.
- **Батч-обработка GetAll** (`GETALL_BATCH ≈ 5000` за кадр через `C_Timer.After(0)`) —
  быстрый разбор 200k+ лотов без фриза.
- **Иконки** через `GetItemInfoInstant(itemID)` (работают даже для незакэшированных).
- `CreateFrame(..., "BackdropTemplate")` для рамок (в 2.5.5 у обычного фрейма нет
  `SetBackdrop`).

## Методики: что НЕ работает / грабли ❌

- **Точечный пере-запрос лота перед ставкой** (`FocusQuery` + exact-match
  `QueryAuctionItems`): затирает живой GetAll-снимок, ломает прямой путь, даёт UX
  «press bid again» и нестабильные ставки. **Убрано из вызовов** (функции
  `FocusQuery`/`MatchInLive` остались мёртвым кодом — можно удалить).
- **Префетч на клик по строке** — убивал свежий снимок, ломал прямую ставку.
- **Авто-цикл ставок через `C_Timer`** — отбрасывается (hardware event).
- **Точное равенство `eff == it.bid`** как условие ставки — падает, если цену успели
  подвинуть; надо матчить по идентичности и бить текущий `eff`, если он ещё проходит
  фильтр.
- **Запуск с включёнными Auctioneer/Auctionator** — затирают `"list"`, ставки мимо.
- **O(N²) по `scanCache`** (перебор 200k на каждый лот) → «script ran too long».
  Перебирать только маленький `cheapItems`.
- **Unicode-глифы** (✓ ▶ ∞ — –) → «тофу». Только ASCII (кириллица в строках — ок).

---

## Архитектура UI

Вкладка в `AuctionFrame` (`AuctionTabTemplate`), показывается поверх Browse/Bid/Auctions.

- **Верх — фильтр:** `Bid from/to` и `Buyout from/to`, по три поля g/s/c с иконками
  монет. Пусто = любой. Справа от строки — системный статус (скан/прогресс).
- **Левая панель** (`leftCol`): кнопки `scan auc` / `search` / `bid` / `cancel`
  (в режиме скана `scan auc` → `Stop`), прогресс-бар, счётчики `Cache:`/`Found:`,
  чекбоксы времени `<30m / 30m-2h / 2-12h / >12h`, статус ставок (под чекбоксами).
- **Правая панель** (`rightPanel`/`listFrame`): таблица, колонки
  `Item / Rarity / Qty / Seller / Bid / Buyout / Auc min / Time left`, сортировка по
  клику на заголовок, `FauxScrollFrame`. Клик по строке — выбор; дабл-клик — ставка.
  Ширины колонок — константы `C_RAR/C_CNT/C_SELLER/C_BID/C_BUY/C_AUC/C_TIME` (Bid/Buyout
  узкие; имя `name` — флекс). Правишь ширину/порядок — синхронно правь **три** места:
  `headerBtn`-и, массив `seps` и создание `*FS` в строке (offset'ы считаются от правого края).

### Поток
`scan auc` (GetAll) → авто-`ApplyFilter` → правка фильтра → `search` → выбрать строку
→ `bid` (или дабл-клик / хоткей). `cancel` прерывает скан.

### Ключевые функции (`CheapBids.lua`)
- `ReadIndexInto` — читает лот из `"list"` в кэш (с `idx` при GetAll).
- `ProcessGetAll` / `StartScan` / `StartPageScan` / `PageScanUpdate` — скан.
- `ApplyFilter` / `PassesFilter` / `TimeShown` / `SortItems` / `UpdateTable` — выдача.
- `TryBid(it)` — прямая ставка по одному лоту (валидация + `PlaceOn`).
- `BidItem(it)` — бьёт выбранный, иначе первый валидный (`TryBid` по `cheapItems`).
- `PlaceOn` — `PlaceAuctionBid` + `pending`/`attempted` + сторож `ArmBidWatch`.
- `ReconcileBids` / `ConfirmOldest` / `RejectOldest` — подтверждение/откат, удаление
  лота из таблицы после подтверждения.
- Состояние ставок: `pending` (FIFO), `attempted`, `bidsOK/bidsFail`, `it._bidIdx`.

### Auc min price (порт механизма Auctionator)
- Во время GetAll `ReadIndexInto` (только при `storeIdx=true`) сворачивает **за-единицу**
  buyout каждого лота в `scanPriceDB[itemID] = min` (O(1) на лот). При завершении
  `ProcessGetAll` коммитит его в `priceDB` и в **SavedVariable** `CheapBidsDB.priceDB`
  (+`priceDBTime`) — цена живёт между сессиями до следующего GetAll. Постраничный скан
  прайс-БД **не** трогает (не полный рынок).
- `AucUnit(it)` — рыночная мин-цена за единицу для `it.itemID` (или nil). Колонка
  `Auc min` показывает её; тултип (`PriceTip`, аддитивный `HookScript`, taint не создаёт)
  подписывает цену на **любом** предмете. **Shift** в тултипе = цена за весь стак
  (`unit × кол-во`; кол-во стака ловится из слота сумки через `StashStack`).
- **Perfect sort** (`Significance`) ранжирует по `value/bid`, где `value = AucUnit × cnt`
  (рыночная стоимость всего лота), с откатом на собственный buyout лота, если предмета
  нет в `priceDB`. Наверх — дешёвая ставка на дорогой по рынку предмет.
- Тесты: блок «Auc min price DB + Perfect sort + price tooltip» в `tests/spec.lua`.

---

## Правила (безопасность / анти-бан)

- Аддон **только показывает** список и ставит **по клику игрока**. Никакого
  авто-выкупа/авто-цикла. Это намеренно — чтобы не быть ботом.
- Не трогаем чужие аддоны и игровые файлы кроме папки `CheapBids`.
