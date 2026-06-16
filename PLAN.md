# 3DWorkout — Feature Roadmap & Implementation Plan

This document plans six new capabilities on top of the current app:

1. Shareable summary card — **animated route video export**
2. Elevation profile chart (Swift Charts) synced to the animation position
3. Ghost runner — overlay two runs of the same route to compare
4. Segment PRs — fastest km, fastest climb
5. Route heatmap across all workouts
6. Strava sync (deferred — options documented, not built yet)

---

## 1. Where we are today (architecture baseline)

A quick recap of what the plan builds on. (Full detail in the codebase; key facts below.)

| Layer | Reality today |
|-------|---------------|
| **Models** | `WorkoutSession` (HealthKit metadata + optional `route`/`metrics`), `WorkoutRoute` (`[RoutePoint]` with lat/lon/**altitude**/timestamp/speed/`cumulativeDistance`, plus elevation gain/loss, min/max alt & speed), `WorkoutMetrics` (HR/pace/cadence/power `MetricSample[]` with timestamped lookup). All `Codable`. |
| **Services** | `HealthKitService` (fetch workouts, routes, metrics — local only, **no network**). `RouteAnimator` (30 fps timer, `currentPointIndex` + `progress` 0–1, `seek(to:)`, heading smoothing). |
| **ViewModels** | `WorkoutDetailViewModel` (animator + route + metrics + all customization state), `WorkoutListViewModel` (list loading). |
| **Views** | MapKit `MKMapView` via `AnimatedMapView` (progressive polyline reveal, gradient segment colors, 3D camera). `MapContainerView` (scrubber + transport controls), `MetricsOverlayView`, `CustomizationView`, `WorkoutListView`, `WorkoutDetailView`, `PermissionsView`. |
| **Persistence** | **None.** Workouts re-fetched from HealthKit every launch. Customization settings lost on restart. |
| **Networking** | **None.** |
| **Targets** | iOS 17.0, Swift 5, no third-party dependencies (HealthKit, MapKit, CoreLocation, SwiftUI, Combine). |

Two structural gaps drive most of this plan:

- **No persistence.** Three of the features (Segment PRs, Heatmap, Ghost runner) are *cross-workout* — they need data from many workouts at once. Re-fetching every route from HealthKit on demand is slow and battery-heavy. We need a local cache.
- **No render/export pipeline.** The video card needs deterministic, frame-by-frame rendering decoupled from the live 30 fps UI timer.

---

## 2. Foundation — Phase 0 (prerequisite for features 3, 4, 5)

### 0a. Local persistence with SwiftData

iOS 17 ships **SwiftData**, which fits cleanly with the existing `@MainActor` `ObservableObject` MVVM and needs no dependencies.

Add a cache layer that mirrors HealthKit, keyed by `hkWorkoutUUID` so it stays idempotent across syncs:

```
@Model final class CachedWorkout {
    @Attribute(.unique) var hkWorkoutUUID: UUID
    var workoutType: String
    var startDate: Date
    var duration: TimeInterval
    var totalDistance: Double?
    // Encoded blobs (route + metrics are already Codable):
    var routeData: Data?      // encoded WorkoutRoute
    var metricsData: Data?    // encoded WorkoutMetrics
    var segmentsData: Data?   // encoded [SegmentResult]  (Phase 3)
    var routeFingerprint: String?  // for "same route" matching (Phase 5)
    var lastSyncedAt: Date
}
```

- New `WorkoutStore` service wraps a `ModelContainer`; `HealthKitService` becomes a sync source that upserts into the store.
- `WorkoutListViewModel` reads from the store first (instant launch), then refreshes from HealthKit in the background.
- Route/metrics decode lazily on demand, exactly as today — only the storage origin changes.

### 0b. Settings persistence (small, independent win)

Persist `CustomizationView` choices (gradient metric, line width, map style, pitch, speed, 3D) via `@AppStorage`/`UserDefaults`. Self-contained; ships anytime.

**Estimate:** 0a ≈ 2–3 days, 0b ≈ half a day.

---

## 3. Feature plans

### Feature 2 — Elevation profile chart (do this first; no dependencies)

**Why first:** fully self-contained, uses data already in `WorkoutRoute.points` (`cumulativeDistance` + `altitude`), and exercises the animator-sync pattern the other features reuse.

**Design**
- New `ElevationProfileView` using **Swift Charts** (`import Charts`).
- Plot `AreaMark`/`LineMark` of `altitude` vs `cumulativeDistance` over `route.points`.
- Sync to playback: a `RuleMark` (vertical line) at the animator's current position. Bind to `viewModel.animator.progress` / `currentPointIndex` — it already publishes via Combine, so the marker moves for free.
- **Two-way sync:** drag/tap on the chart → map distance back to a route fraction → `animator.seek(to:)`. Mirrors the existing scrubber in `MapContainerView`.
- Optional: color the area fill by grade (reuse the gradient pipeline in `WorkoutDetailViewModel.buildColors`), and show a live "current elevation / grade" readout.
- Placement: collapsible panel in `MapContainerView` beneath the map, or a tab alongside metrics.

