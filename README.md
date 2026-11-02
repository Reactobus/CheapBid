# CheapBids

An auction house addon for World of Warcraft **TBC Classic Anniversary 2.5.6**.

It scans the whole auction house, lists the cheapest bids (1-99 copper by default),
and lets you bid or buy out from a fast sortable table. Every bid and buyout is a
click of yours. CheapBids is **not** a bot and never buys anything on its own.

## Install

Install it through CurseForge, or copy these folders into
`World of Warcraft\_anniversary_\Interface\AddOns\` and restart the game:

- `CheapBids` (required)
- `CheapBids_Disenchant` (optional)
- `CheapBids_Prospect` (optional)
- `CheapBids_CompactBrowse` (optional)

> **Important:** disable Auctioneer while bidding. It overwrites the shared auction
> list, so bids hit stale data. Auctionator works fine alongside CheapBids.

## Use

1. Open the auction house and pick the **CheapBids** tab.
2. Press `scan auc` for a full scan (server cooldown is about 15 minutes).
3. Set the **Bid**, **Buyout** and **Time left** filters, then press `search`.
4. Click a row, then press `bid` or `buy` (or double-click the row to bid). Bid soon
   after scanning, because scan results go stale.

Other buttons:

- `my bids` shows your bids, outbid lots first in red, so you can re-bid them.
- `dis. loot` lists lots worth buying out and disenchanting (needs the Disenchant module).

Slash commands: `/cb` opens the tab, `/cbde` toggles the disenchant tooltip, `/cbpr` the
prospecting tooltip, `/cbrowse` the compact Browse tab. A bid hotkey and all options are
in the game settings (Key Bindings, and Interface -> AddOns -> CheapBids).

## Limits

- Bids must come from a real click or key press. This is a Blizzard restriction, so
  bulk auto-bidding is not possible.
- The client reports only four time-left buckets (`<30m`, `30m-2h`, `2-12h`, `>12h`), so
  12, 24 and 48 hour auctions look the same to buyers.

## Credits and license

CheapBids is free software under the [GNU GPL v2 or later](LICENSE).

- `CheapBids_Disenchant` and `CheapBids_Prospect` use data and logic from
  [Enchantrix](http://enchantrix.org/) by Norganna's AddOns (GPL v2 or later).
- `CheapBids_CompactBrowse` is derived from Auc-Util-CompactUI, part of
  [Auctioneer](http://auctioneeraddon.com/) by Norganna's AddOns (GPL v2 or later).

Design notes for contributors are in `CLAUDE.md`, and releasing is covered in
`docs/CURSEFORGE.md`.
