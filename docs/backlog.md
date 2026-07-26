# Palworld Tooling Ideas Backlog

Recorded: 2026-07-10

These are follow-up ideas for later review after the FPS telemetry, Engine.ini tuning editor, and event markers.

## 1. Config snapshot + label tool — implemented

Implemented in `/usr/local/sbin/palworld-config-snapshot`. Example:

```bash
sudo /usr/local/sbin/palworld-config-snapshot "balanced-60-tps-before-restart"
```

Potential output:

```text
/opt/palworld/config-snapshots/20260710T1425-balanced-60-tps/
  Engine.ini
  Engine.pretty.ini
  PalWorldSettings.ini
  PalWorldSettings.pretty.ini
  metrics.json
  system.txt
```

Purpose:

- Capture exact config + live state before/after tuning experiments.
- Make rollbacks and performance comparisons less ambiguous.

## 2. Before/after performance comparison — implemented

Implemented in `/usr/local/sbin/palworld-fps compare`. Example:

```bash
sudo /usr/local/sbin/palworld-fps compare --before 1h --after 1h --mark "Balanced 60 TPS"
```

Potential output:

```text
Before:
  avg: 58.9
  1% low: 55.0
  0.1% low: 54.0

After:
  avg: 59.1
  1% low: 58.0
  0.1% low: 56.0
```

Purpose:

- Turn tuning experiments into evidence-backed results.
- Support comparing windows around event markers or explicit timestamps.

## 3. Broader daily server health report — implemented

Extend or complement the FPS daily report with:

- FPS average / 1% lows / 0.1% lows
- current and peak player count
- API failure count
- memory current/peak
- disk usage
- restart count / recent event markers
- local Steam buildid and game version

Implemented commands:

```bash
sudo /usr/local/sbin/palworld-health-report report
sudo /usr/local/sbin/palworld-health-report discord --window 24h
```

Purpose:

- Give one Discord-safe daily operational summary.
- Highlight problems before they become player-facing.

## 4. Player count history graph panel — implemented

Implemented in `/usr/local/sbin/palworld-fps report --graph ...` and `discord`:

- top panel: FPS / server FPS average
- bottom panel: player count
- event markers spanning both panels

Purpose:

- Interpret FPS lows in context of server population.
- Distinguish idle-server dips from player-load-induced dips.

## 5. Engine profile rollback helper — implemented

Implemented in `/usr/local/sbin/palworld-engine-config rollback`:

```bash
sudo /usr/local/sbin/palworld-engine-config rollback --list
sudo /usr/local/sbin/palworld-engine-config rollback Engine.ini.20260710T182037Z
```

Expected behavior:

- Restore selected Engine.ini backup.
- Regenerate Engine.pretty.ini.
- Record an FPS event marker.
- Remind operator to run graceful restart.

Purpose:

- Make tuning experiments reversible without manual file surgery.

## 6. Engine config status/profile match — implemented

Implemented in `/usr/local/sbin/palworld-engine-config status`:

```bash
sudo /usr/local/sbin/palworld-engine-config status
```

Potential output:

```text
Active managed Engine.ini values:
- NetServerMaxTickRate=60
- MaxClientRate=100000
- MaxInternetClientRate=100000
...

Current profile match:
- Balanced 60 TPS: exact match
```

Purpose:

- Quickly understand whether the live Engine.ini matches a known profile.
- Detect manual drift.

## 7. Automatic event markers for more operational actions

Initial marker integration exists for:

- Engine.ini config apply
- PalWorldSettings.ini config apply
- graceful restart requested/completed
- Palworld update detected/completed

Potential future integrations:

- backup creation/restoration
- world save events, if useful and not too noisy
- manual maintenance windows
- crash/restart detection from systemd journal

Purpose:

- Improve graph context without making samplers noisy.

## 8. Crash/restart watchdog summary

Add a small watchdog/report that checks recent `palworld.service` restarts and abnormal exits.

Potential command:

```bash
sudo /usr/local/sbin/palworld-service-events --since 24h
```

Purpose:

- Correlate crashes/restarts with FPS drops and config changes.
- Feed daily health report.

## Prioritized next steps

1. Add crash/restart watchdog summary.
2. Consider wiring health report failures into alert-only notifications.
