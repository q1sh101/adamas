# Adamas

🧱 Deny-by-default hardening for Flatpak apps.

Zero by default. Allowed only by name.

## tl;dr + quickstart

```bash
# pick a config in apps/*.conf
# install -> harden -> run

bash adamas.sh install firefox
bash adamas.sh harden firefox
bash adamas.sh run firefox
bash adamas.sh verify firefox
```

```text
commands:
  bash adamas.sh run      <app>                  launch with stateless sandbox
  bash adamas.sh install  <app>                  install from flathub
  bash adamas.sh harden   <app>                  patch .desktop route or install hook
  bash adamas.sh verify   <app>                  audit route / hook integrity
  bash adamas.sh auto                            scan installed apps, generate config if missing, patch route
  bash adamas.sh watch    install|remove|status   manage systemd automation
  bash adamas.sh trace    <app-id> [--runtime] [--save]
  bash adamas.sh list                            show available configs
```

## model

The deny-by-default pipeline. Everything starts locked. Nothing gets through
unless the config names it.

```text
  ┌────────────────┐       ┌────────────────┐       ┌────────────────┐       ┌────────────────┐
  │    MANIFEST    │       │      ZERO      │       │   ALLOW-LIST   │       │     SEALED     │
  │                │       │                │       │                │       │                │
  │  finish-args:  │─strip─│  --sandbox:    │─allow─│  apps/*.conf:  │─lock──│  runtime:      │
  │  all defaults  │──────▶│  nothing       │──────▶│  ALLOW_*       │──────▶│  minimal       │
  │  from upstream │       │  remains       │       │  only          │       │  surface       │
  │                │       │                │       │                │       │                │
  └────────────────┘       └────────────────┘       └────────────────┘       └────────────────┘
        100%                      0%                    you decide                 locked
```

```text
  ┌───────────────────────────────────────────────────────────────────────────────────────┐
  │                           DENY-BY-DEFAULT PIPELINE                                    │
  ├───────────────────────────────────────────────────────────────────────────────────────┤
  │                                                                                       │
  │   Flatpak manifest         flatpak run          apps/firefox.conf       env -i        │
  │   ┌────────────────┐       ┌──────────────┐     ┌──────────────┐       ┌──────────┐   │
  │   │ shared=network │       │              │     │ ALLOW_SHARE  │       │ HOME     │   │
  │   │ sockets=x11    │       │   --sandbox  │     │ ALLOW_SOCKET │       │ PATH     │   │
  │   │ sockets=wayland│──────▶│              │────▶│ ALLOW_DEVICE │──────▶│ XDG_RT   │   │
  │   │ devices=all    │ strip │   = nothing  │ add │ ALLOW_FS     │       │ DBUS_ADDR│   │
  │   │ filesystems=~  │  all  │              │back │ ALLOW_DBUS   │       │ WAYLAND  │   │
  │   │ talk-name=*    │       │              │only │ PERSIST      │       │ DISPLAY  │   │
  │   │                │       │              │     │              │       │ LANG     │   │
  │   │                │       │              │     │              │       │ (only)   │   │
  │   └────────────────┘       └──────────────┘     └──────────────┘       └──────────┘   │
  │         many                    zero              named only             sanitized    │
  │                                                                                       │
  └───────────────────────────────────────────────────────────────────────────────────────┘
```

## enforcement

