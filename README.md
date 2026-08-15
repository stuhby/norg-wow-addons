# Norg addons

WoW 3.3.5a (WotLK) addons. Written for a private AzerothCore server, but the
client side of most of them works anywhere — see **Server support** below for the
three that need more than the client can provide.

## The addons

Versions are the ones in each `.toc`, which is also what the addon prints in chat
as it loads. If the line in chat says something else, you are running an older
copy than this table describes.

| Addon | Version | Command | What it does |
|---|---|---|---|
| **NorgQuest** | 1.12 | `/quest` | Quest arrow that follows a real path, draws the route on the world map, and routes across continents by boat and zeppelin |
| **NorgNav** | 2.7 | `/nav` | Arrow to the next boss in a dungeon, with real pathing rather than a straight bearing |
| **NorgHearth** | 1.0 | `/hs` | Save up to eight innkeeper binds and pick which one the hearthstone sends you to |
| **NorgAHValue** | 1.5 | `/ahprice` | Fills the auction sell slot at the highest price the server's auction-house bot will actually pay |
| **NorgMail** | 1.5 | `/mail` | Empties the mailbox from one button, skipping C.O.D. and GM mail |
| **NorgDungeons** | 1.0 | `/dungeon` | 101 dungeon and raid maps with the server's real boss order, a marker legend, and bosses greying out as you kill them |
| **NorgOneBag** | 1.0 | `/onebag` | Single-bag inventory view |
| **NorgRoutes** | 1.0 | `/route` | Boss order for 69 instances, with the compass bearing and distance from each boss to the next |

## Install

Copy the folder you want into `Interface/AddOns/` and **restart the client**.

(!) **`/reload` will not pick up a newly added addon** — 3.3.5a scans the AddOns
folder at launch only, so a folder copied in while the game is running does not
exist as far as the client is concerned. Nearly every "I typed `/hs` and nothing
happened" is this and not a bug. Each addon announces itself in chat as it loads;
no line means the folder was never indexed, and a full restart fixes it.

## Server support

**NorgQuest**, **NorgNav** and **NorgHearth** are thin clients. Pathing,
quest-objective resolution, transport routing and the stored hearthstone binds all
happen server-side in a companion module, and the addon talks to it over the addon
message channel. Without that module they will load and do nothing useful.

NorgHearth in particular is not a teleport and cannot invent a bind: saving only
copies the bind the server already holds for you, so a bind still has to be made
at an innkeeper first.

**NorgAHValue** prices against a specific auction-house bot's buying rules. The
numbers in `DataSell.lua` / `DataVendor.lua` are generated from a server's item
table; on a different server they will be wrong.

**NorgDungeons** and **NorgRoutes** need no module — they are ordinary client
addons, each with its own window and slash command, and NorgDungeons ships its map
artwork so Atlas is not required. But their `Data.lua` is generated from the Norg
server's encounter table and creature spawns, so on a different server the boss
order and the bearings describe the wrong world.

**NorgMail** and **NorgOneBag** are pure client and work anywhere.

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
- a new addon **folder** is invisible until the client is restarted; `/reload` only
  re-runs folders that were already indexed at launch
