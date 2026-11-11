# DicyaninBugReport

Shake the device, type one line, tap Report. The screenshot and note go to the Cadence Mac app on the same
network. Reports are saved on device first and sync whenever Cadence is reachable.

## Install

```yaml
# project.yml (XcodeGen)
packages:
  DicyaninBugReport:
    url: git@github.com:hunterh37/DicyaninBugReport.git
    from: 1.0.0
targets:
  App:
    dependencies:
      - package: DicyaninBugReport
    info:
      properties:
        NSLocalNetworkUsageDescription: Sends bug reports to Cadence on your Mac.
        NSBonjourServices: [_cadencebug._tcp]
```

```swift
import DicyaninBugReport

@main struct MyApp: App {
    init() { BugReporter.shared.install(project: "RealityStudio") }
    var body: some Scene { WindowGroup { RootView().bugReporter() } }
}
```

Optional: `BugReporter.shared.screenName = { router.current }` adds the screen name to each report.
`BugReporter.shared.showingList = true` opens the report list. Wrap `install` in `#if DEBUG` to keep it out of release builds.

## Status

Each report shows a dot. Red: saved on device, Cadence has not received it. Green: Cadence stored it.
A hammer means Cadence started a Claude session for it, a checkmark means it was marked fixed.

## Sync

Reports live in `Application Support/DicyaninBugReport/<id>/` (report.json, shot.png). Sync runs on launch,
on network change, when Cadence appears on Bonjour, after each report and every 60 s. Fixed reports older
than 14 days are pruned.

## Protocol v1

TCP, Bonjour type `_cadencebug._tcp`. See `BugWire.swift`.

| Request | Bytes |
|---|---|
| magic | `DBR1` |
| kind | `P` post, `Q` query |
| JSON length | UInt32 big-endian |
| JSON | `BugReport` or `{"ids":[...]}` |
| payload length | UInt64 big-endian |
| payload | PNG for `P`, empty for `Q` |

Reply: UInt32 big-endian length, then `{"ok":true,"states":{"<uuid>":"received"},"host":"Mac"}`.
States: `queued`, `received`, `working`, `fixed`. The server closes after the reply.
