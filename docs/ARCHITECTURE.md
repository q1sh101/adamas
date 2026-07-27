# adamas architecture

adamas strips a Flatpak app down to nothing and hands back only what a config
names: `flatpak run --sandbox` drops every permission the manifest asked for,
`apps/*.conf` adds a named allow-list back, `env -i` sanitizes the environment,
and the portal permission store is reset on every launch. This document maps the
enforcement pipeline, portal access, launch routing, config model, and
automation. See [README.md](../README.md) for usage.

## table of contents

1. [overview](#overview)
2. [enforcement](#enforcement)
3. [portal access](#portal-access)
4. [route](#route)
5. [config](#config)
6. [memory](#memory)
7. [trace](#trace)
8. [automation](#automation)
9. [structure](#structure)
10. [requirements](#requirements)

## overview

Everything starts locked. Nothing gets through unless the config names it.

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
  │   │     wipe every grant - on every launch, sibling or not    │   │
  │   │     failure is fatal - no launch with unknown grants      │   │
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
  │   │     the union's ALLOW_PORTAL gets permission-set yes      │   │
  │   └────────────────────────────┬──────────────────────────────┘   │
  │                                │                                  │
  │                                ▼                                  │
  │   ┌───────────────────────────────────────────────────────────┐   │
  │   │  4. session bus proxy (NEED_PORTAL / ALLOW_DBUS_CALL)     │   │
  │   │     see: portal access                                    │   │
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
  │   on exit: recompute the union, permission-reset if last out      │
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

Steps 1-3 run under a per-`APP_ID` lock, so a second launch of the same app
waits until the policy is fully written before its own process starts. With a
sibling alive the store is rewritten to the union of both, or the launch is
refused - see [portal access](#portal-access).

## portal access

Three independent layers decide whether an app reaches a portal. Mixing them up
is the most common source of "the config looks right but nothing works".

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                        Portal Access                              │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   layer 1: is the session bus reachable at all?                   │
  │                                                                   │
  │     --sandbox              proxy off - no portal, no D-Bus        │
  │     NEED_PORTAL=true       proxy on  - portals reachable          │
  │     ALLOW_SOCKET=          rejected  - unfiltered bus is an       │
  │       (session-bus)                    escape hatch, not a mode   │
  │                                                                   │
  │   layer 2: which portal calls are allowed through the proxy?      │
  │                                                                   │
  │     default                every portal method (vanilla flatpak)  │
  │     ALLOW_DBUS_CALL=()     named methods only (patched fork)      │
  │                                                                   │
  │   layer 3: does the portal itself grant the request?              │
  │                                                                   │
  │     permission store       DENY_PORTAL / ALLOW_PORTAL             │
  │                            works on vanilla flatpak               │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```

`ALLOW_PORTAL` and `ALLOW_DBUS_CALL` are not alternatives:
`ALLOW_PORTAL=(devices:camera)` writes a grant into the permission store, while
`ALLOW_DBUS_CALL` names which methods may cross the bus at all. Either one needs
a bus first - `NEED_PORTAL=true` opens it, and `ALLOW_DBUS_CALL` implies it.

### one app id, one policy

The permission store is keyed by application id, so layer 3 has no notion of a
profile, an instance or a sandbox: a grant written for one config is live for
every process under that id. `lib/run.sh` therefore keeps one state file per app
id and decides under a `flock`.

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                       One APP_ID, One Policy                      │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   state    $XDG_RUNTIME_DIR/adamas-<APP_ID>.pids                  │
  │            <pid>  <config>  <shared>  <portal signature>          │
  │                                                                   │
  │   launch   flock, prune dead pids, compare signatures             │
  │              same                 join, the union is unchanged    │
  │              differs              die, unless both sides share    │
  │              differs, both share  widen to the union              │
  │                                                                   │
  │   write    reset  ->  DENY the rest  ->  ALLOW the union          │
  │   exit     recompute; permission-reset when the last one goes     │
  │                                                                   │
  │   ┌─────────────────┬────────┬────────────┬───────────────────┐   │
  │   │     instance    │ camera │ screencast │     microphone    │   │
  │   ├─────────────────┼────────┼────────────┼───────────────────┤   │
  │   │ firefox-discord │  yes   │    yes     │         no        │   │
  │   │ firefox-netflix │   no   │     no     │         no        │   │
  │   ├─────────────────┼────────┼────────────┼───────────────────┤   │
  │   │  store, both up │  yes   │    yes     │         no        │   │
  │   │  discord exits  │   no   │     no     │         no        │   │
  │   └─────────────────┴────────┴────────────┴───────────────────┘   │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```

A lone instance gets exactly its own policy - the union of one set is that set.
The zero-byte `.lock` is left behind on purpose: unlinking a lock file releases
waiters onto an inode no longer at that path, so the next launch would create a
fresh one and two processes would hold what they both believe is the same lock.
`$XDG_RUNTIME_DIR` is a tmpfs cleared at logout, which is the cheaper trade.

Failing closed is the default, and `SHARE_PORTAL=true` trades that refusal for
concurrency. The trade is real: while siblings run together layer 3 stops
distinguishing them, so the strict profile sits inside the loose profile's
grant. That is only sound when the application confines its own profiles, the
way a browser can lock a pref per profile. adamas cannot verify that and does
not claim to - the config asserts it. Without such a layer, leave the flag off.

### the fork path

The gap is upstream flatpak's. `--dbus-call` was proposed as
[flatpak#6526](https://github.com/flatpak/flatpak/pull/6526); upstream preferred
a portal-side entitlement model
([xdg-desktop-portal#1924](https://github.com/flatpak/xdg-desktop-portal/pull/1924),
open), so the option lives on as a [fork](https://github.com/q1sh101/flatpak) on
branch `add-dbus-call-option`. It replaces flatpak's default
`--call=org.freedesktop.portal.*=*` with explicit rules, moving the deciding
layer out of the shared store and into the sandbox:

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                   Where The Deciding Layer Lives                  │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   vanilla   layer 3   one store, one answer per app id            │
  │   fork      layer 2   one filter per sandbox, the store is        │
  │                       only the outer bound                        │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```

Layer 3 does not disappear, so every profile of one app id keeps the same
`ALLOW_PORTAL` - the outer bound, and what carries them past the conflict gate -
and they differ only in `ALLOW_DBUS_CALL`. A profile with no `Camera.*` rule
cannot reach the camera even while the store grants it, because the call never
crosses its proxy.

The launcher has no fork-aware branch: the gate compares store policy, the layer
that is genuinely shared. It only refuses `ALLOW_DBUS_CALL` on a flatpak without
`--dbus-call` instead of dropping the rule silently. The configs in `apps/` ship
both halves as commented blocks.

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
  │   │  ~/.local/share/   │     │     │  $HOOK_DIR/              │   │
  │   │  applications/     │     │     │  $HOOK_NAME              │   │
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

`adamas verify` checks that the route still points at this repo: the `.desktop`
must exec this `adamas.sh`, the hook must call `run "<conf>"` with the same
absolute path. Anything else is reported as drift.

`AUTO_SKIP=true` marks a config whose launch route is owned by something else -
`auto` leaves it alone and `verify` reports it as unmanaged instead of drift.

## config

```text
  start:     apps/example.conf     (template -- copy and edit APP_ID)
  real:      apps/firefox.conf     (working config for Firefox)
  grouped:   apps/webapps/*.conf   (optional, one level deep)
```

Config lookup is by basename, not by path: `adamas run firefox-discord` finds
`apps/firefox-discord.conf` or `apps/webapps/firefox-discord.conf`. Two configs
with the same basename are a hard error. Symlinked directories and deeper
nesting are ignored.

```sh
APP_ID="org.mozilla.firefox"

ALLOW_SHARE=(network)
ALLOW_SOCKET=(wayland pulseaudio)
ALLOW_DEVICE=(dri)
ALLOW_FILESYSTEM=(xdg-download)

PERSIST=(.mozilla .config/mozilla .cache/mozilla .local/share/mozilla)

SET_ENV=(GTK_THEME=Adwaita:dark)
ALLOW_ENV=(DESKTOP_STARTUP_ID XDG_ACTIVATION_TOKEN MOZ_APP_REMOTINGNAME)

NEED_PORTAL=true
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
  │   portals                 NEED_PORTAL                             │
  │                           ALLOW_PORTAL / DENY_PORTAL              │
  │                           ALLOW_DBUS_CALL (patched flatpak)       │
  │                                                                   │
  │   persistence             PERSIST                                 │
  │                                                                   │
  │   environment             SET_ENV / ALLOW_ENV                     │
  │                                                                   │
  │   routing                 HOOK_NAME + HOOK_DIR / AUTO_SKIP        │
  │                                                                   │
  │   extras                  ADD_POLICY / ALLOW_USB / APP_ARGS       │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```

A config is sourced as shell code, so it is checked before it runs:

```text
  config files must:
  ┌───────────────────────────────────────────────────────────────────┐
  │     - not be a symlink                                            │
  │     - be owned by the current user                                │
  │     - not be group/world-writable                                 │
  └───────────────────────────────────────────────────────────────────┘
```

Values are validated too: enums for sockets and devices, reverse-DNS for
`APP_ID`, no path traversal or overly broad paths in `ALLOW_FILESYSTEM`, and a
block-list for loader environment variables such as `LD_PRELOAD`.

## memory

RAM by default, disk only if you name it:

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

Configs that share one `APP_ID` share one Flatpak home and one portal
permission store. Separate profiles under the same app id are UI isolation, not
a security boundary.

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
  │   - runtime mode runs the app WITHOUT the sandbox             │
  │   - runtime mode is mainly for portal / D-Bus call discovery  │
  │   - env needs are not inferred (add ALLOW_ENV manually)       │
  │   - if sender resolution fails, output may include            │
  │     unrelated D-Bus traffic from other apps                   │
  │   - on vanilla flatpak the D-Bus call block is emitted        │
  │     commented out, with NEED_PORTAL=true instead              │
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

A generated config has no permissions at all, so `auto` writes it with
`AUTO_SKIP=true` and does not route launches to it. Review the config, set
`AUTO_SKIP=false`, and the next run hardens it. Apps that export no `.desktop`
are skipped, not failed.

## structure

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                        Project Layout                             │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   adamas/                                                         │
  │   ├── adamas.sh                 entry point + dispatch            │
  │   ├── lib/                                                        │
  │   │   ├── common.sh             logging, validation, lookup       │
  │   │   ├── run.sh                stateless sandbox launcher        │
  │   │   ├── install.sh            flatpak install                   │
  │   │   ├── harden.sh             .desktop patch or launcher hook   │
  │   │   ├── verify.sh             route / hook integrity check      │
  │   │   ├── auto.sh               auto-harden all apps              │
  │   │   ├── watch.sh              systemd path + timer              │
  │   │   └── trace.sh              draft config generation           │
  │   └── apps/                                                       │
  │       ├── example.conf          template                          │
  │       ├── firefox.conf          per-app config                    │
  │       └── webapps/              optional grouping (one level)     │
  │           └── firefox-*.conf    browser-backed webapp configs     │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```

## requirements

```text
  ┌───────────────────────────────────────────────────────────────────┐
  │                        Requirements                               │
  ├───────────────────────────────────────────────────────────────────┤
  │                                                                   │
  │   flatpak >= 1.14.10                                              │
  │   flatpak 1.15 requires >= 1.15.10                                │
  │   flatpak 1.16+ recommended                                       │
  │                                                                   │
  │   portal access:                                                  │
  │     NEED_PORTAL=true      coarse  - any portal call (vanilla)     │
  │     ALLOW_DBUS_CALL=()    narrow  - named methods only (fork)     │
  │                                                                   │
  │   ALLOW_DBUS_CALL requires patched flatpak (--dbus-call support): │
  │     repo:   https://github.com/q1sh101/flatpak                    │
  │     branch: add-dbus-call-option                                  │
  │     on vanilla flatpak adamas refuses to launch such configs      │
  │     everything else works without the fork                        │
  │                                                                   │
  │   trace --runtime requires: gdbus, dbus-monitor                   │
  │   watch requires: systemd --user                                  │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘
```