What happens inside `adamas run <app>`:

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                         adamas run <app>                          │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   ┌───────────────────────────────────────────────────────────┐   │
  │   │  1. flatpak permission-reset $APP_ID                      │   │
  │   │     wipe all portal grants (skipped if sibling alive)     │   │
  │   └────────────────────────────┬──────────────────────────────┘   │
  │                                │                                  │
  │                                ▼                                  │
  │   ┌───────────────────────────────────────────────────────────┐   │
  │   │  2. deny 8 sensitive portals                              │   │
  │   │     camera | microphone | speakers | location             │   │
  │   │     notifications | screenshot | screencast | background  │   │
  │   └────────────────────────────┬──────────────────────────────┘   │
  │                                │                                  │
  │                                ▼                                  │
  │   ┌───────────────────────────────────────────────────────────┐   │
  │   │  3. .conf --> flags                                       │   │
  │   │     ALLOW_* arrays compile to --share= --socket= etc.     │   │
  │   │     ALLOW_PORTAL entries get permission-set yes           │   │
  │   └────────────────────────────┬──────────────────────────────┘   │
  │                                │                                  │
  │                                ▼                                  │
  │   ┌───────────────────────────────────────────────────────────┐   │
  │   │  4. --dbus-call= per-call D-Bus filtering                 │   │
  │   │     granular method-level allow on session bus            │   │
  │   └────────────────────────────┬──────────────────────────────┘   │
  │                                │                                  │
  │                                ▼                                  │
  │   ┌───────────────────────────────────────────────────────────┐   │
  │   │  5. env -i   zero host environment                        │   │
  │   │     only baseline vars + ALLOW_ENV pass through           │   │
  │   └────────────────────────────┬──────────────────────────────┘   │
  │                                │                                  │
  │                                ▼                                  │
  │   ┌───────────────────────────────────────────────────────────┐   │
  │   │  env -i flatpak run --sandbox ... $APP_ID                 │   │
  │   └───────────────────────────────────────────────────────────┘   │
  │                                                                   │
  │   on exit: permission-reset $APP_ID (only if last instance)       │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```

```text
  default portal deny-set (always denied unless ALLOW_PORTAL overrides):

  ┌──────────────┬──────────────┬──────────────┬──────────────┐
  │   camera     │  microphone  │   speakers   │   location   │
  ├──────────────┼──────────────┼──────────────┼──────────────┤
  │ notification │  screenshot  │  screencast  │  background  │
  └──────────────┴──────────────┴──────────────┴──────────────┘
```

## route

How app launches get intercepted so they always go through adamas:

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                        Launch Routing                             │
  ├──────────────────────────────┬────────────────────────────────────┤
  │     Flatpak App              │     Webapp / External Launcher     │
  │                              │                                    │
  │   ┌────────────────────┐     │     ┌────────────────────┐         │
  │   │  exported .desktop │     │     │  launcher binary   │         │
  │   └─────────┬──────────┘     │     └─────────┬──────────┘         │
  │             │                │               │                    │
  │             │ adamas harden  │               │ adamas harden      │
  │             ▼                │               ▼                    │
  │   ┌────────────────────┐     │     ┌──────────────────────────┐   │
  │   │  ~/.local/share/   │     │     │  ~/.config/hifox/hooks/  │   │
  │   │  applications/     │     │     │  webapp/<name>           │   │
  │   │  ${APP_ID}.desktop │     │     │  (executable hook)       │   │
  │   └─────────┬──────────┘     │     └─────────┬────────────────┘   │
  │             │                │               │                    │
  │             └────────────────┼───────────────┘                    │
  │                              │                                    │
  │                              ▼                                    │
  │                ┌──────────────────────────┐                       │
  │                │  adamas.sh run <conf>    │                       │
  │                │  stateless sandbox       │                       │
  │                └──────────────────────────┘                       │
  └───────────────────────────────────────────────────────────────────┘
```

## trace

Generate a draft config from manifest metadata or runtime observation:

```bash
# static draft from manifest metadata
bash adamas.sh trace org.mozilla.firefox

# save draft into apps/*.conf
bash adamas.sh trace org.mozilla.firefox --save

# runtime draft: watch portal calls while app runs
bash adamas.sh trace org.mozilla.firefox --runtime
bash adamas.sh trace org.mozilla.firefox --runtime --save
```

