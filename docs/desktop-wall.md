# Desktop wall

One page and one listener for every VNC desktop on a box, with a registry that says who owns each one.

- Status: current, first deployed 2026-09-02.
- Components: `bin/fm-desktop.sh` (registry), `bin/fm-desktop-wall.py` plus `bin/fm-desktop-wall.html` (listener, snapshot loop, wall page).
- Authoritative copy: this file in `undeemed/firstmate`.
- Exact flags, defaults and data mechanics live in each file's header and `--help`; this document owns the design and the operating story.

## Who this is for, and what they ask

| Reader | Question this answers |
|---|---|
| The captain, watching the fleet | One URL that shows every desktop at a glance, and one tap to drive any of them. |
| An operator adding or removing a desktop | Where the display and its owner are recorded, and what is safe to stop. |
| A maintainer changing it | Why it is a snapshot wall and one listener, and where it stops scaling. |

## Context view

A box runs one X display per agent home, each with a localhost-only RFB port.
Before this, each display also had its own `websockify` process on its own tailnet port, each holding its own copy of the TLS material, with the display-to-owner mapping written down nowhere.
Ownership had to be recovered by reading process environments, and a display that died was noticed by nobody.

Now there is one registry, one listener, and one page:

```
phone / laptop on the tailnet
        |  https://firstmate-vps.tailc4c9b.ts.net:6090/wall/
        v
  one websockify listener (TLS, tailnet address only)
        |-- /wall/            wall page, snapshots, viewer heartbeat
        |-- /vnc.html?path=websockify?token=<name>   live noVNC, token-routed
        v
  127.0.0.1:59NN  Xtigervnc, one per desktop
        ^
        |  x11grab, only while a viewer is watching
  snapshot loop (same process, bounded worker pool)
```

The per-desktop `websockify` listeners this replaces (tailnet ports 6111-6116) are still running beside the new one, untouched.
They are retired only after the captain confirms the single listener from his own devices; until that confirmation, do not stop them.

## Composition view

**Registry - `bin/fm-desktop.sh`.**
Writes `state/desktops.json`, the single source of truth: name, display, group, owner and status file.
The RFB port is derived as `5900 + display` wherever it is needed, so it cannot drift from the display.
`create` allocates a free display, starts it, and records it; `register` records a display that already exists; `list` shows liveness; `retire` drops a record.
No display number or port is hardcoded anywhere else: the wall enumerates this file, and the listener's token plugin resolves a token to `127.0.0.1:5900+display` by reading it per connection.
The name is the websockify token and the snapshot filename, so it is restricted to `[a-z0-9][a-z0-9-]*`.

`retire` never signals a process, because another home may be working on that desktop.
It prints the `tigervncserver -kill` command for a human to run deliberately.

**Listener and snapshot loop - `bin/fm-desktop-wall.py`.**
One process: a `websockify` proxy whose token plugin reads the registry, serving noVNC's static files, the wall page, the snapshot images, and two small JSON routes.
The lookup happens per connection in the serving child, so a desktop created after startup is routable with no restart and no derived token file.
The capture loop runs in a thread of the parent process and submits work to a bounded pool.

**Wall page - `bin/fm-desktop-wall.html`.**
Groups tiles by home group, paginates, searches, filters, and reports which tiles are on screen.
Per-tile and page-level toggles switch tiles to live RFB in place; the tile link opens a full interactive session.
Tiles embedded in the wall are view-only; the full-page link is not.

## Information view

`state/desktops.json`:

```json
{"desktops": [{"name": "seer", "display": 14,
               "group": "secondmates", "owner": "seer-mate-e3",
               "status_file": "/home/ubuntu/Dev/firstmate/state/seer-mate-e3.status"}]}
```

`state/desktop-wall/` holds the generated material: `<name>.webp` (latest snapshot), `<name>.json` (capture time, change time, content digest, error), and `viewers/<name>` (one file per watched desktop, mtime = last heartbeat, contents = the interval that viewer asked for).

## Interaction view: why viewer heartbeats are files

`websockify` serves every connection from a separate child process, so a request handler cannot write to the parent's memory.
The heartbeat therefore crosses that boundary through the filesystem: the child writes `viewers/<name>`, and the capture loop in the parent reads its mtime.
A restart loses no viewer state, and a viewer that goes away expires by itself after 15 seconds (`VIEWER_TTL_SECONDS`).

The interval floor is applied on the server, in the same place, so a client cannot ask the box for a 100 ms capture loop.

## Resource view: what it costs and where it stops

Measured on this 8-core VPS on 2026-09-02, 1600x900 desktops, 480 px webp tiles.

