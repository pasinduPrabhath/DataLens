# Contributing

Thanks for helping improve DataLens! Bug reports, ideas and pull requests are all welcome.

## Setup

```bash
git clone https://github.com/pasinduPrabhath/DataLens.git
cd DataLens
swift build -c release            # needs Xcode / Swift 5.9+, macOS 14+
DATALENS_DEMO=1 .build/release/DataLens   # run with sample data
```

`./build.sh` produces `build/DataLens.app`.

## Workflow

- Branch from `develop` (`main` holds released code).
- Keep changes focused, and match the existing style (SwiftUI, small files, no extra dependencies).
- Test on your Mac before opening a pull request into `develop`, and describe what you checked.
- Anything that deletes files must ask for confirmation and move items to the Trash.

## Project layout

| Path | What it does |
|---|---|
| `NetworkMonitor.swift`, `UsageDB.swift`, `NetStore.swift` | Wi-Fi sampling, SQLite storage, aggregation |
| `StorageStore.swift`, `Treemap.swift` | Disk scans, cleanup suggestions, folder explorer |
| `SSDMonitor.swift` | S.M.A.R.T. status, live disk I/O, health score |
| `*Views.swift`, `Theme.swift` | SwiftUI screens and styling |
| `Demo.swift` | Sample data for `DATALENS_DEMO=1` |