```text
  ┌───────────────────────────────────────────────────────────────┐
  │                          Trace Modes                          │
  ├──────────────────────────────┬────────────────────────────────┤
  │          STATIC              │          RUNTIME               │
  │                              │                                │
  │   ┌────────────────────┐     │     ┌────────────────────┐     │
  │   │  flatpak info      │     │     │  parse metadata    │     │
  │   │  --show-metadata   │     │     │  (static base)     │     │
  │   └─────────┬──────────┘     │     └─────────┬──────────┘     │
  │             │                │               │                │
  │             ▼                │               ▼                │
  │   ┌────────────────────┐     │     ┌────────────────────┐     │
  │   │  parse sections:   │     │     │  start dbus-monitor│     │
  │   │    [Context]       │     │     │  (background)      │     │
  │   │  [Session Bus Pol.]│     │     └─────────┬──────────┘     │
  │   │  [System Bus Pol.] │     │               │                │
  │   └─────────┬──────────┘     │               ▼                │
  │             │                │     ┌────────────────────┐     │
  │             │                │     │  launch app (full  │     │
  │             │                │     │  manifest perms)   │     │
  │             │                │     └─────────┬──────────┘     │
  │             │                │               │                │
  │             │                │               ▼                │
  │             │                │     ┌────────────────────┐     │
  │             │                │     │  user interacts    │     │
  │             │                │     │  app closes        │     │
  │             │                │     └─────────┬──────────┘     │
  │             │                │               │                │
  │             │                │               ▼                │
  │             │                │     ┌────────────────────┐     │
  │             │                │     │  parse dbus log    │     │
  │             │                │     │  resolve sender    │     │
  │             │                │     │  infer:            │     │
  │             │                │     │   ALLOW_DBUS_CALL  │     │
  │             │                │     │   ALLOW_PORTAL     │     │
  │             │                │     └─────────┬──────────┘     │
  │             │                │               │                │
  │             ▼                │               ▼                │
  │             └────────────────┼───────────────┘                │
  │                              │                                │
  │                              ▼                                │
  │               ┌──────────────────────────────┐                │
  │               │  draft .conf                 │                │
  │               │  (stdout or --save to apps/) │                │
  │               └──────────────────────────────┘                │
  └───────────────────────────────────────────────────────────────┘
```

```text
  trace notes:
  ┌───────────────────────────────────────────────────────────────┐
  │   - output is a draft -- review before using                  │
  │   - runtime mode is mainly for portal / D-Bus call discovery  │
  │   - env needs are not inferred (add ALLOW_ENV manually)       │
  │   - if sender resolution fails, output may include            │
  │     unrelated D-Bus traffic from other apps                   │
  └───────────────────────────────────────────────────────────────┘
```

## memory

How persistence works -- RAM by default, disk only if you name it:

```text
  ┌───────────────────────────────────────────────────────────────┐
  │                       Memory Model                            │
  ├───────────────────────────────────────────────────────────────┤
  │                                                               │
  │    ┌─────────────────┐                                        │
  │    │    app starts   │                                        │
  │    └────────┬────────┘                                        │
  │             │                                                 │
  │             ▼                                                 │
  │    ┌────────────────────────────────────────────┐             │
  │    │                   RAM                      │             │
  │    │  default: everything lives here            │             │
  │    │  exit = state dies                         │             │
  │    └────────┬───────────────────────────────────┘             │
  │             │                                                 │
  │             │  what does PERSIST=() control?                  │
  │             │                                                 │
  │             ├── PERSIST=()                                    │
  │             │   RAM only -- nothing survives exit             │
  │             │                                                 │
  │             ├── PERSIST=(.)                                   │
  │             │   full app home to disk                         │
  │             │                                                 │
  │             ├── PERSIST=(.mozilla .config/app)                │
  │             │   named paths only to disk                      │
  │             │                                                 │
  │             ▼                                                 │
  │    ┌────────────────────────────────────────────┐             │
  │    │                  DISK                      │             │
  │    │  only what you name                        │             │
  │    └────────────────────────────────────────────┘             │
  │                                                               │
  └───────────────────────────────────────────────────────────────┘
```

## automation

Systemd-driven auto-hardening for new installs:

```text
  ┌────────────────────────────────────────────────────────────────┐
  │                       Automation Pipeline                      │
  ├────────────────────────────────────────────────────────────────┤
  │                                                                │
  │     ┌───────────────────┐                                      │
  │     │  systemd .path    │─── dir changed? ──┐                  │
  │     │  (inotify watch)  │                   │                  │
  │     └───────────────────┘                   │                  │
  │                                             ▼                  │
  │                                  ┌──────────────────────┐      │
  │                                  │    adamas auto       │      │
  │     ┌───────────────────┐        │                      │      │
  │     │  systemd .timer   │───────▶│  scan installed apps │      │
  │     │  (every 30 min)   │        │  generate configs    │      │
  │     └───────────────────┘        │  if missing          │      │
  │                                  └──────────┬───────────┘      │
  │                                             │                  │
  │                                             ▼                  │
  │                                  ┌──────────────────────┐      │
  │                                  │    adamas harden     │      │
  │                                  │  patch .desktop/hook │      │
  │                                  └──────────────────────┘      │
  │                                                                │
  └────────────────────────────────────────────────────────────────┘
```

