# Nocturne Health

Copies Apple Health activity into your Nocturne site, so it shows up next to
your glucose:

- **Steps** in 5-minute buckets (Health merges iPhone and Apple Watch, so steps
  aren't counted twice) → Nocturne step counts
- **Heart rate**, averaged per 5 minutes → Nocturne heart rate
- **Workouts** (type, duration, active calories, distance) → Nocturne exercise
  activities

It syncs when you open it and in the background whenever Health gets new data.
iOS limits background step updates to about once an hour, and Health data can't
be read while the iPhone is locked, so some syncs wait until the next unlock.

Every record carries a stable ID, and Nocturne updates a record it already has
instead of adding another. The app re-sends the last 6 hours on every sync to
pick up Apple Watch data that arrives late, and "Send everything again" is safe
to use.

Not synced: workouts you delete in Health stay in Nocturne (removing them would
need a full-access token). Delete them in Nocturne if needed.

## Install with TestFlight (GitHub Actions)

Same signing setup as Trio and Nocturne Viewer: the six secrets `TEAMID`,
`GH_PAT`, `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY`,
`MATCH_PASSWORD`, and your existing `Match-Secrets` repository.

1. **Secrets.** Add the same six secrets under **Settings → Secrets and
   variables → Actions** (skip if they're set on your GitHub organization).
2. **Actions → 1. Add identifier → Run workflow.** Registers the bundle ID
   `com.<TEAMID>.nocturnehealth` with HealthKit turned on, and makes its App
   Store profile.
3. **App Store Connect → Apps → + → New App.** Platform iOS, name "Nocturne
   Health" (or anything), bundle ID `com.<TEAMID>.nocturnehealth`, any SKU, Full
   Access.
4. **Actions → 2. Build to TestFlight → Run workflow.** About 10 minutes, then
   Apple takes a few more to process it.
5. In App Store Connect → the app → **TestFlight**, add yourself to an internal
   testing group (once). Install from the TestFlight app.

Run step 4 again for a new build. TestFlight builds expire after 90 days.

**0. Check build** compiles the app on every push without signing, so code
errors show up without spending a TestFlight build.

## Set it up on the phone

1. In Nocturne: **Settings → Connectors & Apps → API Tokens → Create token**.
   Label it "Apple Health" and give it write access to **step count**, **heart
   rate** and **treatments** (workouts are stored through the treatments-scoped
   activity endpoint).
2. In the app: enter `https://your-name.nocturne.run` and the token, then
   **Save & test connection**.
3. Tap **Allow Apple Health access** and turn on Steps, Heart Rate, Workouts,
   Active Energy and the distance types.
4. Pick how far back the first sync goes (default 30 days). It runs right away.

## How it talks to Nocturne

- `POST /api/v4/StepCount` and `POST /api/v4/HeartRate`, with
  `dataSource: "apple-health"` and a `syncIdentifier` of the bucket start
  (`steps:<unix seconds>`, `hr:<unix seconds>`)
- `POST /api/v1/activity` for workouts, with `_id: healthkit-<workout UUID>`
- `Authorization: Bearer noc_…`

## Build locally instead (Mac with Xcode 26)

`brew install xcodegen`, then `xcodegen generate` in this folder, open
`NocturneHealth.xcodeproj`, pick your team under Signing & Capabilities, and
run on your phone. HealthKit doesn't work in the Simulator.
