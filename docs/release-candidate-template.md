# Release Candidate Evidence

Copy this template into the release issue or release notes. Record real results;
do not commit device-specific traces or credentials.

## Build

| Field | Value |
|---|---|
| App version / tag | |
| Commit | |
| Android APK asset | |
| SHA-256 verified | |
| Tester and date | |

## Device Matrix

| Platform / device | OS | Startup | Library | Playback / screen off | Notification | Timer / restart | Overlay | Update / signature | Result / notes |
|---|---|---|---|---|---|---|---|---|---|
| Android reference | | | | | | | | | |
| Android OEM background-policy device | | | | | | | | | |

Confirm first launch with every optional permission denied. Each permission
handoff must occur only after the related user action, re-read real state after
returning from settings, and leave unrelated features usable after denial.

## Performance Baseline

Use the same profile build, data set, device, OS, and network condition. Record
the median of at least three runs and attach or link the raw local measurements.

| Metric | Baseline | Candidate | Change | Pass / explanation |
|---|---:|---:|---:|---|
| Cold startup to interactive frame | | | | |
| First populated/empty library frame | | | | |
| Long-list jank / frame time | | | | |
| Stable local/remote cover display | | | | |
| Large scan duration | | | | |
| Large scan peak memory | | | | |

An unexplained regression greater than 20% blocks release.

## Manual Boundaries

- [ ] Android screen-off playback remained stable.
- [ ] System installer handled the formally signed upgrade.
- [ ] Playback and timer state recovered after process/device restart.
- [ ] OEM background restrictions were documented.