## config

```text
  start:     apps/example.conf     (template -- copy and edit APP_ID)
  real:      apps/firefox.conf     (working config for Firefox)
```

```sh
APP_ID="org.mozilla.firefox"

ALLOW_SHARE=(network)
ALLOW_SOCKET=(wayland pulseaudio)
ALLOW_DEVICE=(dri)
ALLOW_FILESYSTEM=(xdg-download)

PERSIST=(.mozilla .config/mozilla .cache/mozilla .local/share/mozilla)

SET_ENV=(GTK_THEME=Adwaita:dark)
ALLOW_ENV=(DESKTOP_STARTUP_ID XDG_ACTIVATION_TOKEN MOZ_APP_REMOTINGNAME)

# requires patched flatpak fork for --dbus-call -- remove if using vanilla
ALLOW_DBUS_CALL=(
  "org.freedesktop.portal.Desktop=org.freedesktop.portal.Inhibit.*"
)
```

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                       Config Groups                               │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   sandbox surface         ALLOW_SHARE / SOCKET / DEVICE / FEATURE │
  │                           ALLOW_FILESYSTEM                        │
  │                                                                   │
  │   D-Bus policy            ALLOW_DBUS_TALK / ALLOW_DBUS_OWN        │
  │                           ALLOW_SYSTEM_DBUS_TALK / _OWN           │
  │                           ALLOW_A11Y_OWN                          │
  │                                                                   │
  │   D-Bus call filtering    ALLOW_DBUS_CALL                         │
  │                                                                   │
  │   portals                 ALLOW_PORTAL / DENY_PORTAL              │
  │                                                                   │
  │   persistence             PERSIST                                 │
  │                                                                   │
  │   environment             SET_ENV / ALLOW_ENV                     │
  │                                                                   │
  │   extras                  ADD_POLICY / ALLOW_USB / HOOK_NAME      │
  │                           APP_ARGS                                │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```

```text
  config files must:
  ┌───────────────────────────────────────────────────────────────────┐
  │     - not be a symlink                                            │
  │     - be owned by the current user                                │
  │     - not be group/world-writable                                 │
  └───────────────────────────────────────────────────────────────────┘
```

## structure

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                        Project Layout                             │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   adamas/                                                         │
  │   ├── adamas.sh                 entry point + dispatch            │
  │   ├── lib/                                                        │
  │   │   ├── common.sh             logging, validation, paths        │
  │   │   ├── run.sh                stateless sandbox launcher        │
  │   │   ├── install.sh            flatpak install                   │
  │   │   ├── harden.sh             .desktop patch or launcher hook   │
  │   │   ├── verify.sh             route / hook integrity check      │
  │   │   ├── auto.sh               auto-harden all apps              │
  │   │   ├── watch.sh              systemd path + timer              │
  │   │   └── trace.sh              draft config generation           │
  │   └── apps/                                                       │
  │       ├── example.conf          template                          │
  │       └── firefox.conf          per-app config                    │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```

## requires

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                        Requirements                               │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   flatpak >= 1.14.10                                              │
  │   flatpak 1.15 requires >= 1.15.10                                │
  │   flatpak 1.16+ recommended                                       │
  │                                                                   │
  │   ALLOW_DBUS_CALL requires patched flatpak (--dbus-call support): │
  │     repo:   https://github.com/q1sh101/flatpak                    │
  │     branch: add-dbus-call-option                                  │
  │     configs that use it will fail on vanilla flatpak              │
  │     without it, everything else works                             │
  │                                                                   │
  │   trace --runtime requires: gdbus, dbus-monitor                   │
  │   watch requires: systemd --user                                  │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```
