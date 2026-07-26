# Credits & inspiration

`palwarden` stands on the shoulders of other people's work. This project is
licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)); the components below keep
their own licenses, and this file records what came from where so nobody's work
is passed off as ours.

## Starting points / bundled components

### Palworld Config Parser Tool
- **Upstream:** pelican-eggs/Palworld-Config-Parser-Tool (v1.0.23)
- **License:** **AGPL-3.0**
- **How we use it:** `bin/palworld-config-parser` is the upstream prebuilt binary,
  wrapped by `sbin/palworld-config-apply-env`. It's a starting point for our
  config-apply flow.
- **License note:** Because `palwarden` is itself AGPL-3.0, bundling and building
  on this is consistent. If we ever adapt its **source** (not just call the
  binary), that derived code is AGPL too — which is fine here. We may still
  reimplement it in Python over time to reduce the opaque-binary dependency, not
  for licensing reasons but for maintainability.

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
