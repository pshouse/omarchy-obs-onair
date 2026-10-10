# OBS On Air

<p align="center">
<img src="preview.png" alt="OBS On Air bar widget" width="600">
</p>

An [Omarchy](https://omarchy.org) bar widget that shows a red **ON AIR** pill while
OBS is streaming, so you always know when you're live.

- **ON AIR** (red, pulsing dot): OBS is streaming.
- **BRB** (amber): OBS is streaming on one of your "be right back" scenes.
- **RECONNECTING** (amber, blinking): OBS has lost its connection to the server and is retrying.
- **Hidden:** OBS isn't running or isn't streaming. The widget takes no space.

The pill shows elapsed stream time and, optionally, your combined YouTube + Twitch
viewer count. Hover for details: scene, elapsed time, bitrate, dropped frames, and
viewers per platform.

The widget is display-only: clicking it does nothing, so it can never stop your
stream by accident.

Plugin id: `io.github.pshouse.obs-onair`

> Looking for meeting detection with smart lights? That's
> [joegeary/omarchy-on-air](https://github.com/joegeary/omarchy-on-air), a different
> plugin. This one only watches OBS.

## Requirements

- [OBS Studio](https://obsproject.com) with its built-in WebSocket server enabled
  (OBS → Tools → WebSocket Server Settings → Enable WebSocket server).
- [`obs-cmd`](https://github.com/grigio/obs-cmd) (AUR): `omarchy pkg aur add obs-cmd`
- `jq` and `curl` (already on Omarchy).

The widget reads the WebSocket port and password from OBS's own config
(`~/.config/obs-studio/plugin_config/obs-websocket/config.json`, or the Flatpak
equivalent), so there's nothing to configure for local OBS. It only reads state from
OBS and never changes it.

## Install

```bash
omarchy plugin add https://github.com/pshouse/omarchy-obs-onair --enable
```

The widget is placed in the center section. To put it just left of the clock:

```bash
omarchy bar move io.github.pshouse.obs-onair --before omarchy.clock
```

## Viewer counts (optional)

Live viewer counts come from the YouTube Data API and the Twitch Helix API. You need
your own credentials. Skip this section if you don't want counts. Without
credentials, the widget shows only the label and timer.

```bash
mkdir -p ~/.config/obs-onair
cp ~/.config/omarchy/plugins/io.github.pshouse.obs-onair/credentials.env.example \
   ~/.config/obs-onair/credentials.env
chmod 600 ~/.config/obs-onair/credentials.env
```

Then fill in the file:

**YouTube**
1. In [Google Cloud Console](https://console.cloud.google.com), create a project and
   enable **YouTube Data API v3**.
2. Go to Credentials → Create credentials → API key. Restrict it to YouTube Data API v3.
3. Your channel ID (starts with `UC`) is in YouTube Studio → Settings → Channel →
   Advanced settings.

**Twitch**
1. At [dev.twitch.tv/console](https://dev.twitch.tv/console), click Register Application.
   Use redirect URL `http://localhost` and category "Other".
2. Copy the Client ID, then click New Secret.
3. Set `TWITCH_LOGIN` to your Twitch username.

Test it while you're live:

```bash
~/.config/omarchy/plugins/io.github.pshouse.obs-onair/bin/obs-onair-viewers
```

Notes:
- **YouTube quota:** the live video is looked up once per stream (100 quota units,
  retried at most every 2 minutes until YouTube lists it), then each count costs 1
  unit. At the default 60-second refresh, a full day of streaming uses about 1,500
  of the free 10,000 daily units.
- YouTube can take a minute or two after you go live to list the stream. A live
  stream with no viewers shows 0.
- Other platforms (X, Kick, etc.) aren't supported.
- The credentials file is read as plain `KEY=value` lines and is never executed. The
  Twitch app token is cached in `$XDG_RUNTIME_DIR/obs-onair/` (owner-only).

## Settings

Set these in Setup → Bar, or with `omarchy bar set io.github.pshouse.obs-onair <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `brbScenes` | `Be right back, BRB` | Comma-separated scene names that show BRB instead of ON AIR |
| `showViewers` | `true` | Show viewer counts (needs credentials) |
| `viewerIntervalSec` | `60` | How often to refresh viewer counts (30–600) |
| `credentialsFile` | `~/.config/obs-onair/credentials.env` | Where your API credentials live |

## How it works

- `bin/obs-onair-status` asks OBS for its streaming status and current scene with
  `obs-cmd`, and prints one JSON line. The widget runs it every 2 seconds. When OBS
  isn't running, it exits immediately without contacting anything.
- `bin/obs-onair-viewers` calls the YouTube and Twitch APIs and prints one JSON line.
  It runs only while you're live.
- `ObsOnAir.qml` draws the pill and tooltip. Bitrate is calculated from the change in
  bytes sent between polls.

No sudo, no background services, and nothing runs at install time.

## Removal

```bash
omarchy plugin remove io.github.pshouse.obs-onair
rm -rf ~/.config/obs-onair   # if you set up viewer counts
```

## License

[MIT](LICENSE)
