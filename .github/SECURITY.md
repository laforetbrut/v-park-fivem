# Security policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting: the **Security** tab on this repository, then
**Report a vulnerability**. That opens a private advisory only the maintainer can see.

Include what you would put in a bug report - framework, database driver, the output of
`/vparkinfo` - plus the steps to reproduce. A proof of concept is welcome and is never required.

Expect an acknowledgement within a few days. A fix for anything that lets a player affect
another player's vehicles is a patch release, not a scheduled one.

---

## What this resource trusts, and what it does not

Worth stating precisely, because a bug report that starts "a client can send X" is only a
vulnerability if X is something we act on.

### The client is not trusted

Every net event from a client is re-validated on the server against the server's own config and
its own view of who that player is. Specifically:

- **`vpark:server:candidate`** carries a described vehicle. The server re-runs every rule -
  class, model, plate, health, zone, mode - and re-resolves ownership from the framework rather
  than from the payload. A client can describe a vehicle it is standing next to; it cannot
  describe one it is not, because the server resolves the entity from the network id and checks
  it exists.
- **`vpark:server:captured`** carries snapshots. The server only accepts snapshots for ids it
  asked *that client* for, in *that request*, tracked by token. A client cannot volunteer a
  snapshot for an arbitrary vehicle.
- **`vpark:server:restored`** is accepted only from the client the server nominated for that
  vehicle. A late answer from a previously nominated client is dropped rather than acted on.
- **`vpark:server:panelAction`** re-checks the admin permission on every single call, and
  re-checks the `Config.Panel.actions` gate. The panel hiding a button is a convenience; a
  hidden button can be un-hidden and an NUI callback can be sent by anything.
- **Positions** are sanity-checked: a position at the origin is rejected as "coordinates were
  never written" rather than written as a vehicle in the middle of the ocean.

### What a client can still do

A client near a vehicle can lie about that vehicle's **state** - its damage, its fuel, its
modifications - because those can only be read client-side and there is no native that lets the
server verify them. The worst outcome is a vehicle stored in a condition it was not in, which
that player could have produced honestly by driving it.

It cannot create a vehicle, change ownership, delete anything, or affect a vehicle it is not
near.

### The API boundary is real

`Config.Api.allowedResources` is enforced with `GetInvokingResource()`, which the runtime tells
us and the caller cannot spoof. A server running scripts it does not fully trust can set that
list and mean it.

### SQL

The table prefix is the only config value that reaches SQL text. It is validated against
`^[%w_%-%$]+$` and backticked, and `Database.table()` is the only function that produces a table
name. Every value is a parameter; nothing is concatenated into a statement.

The Advanced Parking migration reads `INFORMATION_SCHEMA` and parameterises the table name in
that query. The source table name itself is interpolated into `SELECT * FROM` - it comes from
`Config.Migration.tables`, which is a config file an operator controls, not from anything a
player can influence.

### NUI

Every value rendered in the admin panel goes through `textContent`. Nothing is inserted as HTML,
because a vehicle label or a plate contains whatever a player typed into it, and the page has
NUI callbacks attached.

### Webhooks

Webhook URLs are read from convars by default rather than from `config.lua`. A URL in
`config.lua` ends up in your repository, in your backups, and in the zip you send when you ask
for help. The resource warns once at boot when it finds one there.

A URL that does not look like a Discord webhook is refused rather than posted to.

---

## Destructive commands

Two commands can remove a lot of data, and both are deliberately awkward:

- **`/vparkpurge`** always previews first and requires `confirm` as a second argument.
- **`vparkwipe`** is **console only**, cannot be run in game whatever the permission config
  says, and requires a token that the first invocation generates and prints to that console.
  A copy-and-pasted command from a support thread cannot empty somebody's table.

Everything removed by any path goes to `<prefix>trash` first, for
`Config.Database.trashRetentionDays` days, and `/vparkrestore` rebuilds it exactly.

Every destructive action writes an audit row and, when configured, posts to the staff webhook
with the actor named.

---

## Supported versions

The latest release. Fixes are made against `main` and released; there are no backports.