**Touches:** new `Views/ElevationProfileView.swift`; small wiring in `MapContainerView`. Down-sample very long routes (e.g. > 2k points) for smooth charting.

**Estimate:** 2–3 days.

---

### Feature 1 — Shareable summary card (animated route video)

**Goal:** export an MP4 of the route drawing itself out with a moving camera and a stats overlay — shareable to Photos / share sheet / social.

**Why video is non-trivial:** the live map uses a 30 fps `Timer` tied to wall-clock playback. A video export must be **deterministic and decoupled from real time** — render frame *N*, capture it, advance, regardless of how long each frame takes.

**Design**
- New `Services/RouteVideoRenderer.swift`:
  - Drives an offscreen/hidden `MKMapView` (reuse `AnimatedMapView`'s coordinator logic, refactored so frame stepping is callable directly rather than only via the timer).
  - For each frame: set camera + revealed polyline + position for fraction `t = frame / totalFrames`, wait for map tiles to finish (`mapViewDidFinishRenderingMap`), then capture via `drawHierarchy(in:afterScreenUpdates:)` into a `CVPixelBuffer`.
  - Composite the stats overlay (distance, time, pace, elevation, HR) + branding by drawing a SwiftUI/`UIView` snapshot over the frame.
  - Feed buffers to `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` → H.264 MP4. Target 1080×1920 (vertical) and 1080×1080 (square) presets, ~30 fps, 4–8 s clips.
- **Export UX:** an "Export Video" button opens a config sheet (aspect ratio, duration, what stats to show, intro/outro), a progress bar during render, then a `UIActivityViewController` + "Save to Photos" (needs `NSPhotoLibraryAddUsageDescription` in Info.plist).
- **Refactor enabler:** extract the map-update logic in `AnimatedMapView` into a shared `MapSceneController` usable by both the live view and the renderer, so visuals stay identical.

**Risks/notes:** tile loading is the slow part — render off the main interaction loop and gate each capture on tile completion; flyover/satellite styles may need a fixed zoom budget. Provide an image fallback (single composited frame) if the user cancels.

**Estimate:** 5–7 days (largest single feature).

---

### Feature 4 — Segment PRs (fastest km, fastest climb)

**Depends on:** Phase 0 persistence.

**Design**
- New `Services/SegmentAnalyzer.swift` computing, per workout, from `route.points`:
  - **Fastest split** for each distance bucket (1 km, 1 mi, 5 km…) via a sliding window over `cumulativeDistance` (fastest *moving* km, not just the slowest-to-start km).
  - **Fastest/biggest climb**: detect sustained-ascent segments (monotonic-ish altitude gain over a min distance), rank by VAM (vertical ascent metres/hour) and total gain.
  - Output `[SegmentResult]` cached in `CachedWorkout.segmentsData`.
- **PR rollup** across the store: for each segment category, find the all-time best → `PRRecord`. Recompute incrementally on new workouts.
- **UI:**
  - PR badges on `WorkoutDetailView` ("🏆 Fastest 5K", "🏆 Biggest climb").
  - Highlight the PR segment on the map (reuse polyline coloring) and on the elevation chart (Feature 2).
  - A "Records" screen listing PRs with deep links to the workout.

**Estimate:** 4–5 days.

---

### Feature 5 — Route heatmap across all workouts

**Depends on:** Phase 0 persistence (don't refetch every route from HealthKit).

**Design**
- New `Services/HeatmapBuilder.swift` aggregating all cached route points.
- **Rendering options (recommended → simpler):**
  1. **Weighted overlay (recommended):** bucket points into a coordinate grid, then draw an `MKTileOverlay` (or `MKOverlayRenderer`) whose alpha/color ramps with visit frequency — classic heatmap look, scales to many workouts.
  2. **Simpler v1:** `MKMultiPolyline` of all routes drawn with low opacity + additive blending, so overlapped roads naturally glow. Fast to ship; upgrade to the grid later.
- New `HeatmapView` (full-screen map): style picker, activity-type filter, date range, tap a hot segment → list of contributing workouts.
- Build the grid off the main actor; cache the rendered tiles. Region defaults to the bounding box of all routes.

**Estimate:** 4–6 days (v1 polyline glow ≈ 2–3 days).

---

### Feature 3 — Ghost runner (overlay two runs of the same route)

**Depends on:** Phase 0 persistence + a "same route" matcher.

**Design**
- **Route matching** (`routeFingerprint` on `CachedWorkout`): a geohash/bounding-box + resampled-shape signature so we can offer "other runs of this route." Match tolerance configurable.
- **Race model** (`Services/GhostRaceCoordinator.swift`): instead of two independent time-based animators, advance both runs along a **shared distance axis** (`cumulativeDistance`). At virtual distance *d*, interpolate each run's position/time → the visible gap *is* the time difference at that point on the course.
  - Reuse `RouteAnimator`'s interpolation; add a thin coordinator that fans one progress value out to two position lookups.
- **UI:**
  - Run picker: "Compare with…" → list filtered to matching routes (PR run highlighted).
  - Two position dots on the map (e.g. solid = current, ghost = translucent) + a live **delta banner** ("+12 s ahead" / "−40 m behind").
  - Optional split-by-split comparison table; tie into the elevation chart with two traces.

**Estimate:** 5–7 days (matcher is the subtle part).

---

### Feature 6 — Strava sync (DEFERRED — options for later)

Not built now. The key constraint: **Strava OAuth requires a `client_secret` that must never ship inside the app binary**, so any real API sync needs a tiny backend to perform the token exchange/refresh. Options, cheapest → richest:

| Option | What it does | Backend needed? | Effort |
|--------|--------------|-----------------|--------|
| **A. Manual file share** | Export GPX/MP4 from the app; user uploads to Strava themselves (share sheet). | **No** | Low — GPX exporter reuses `WorkoutRoute`. Good first step. |
| **B. Import from Strava** | Pull activities/routes via Strava API as a second source alongside HealthKit. | **Yes** (token proxy) | Medium |
| **C. Export to Strava** | Push HealthKit workouts up as Strava activities (write scope). | **Yes** | Medium |
| **D. Two-way sync** | Both, with dedup/conflict handling keyed on activity IDs. | **Yes** | High |

**If/when we do B–D:**
- Strava OAuth 2.0 **Authorization Code + PKCE**, `ASWebAuthenticationSession`, custom URL scheme redirect.
- A minimal hosted endpoint (Cloudflare Worker / small Lambda) holding the secret, doing code→token exchange and refresh; the app stores only short-lived tokens in the Keychain.
- Respect Strava rate limits (200/15 min, 2,000/day), cache aggressively (Phase 0 store already helps), and follow brand/API terms.
- Generalize the sync layer so Strava is just another source feeding the same `WorkoutStore` — leaving room for Garmin/Komoot later.

**Recommendation:** ship **Option A (GPX/video share)** as part of Feature 1's export work — it delivers "get my route onto Strava" with zero backend — and revisit B–D once there's appetite for hosting a service.

---

## 4. Suggested sequencing

| Phase | Work | Why this order |
|-------|------|----------------|
| **0** | SwiftData store + settings persistence | Unblocks 3/4/5; instant launches. Settings persistence ships independently. |
| **1** | **Elevation profile chart** | Self-contained quick win; establishes the animator-sync pattern reused everywhere. |
| **2** | **Shareable video export** (+ GPX export = Strava Option A) | High user value; the refactor into a shared `MapSceneController` benefits later map features. |
| **3** | **Segment PRs** | First payoff from the Phase 0 store. |
| **4** | **Route heatmap** | Reuses the store + map overlay work. Ship polyline-glow v1, upgrade to grid. |
| **5** | **Ghost runner** | Most complex; benefits from route matching + interpolation groundwork laid earlier. |
| **6** | **Strava (A now, B–D later)** | A rides along with Phase 2; B–D gated on a backend decision. |

### Cross-cutting
- Refactor `AnimatedMapView` into a reusable `MapSceneController` (used by live view, video renderer, ghost runner, heatmap).
- Add lightweight unit tests for the pure-logic pieces: `SegmentAnalyzer`, `HeatmapBuilder` grid, route fingerprint/matcher, distance↔fraction mapping.
- Info.plist additions: `NSPhotoLibraryAddUsageDescription` (video save). Strava B–D would add a URL scheme.
- No new third-party dependencies required for features 1–5.

---

## 5. Decisions (confirmed)

1. **Units:** user-selectable Metric/Imperial, defaulting to the device locale (`Automatic`). ✅ Implemented (see Status).
2. **Share video branding:** include a subtle app watermark on exported videos.
3. **Heatmap scope:** one merged heatmap with an activity-type filter.
4. **Ghost runner matching:** default to a moderate tolerance, exposed as a user-adjustable slider.
5. **Strava:** not in scope right now (options documented in §3, Feature 6 for later).

---

## 6. Status

- ✅ **Units foundation** (`UnitSettings.swift`: `UnitPreference`, `UnitFormatter`, `AppSettings`) + global **Settings** screen with the metric/imperial picker. All distance/elevation/speed/pace displays now route through the formatter.
- ✅ **Feature 2 — Elevation profile chart** (`ElevationProfileView.swift`, Swift Charts): synced rule marker to playback, drag-to-seek, units-aware, toggle in the playback panel.
- 🔧 Fixed a pre-existing compile blocker in `MetricsOverlayView.swift` (duplicated `LiveMetrics` struct + duplicate speed pill from an earlier merge).
- ⏭️ Next: Phase 0a SwiftData store, then Features 1 (video), 4 (PRs), 5 (ghost), 4-heatmap.
