# adamas

![Linux](https://img.shields.io/badge/Linux-FFA500?logo=linux&logoColor=black&labelColor=FFA500) ![Flatpak](https://img.shields.io/badge/Flatpak-4A90D9?logo=flatpak&logoColor=white) ![Shell](https://img.shields.io/badge/Shell-2ea44f?logo=gnu-bash&logoColor=white)

Deny-by-default sandboxing for Flatpak apps.

The manifest asks for everything. The config decides what it gets.


## quickstart

```bash
git clone https://github.com/q1sh101/adamas && cd adamas

# copy the template, set APP_ID, name what the app needs
cp apps/example.conf apps/myapp.conf

bash adamas.sh install myapp   # install from Flathub
bash adamas.sh harden myapp    # route launches through adamas
bash adamas.sh run myapp       # launch in the stateless sandbox
bash adamas.sh verify myapp    # audit the route
```

> **A fresh config grants nothing.** `--sandbox` drops every permission the manifest asked for, so an app without `ALLOW_SOCKET=(wayland)` will not even open a window. Add permissions until it works, not the other way around.

> **Portals need a bus.** `--sandbox` also turns the session bus proxy off, so the file chooser, screencast and inhibit are unreachable until `NEED_PORTAL=true`. `ALLOW_PORTAL` then decides which of them the portal grants.

> **`ALLOW_SOCKET=(session-bus)` is rejected.** An unfiltered bus lets the app call `org.freedesktop.Flatpak` and run commands on the host - that is a sandbox escape, not a portal mode.

> **One `APP_ID`, one portal policy.** Several configs may point at the same app (separate browser profiles, for example). Flatpak keys portal permissions by application id, so "camera for this webapp only" cannot be expressed. adamas refuses to start a config whose portal policy differs from a running instance of the same app id, instead of silently widening the grant - see below.

## what it does

- Strips a Flatpak app to zero with `--sandbox`, then adds back only what the config names.
- Sanitizes the environment with `env -i`: baseline variables plus `ALLOW_ENV`, nothing else.
- Resets the portal permission store on every launch and denies 8 sensitive portals by default.
- Routes launches through adamas by patching the `.desktop` or installing a launcher hook, and reports drift when that route changes.
- Keeps app state in RAM unless `PERSIST` names a path.

## commands

```text
bash adamas.sh run     <app> [args...]                launch with stateless sandbox
bash adamas.sh install <app>                          install from Flathub
bash adamas.sh harden  <app>                          patch .desktop route or install hook
bash adamas.sh verify  <app>                          audit route / hook integrity
bash adamas.sh auto                                   scan installed apps, generate missing configs, harden
bash adamas.sh watch   install|remove|status          manage systemd automation
bash adamas.sh trace   <app-id> [--runtime] [--save]  observe app needs, generate draft config
bash adamas.sh list                                   show available configs
```

## files

```text
apps/example.conf                             template - copy and edit APP_ID
apps/<name>.conf                              per-app allow-list
apps/webapps/<name>.conf                      optional grouping, one level deep
lib/                                          command implementations
```

Key config fields:

```text
APP_ID                                        reverse-DNS Flatpak id (required)
ALLOW_SHARE / SOCKET / DEVICE / FEATURE       sandbox surface
ALLOW_FILESYSTEM                              paths the app may see
ALLOW_DBUS_TALK / ALLOW_DBUS_OWN              session bus names
NEED_PORTAL                                   run the session bus proxy
ALLOW_PORTAL / DENY_PORTAL                    portal permission store entries
ALLOW_DBUS_CALL                               method-level filtering (patched flatpak)
PERSIST                                       paths that survive exit
SET_ENV / ALLOW_ENV                           environment
HOOK_NAME + HOOK_DIR                          route through an external launcher
AUTO_SKIP                                     leave this app's launch route alone
```

## portal least-privilege

Flatpak keys portal permissions by application id, not by sandbox, so one
profile's grant is every profile's grant and "camera for this webapp only" has
nowhere to live. adamas is built around that gap: it fails closed rather than
widen a shared grant. I proposed `--dbus-call`
([flatpak#6526](https://github.com/flatpak/flatpak/pull/6526)) to move the
decision into the sandbox; upstream preferred a portal-side entitlement model
([xdg-desktop-portal#1924](https://github.com/flatpak/xdg-desktop-portal/pull/1924),
open), so it lives on as a [fork](https://github.com/q1sh101/flatpak) on branch
`add-dbus-call-option`. The commented blocks in `apps/` switch the same configs
to per-sandbox default-deny when that fork is installed.

## reference

- [ARCHITECTURE.md](docs/ARCHITECTURE.md) - full system map.
- [MIT License](LICENSE)
