# Norg addons

WoW 3.3.5a (WotLK) addons. Written for a private AzerothCore server, but the
client side of each one works anywhere — see **Server support** below for the two
that need more than the client can provide.

## The addons

| Addon | What it does |
|---|---|
| **NorgQuest** | Quest arrow that follows a real path, draws the route on the world map, and routes across continents by boat and zeppelin |
| **NorgNav** | Arrow to the next boss in a dungeon, with real pathing rather than a straight bearing |
| **NorgAHValue** | Fills the auction sell slot at the highest price the server's auction-house bot will actually pay |
| **NorgMail** | Empties the mailbox from one button, skipping C.O.D. and GM mail |
| **NorgDungeons** | Dungeon reference data |
| **NorgOneBag** | Single-bag inventory view |
| **NorgRoutes** | Route data used by the navigation addons |

## Install

Copy the folder you want into `Interface/AddOns/` and **restart the client**.
`/reload` will not pick up a newly added addon — 3.3.5a only scans the AddOns
folder at launch.

## Server support

**NorgQuest** and **NorgNav** are thin clients. The pathing, quest-objective
resolution and transport routing all happen server-side in a companion module,
and the addon talks to it over the addon message channel. Without that module
they will load and do nothing useful.

**NorgAHValue** prices against a specific auction-house bot's buying rules. The
numbers in `DataSell.lua` / `DataVendor.lua` are generated from a server's item
table; on a different server they will be wrong.

**NorgMail** is pure client and works anywhere.

## Tests

Each addon has a stub harness that drives the real code against fake client APIs
and asserts on what it actually did:

    docker run --rm -v "$PWD:/data" nickblah/lua:5.1-luarocks lua /data/mail_test.lua

(!) **A test that cannot fail is worse than no test.** This project has shipped
several that could not: a check of the form `(frame and true) and true`; a stub
that always reported a usable frame width, so eleven map-line tests passed
against code that could not draw anything; and a position packet with the wrong
field count, so the render path was never exercised at all. Before trusting a new
test, break the behaviour on a scratch copy and confirm the test fails there.

## Notes on 3.3.5a

Every client bug in this project has been an API gap rather than logic:

- no `Texture:SetRotation` (4.0+), so rotation is done with the eight-argument `SetTexCoord`
- no `SetSize`, no `FontString:SetScript`
- `GetQuestLogTitle` returns no quest id — it has to be dug out of the quest link
- `UnitOnTaxi()` is **false** aboard a boat or zeppelin; it only covers flight paths
