# YouTube App (Firefox + uBlock Origin)

Installs **YouTube** as its own app on Windows, Linux or macOS. It runs in
Firefox with **uBlock Origin**, but looks like an app rather than a browser:

- its own Start-menu / app-menu entry, icon and window
- no tabs, address bar or bookmarks (move the mouse to the very top edge of the
  window to show the toolbar for back/reload or the uBlock Origin button)
- YouTube's **app layout**, not the desktop website
- a separate Firefox profile, so your normal Firefox is left untouched

## Layouts

| Layout | What you get | Install flag |
|---|---|---|
| `mobile` (default) | The phone app's layout (`m.youtube.com`): bottom tabs for Home, Shorts, Subscriptions, You. Opens as a tall, phone-sized window; resize or maximize it as you like. | none |
| `tv` | The TV app's layout (`youtube.com/tv`), fullscreen, works with keyboard arrows or a controller. Close with Alt+F4 (⌘Q on Mac). | `--layout tv` / `-Layout tv` |

To switch layouts, run the installer again with the other flag.

## Install

First install [Firefox](https://www.mozilla.org/firefox/). Then download this
folder.

**Windows:** double-click `install-windows.bat`.
For the TV layout, run in PowerShell: `.\install.ps1 -Layout tv`

**Linux / macOS:** in a terminal in this folder:

```sh
./install.sh              # mobile-app layout
./install.sh --layout tv  # TV-app layout
```

Then open **YouTube** from the Start menu, the desktop, your app menu, or
`~/Applications` on a Mac. Sign in to YouTube once; it stays signed in.

Snap and Flatpak Firefox on Linux are supported; the profile is put in a folder
those sandboxes are allowed to use.

## Uninstall

Windows: `uninstall-windows.bat`. Linux / macOS: `./uninstall.sh`.
This deletes the app's profile too (sign-in, settings, history).

## How it works

The installer creates a Firefox profile and puts these in it:

- `extensions/uBlock0@raymondhill.net.xpi`: the latest uBlock Origin from
  addons.mozilla.org. It updates itself like any add-on.
- `user.js`: switches on the profile's stylesheets and the bundled add-on, sets
  the user agent that makes YouTube serve its mobile or TV app layout, opens
  links in the same window, uses a dark theme, and turns off first-run pages
  and telemetry.
- `chrome/userChrome.css`: hides Firefox's toolbars.
- `chrome/userContent.css`: hides YouTube's "open the app" banners.
- `xulstore.json`: the starting window size (only written on first install).

Then it adds a shortcut that starts Firefox with `--profile <that folder>`.
