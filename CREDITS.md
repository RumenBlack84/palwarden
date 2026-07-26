# Credits & inspiration

`palwarden` stands on the shoulders of other people's work. This project is
licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)); the components below keep
their own licenses, and this file records what came from where so nobody's work
is passed off as ours.

## Starting points / bundled components

### Palworld Config Parser Tool — inspiration (no longer bundled)
- **Upstream:** pelican-eggs/Palworld-Config-Parser-Tool (v1.0.23), **AGPL-3.0**
- **History:** we originally shipped the upstream *prebuilt binary* at
  `bin/palworld-config-parser`, wrapped by `sbin/palworld-config-apply-env`. It
  established the interface this project still uses: settings come from the
  environment, the live `PalWorldSettings.ini` is edited in place.
- **Now:** that binary has been **removed and replaced by our own Python
  implementation** at the same path, so the repo and image contain no opaque
  third-party executable. The reimplementation was written from the observable
  interface (env-var names, Palworld's own INI format) — not from upstream source —
  and resolves env names against the keys present in the live config rather than
  copying any mapping table. Credit to the upstream project for the idea and the
  interface; it is no longer a dependency.

### Palworld Dedicated Server Config Creator (web UI)
- **Upstream:** BlinkZer0/Palworld-Dedicated-Server-Config-Creator
- **License:** **MIT** — retained verbatim at
  [`webui/LICENSE.upstream-mit`](webui/LICENSE.upstream-mit)
  (© 2025 Palworld Dedicated Server Config Creator Contributors).
- **How we use it:** `webui/PalWorldSettingsEditor.html` (and the companion
  Engine.ini editor) are the basis for our in-browser config editors. MIT permits
  us to adapt them freely and combine them into this AGPL project; we keep their
  copyright + permission notice for the parts derived from their work.

## Trademark

Palworld is a trademark of Pocketpair, Inc. `palwarden` is an unofficial,
community tool and is not affiliated with, endorsed by, or connected to
Pocketpair.

---

*Building on someone's tool here doesn't imply they endorse this project. If you
maintain one of the upstreams and want the attribution changed, open an issue.*