| Quantity | Measured |
|---|---|
| CPU per capture, `ffmpeg` side | 0.132 CPU-s (20 captures, idle desktop) |
| CPU per capture, `Xtigervnc` side | 0.036 CPU-s |
| CPU per watched desktop at 5 s | 0.034 core, about 3.4% of one core |
| Nine tiles on screen at 5 s | 0.30 core, 3.8% of the box |
| Snapshot size | 6.9 KB average per tile, about 62 KB per full refresh of nine |
| Wall page load event | 104 ms |
| All nine tiles painted | 180 ms after navigation start |
| `/wall/api/view` round trip | 50 ms |
| Live click-through, protocol level | 0.09 s to the RFB banner through the single listener |
| Live click-through, in the browser | 1.41 s to a painted 1600x900 framebuffer |
| Idle desktop footprint | 180 MiB PSS (Xtigervnc plus a 22-process XFCE session) |

Cost is driven by tiles on screen, not by desktops registered.
A registered desktop nobody is watching costs one row in the registry and zero CPU, which is what makes hundreds of registrations cheap.

Saturation, in order of what binds first on one box:

1. **Memory, at roughly 120 desktops.** 180 MiB per idle session against 22 GiB of RAM. This is the real ceiling, and it is reached long before snapshot CPU matters.
2. **Snapshot CPU, at roughly 30 concurrently watched tiles per core at 5 s** (5 s / 0.168 CPU-s). A 2-core budget carries about 60 watched tiles at 5 s, or about 357 at 30 s.
3. **The listener itself,** one child process per live RFB session, which is the same shape as the seven listeners it replaced.

A page only ever watches the tiles it shows, so a 12-tile page costs 0.40 core regardless of whether the registry holds 9 rows or 900.
Past one box, the next step is sharding by box: each box runs its own registry and listener, and the wall federates by adding a host field to the registry row and pointing tiles at the owning box.
Nothing in the page or the capture loop assumes one host; only the registry schema needs the extra field.

## Security view

The perimeter is the tailnet, exactly as before: the listener binds the tailnet address only, serves TLS from `~/.vnc/tls`, and refuses plain HTTP.
`ufw` allows traffic on `tailscale0` only.

The desktops themselves run `-SecurityTypes None` on a localhost-only RFB port, which is how every desktop on this box was already configured.
`state/secrets/vnc-password` exists but is not in that path, so no password is read, printed, or placed in a URL by this design.
Adding VNC authentication would be a change to every desktop, not to the wall, and it is not part of this design.

## Rationale and rejected alternatives

- **Snapshot wall with click-through, not a live-tile wall.** Nine concurrent RFB streams reconnect on every page load and are expensive on a phone. Snapshots are 6.9 KB per tile and the full page paints in 180 ms. Live is still one tap away, per tile or for the whole page.
- **One token-routed listener, not one per desktop.** Seven listeners meant seven ports to remember, seven copies of the TLS configuration, and a hand-picked port for every new desktop. Token routing derives the whole map from the registry.
- **Snapshot loop inside the listener process, not a second service.** The capture loop needs the registry and the viewer files, both of which are on disk. A second unit would add supervision surface without removing a dependency.
- **Registry as JSON in `state/`, not as a systemd unit or an environment file.** It is read by the page, the token map and the operator, and it is the file that ends the "who owns :14" question.
- **Filesystem heartbeats, not shared memory.** `websockify` forks per connection; the filesystem is the only channel both sides already have, and it survives a restart.

## Operating it

```
bin/fm-desktop.sh list                 # every desktop and whether it is running
bin/fm-desktop.sh create <name> --group <g> --owner <id> --status-file <path>
bin/fm-desktop.sh register <name> --display <N> ...   # record an existing display
bin/fm-desktop.sh retire <name>        # record only; never stops a display
```

The listener runs as the user unit `fm-desktop-wall.service`.
It takes `--registry`, `--snapshot-dir`, `--listen`, `--port`, `--cert`, `--key` and `--web-root`; run it with `--help` for current defaults.
The refresh interval is the page's own control, defaulting to 5 s and carried by `?interval=`, and the server floors whatever it is asked for at `MIN_INTERVAL_SECONDS` (2 s).

Give the captain the MagicDNS form of the URL, never a loopback address and never the public IP:
`https://firstmate-vps.tailc4c9b.ts.net:6090/wall/`.
The box itself does not resolve MagicDNS, so verification from the box uses the tailnet IP.

## Maintaining this file

Keep this file to the design and the operating story.
Exact flags and defaults belong in each script's header and `--help`.
When a measured number changes, replace it here with the new measurement and say when it was taken, rather than adding a second number beside it.
