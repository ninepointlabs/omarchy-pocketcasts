# Pocket Casts for Omarchy

A Pocket Casts player in the Omarchy bar. Sign in with your Pocket Casts
account, then play your Up Next, in-progress and new episodes, browse your
shows, and keep your listening position in sync with your phone.

Audio plays through `mpv` in the background. There's no browser and no app
window.

> **Unofficial API.** Pocket Casts has no public API. This plugin uses the
> same endpoints as the Pocket Casts web player, so it can break whenever
> Pocket Casts changes them. It isn't affiliated with or endorsed by Pocket
> Casts or Automattic.

## Requirements

- `mpv` (required): `omarchy pkg add mpv`
- `mpv-mpris` (optional, for media keys and `playerctl`): `omarchy pkg add mpv-mpris`
- A Pocket Casts **email and password**. If you sign in with Apple or Google,
  set a password on your Pocket Casts account first.

## Install

```sh
omarchy plugin add https://github.com/ninepointlabs/omarchy-pocketcasts.git --enable
```

The chip appears in the right section of the bar.

To work from a checkout instead:

```sh
git clone https://github.com/ninepointlabs/omarchy-pocketcasts ~/Projects/omarchy-pocketcasts
~/Projects/omarchy-pocketcasts/install.sh          # adds the widget to the right of the bar
~/Projects/omarchy-pocketcasts/install.sh center   # or pick a section
```

Run `install.sh` again after you pull changes. If the panel doesn't pick
them up, run `omarchy restart shell`.

## Uninstall

Stop playback first (the stop button, or **Sign out**, which also closes the
player), since mpv keeps running on its own. Then:

```sh
omarchy plugin remove ninepointlabs.pocketcasts
rm -rf ~/.local/state/omarchy-pocketcasts ~/.cache/omarchy-pocketcasts   # login tokens, playback state, cover cache
```

`mpv` and `mpv-mpris` are ordinary packages; remove them with
`omarchy pkg remove` if nothing else uses them.

## Using it

Click the bar chip to open the panel. The first time, it asks you to sign in.

| Bar action   | Does                    |
| ------------ | ----------------------- |
| Left click   | Open or close the panel |
| Middle click | Play / pause            |
| Right click  | Skip forward            |
| Scroll       | Volume ±5               |

The panel has tabs for Up Next, In Progress, New releases and Podcasts. It
also has a seek bar, skip back and forward, stop, and playback speed (0.8× to 3×).
Stopping unloads the episode and shrinks the bar chip back to its icon.

**Sync:** while an episode plays, the plugin sends your position to Pocket
Casts every 30 seconds, and again when you pause, stop or switch episodes.
A finished episode is marked as played. If autoplay is on, the next Up Next
episode starts after that.

### Keybindings

The service listens for IPC commands under the `pocketcasts` target:

```sh
omarchy-shell ninepointlabs.pocketcasts toggle   # open/close the panel
omarchy-shell pocketcasts playPause
omarchy-shell pocketcasts status                 # JSON: playing, title, show, position, speed
```

For example, in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER ALT, P, Pocket Casts play/pause, exec, omarchy-shell pocketcasts playPause
```

The commands are `playPause`, `next`, `skipBack`, `skipForward`, `stop`,
`volumeUp`, `volumeDown`, `cycleSpeed`, `refresh` and `status`.

## Settings

| Key             | Default  | Meaning                                                   |
| --------------- | -------- | --------------------------------------------------------- |
| `showTitle`     | `true`   | Show a scrolling "Episode · Show" label next to the cover |
| `maxLabelWidth` | `180`    | Maximum label width in px (60–600)                        |
| `defaultTab`    | `upnext` | Tab the panel opens on: `upnext`, `progress`, `new` or `podcasts` |
| `skipBack`      | `10`     | Seconds to skip back                                      |
| `skipForward`   | `30`     | Seconds to skip forward                                   |
| `autoplay`      | `true`   | Play the next Up Next episode when one finishes           |

## Privacy and security

- The password goes to Pocket Casts once, at sign-in, over stdin. It's never
  passed as a command-line argument and never stored.
- Only the access and refresh tokens are kept, in
  `$XDG_STATE_HOME/omarchy-pocketcasts/auth.json` (mode 0600). Signing out
  deletes them.
- The bridge only connects to Pocket Casts hosts: `api.pocketcasts.com` (the
  only one that gets your token), the episode-list CDN, and
  `static.pocketcasts.com` for artwork. Audio streams from each show's own
  host through mpv.

## Development

```sh
python3 -I -B -m unittest discover -s tests -p 'test_*.py'   # bridge, including a real mpv against a fake server
node --test tests/model.test.cjs                             # Model.js and static QML checks
```

## License

MIT
