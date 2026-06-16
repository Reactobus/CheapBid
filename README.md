# CheapBids

A World of Warcraft **TBC Classic 2.5.5** (anniversary client) auction-house addon.

It scans the whole auction house (GetAll), lists every lot with a **bid of 1–99
copper**, and lets you place those bids **manually**. It only shows the list — you
click each bid yourself. It is **not** a bot and does not auto-buy.

## Install

Copy the `CheapBids/` folder into:

```
World of Warcraft\_anniversary_\Interface\AddOns\
```

(the folder name must stay `CheapBids`), then `/reload` in game.

> **Important:** disable Auctioneer / Auctionator while bidding — two AH addons
> fight over the single auction list and bids hit stale data. CheapBids is
> self-contained so it can be the only AH addon.

## Use

1. Open the auction house, pick the **CheapBids** tab.
2. `scan auc` — full GetAll scan (server cooldown ~15 min between scans).
3. Set the **Bid** / **Buyout** filters and the **Time left** checkboxes, press `search`.
4. Click a row, then `bid` (or double-click the row). **Bid right after scanning** —
   the scan snapshot is only valid briefly.

Slash: `/cb` toggles the tab, `/cb debug` logs each bid attempt.

## Notes / limits

- Bids must come from a real click/keypress — bulk auto-bidding is impossible on
  this client (a Blizzard restriction, not a missing feature).
- The legacy API only exposes 4 time-left buckets (`<30m / 30m-2h / 2-12h / >12h`);
  12/24/48h cannot be told apart by buyers.
- See `CLAUDE.md` for the full design notes, the auction-API details, and what did
  and didn't work.

## License

Personal project. Use at your own risk.
