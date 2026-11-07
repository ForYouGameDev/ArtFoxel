# ARTFOXEL

ARTFOXEL is a local-first creative app by ShadowArc Games. This repository
started as a README-only placeholder; no pre-existing Flutter/Dart, Android,
state-management, routing, persistence, Supabase, test, or asset configuration
was available to audit. The installed Flutter and Dart versions could not be
queried in the original environment. The app baseline targets Flutter 3.32+
(Dart 3.8+) and
uses Flutter, Riverpod, GoRouter, SharedPreferences, and Supabase Flutter.

## Run

Install Flutter 3.32 or newer (Dart 3.8+) and Android Studio/Android SDK, then:

```sh
flutter pub get
flutter run
flutter test
flutter analyze
```

The Android application ID is `www.shadowarcgames.artfoxel`. Set up an Android
SDK and emulator/device through Flutter's standard `flutter doctor` workflow.

## Build Android APK and AAB on GitHub

The **Art Foxel Android Release** GitHub Actions workflow runs for pushes and
pull requests to `main`, version tags (`v*`), and manual runs from the Actions
tab. Each successful push to `main` and manual build publishes a separate
prerelease on GitHub's **Releases** page; pushing a `v*` tag publishes a
versioned release. Each release includes separately downloadable `Art Foxel.apk`
and `Art Foxel.aab` assets. Pull request builds remain available as
`Art-Foxel-<commit>` artifacts on the workflow run for 14 days. The installed
Android app is displayed as **Art Foxel**.

Both CI outputs use Android's debug signing key. The APK can be installed for
testing; neither file is signed for Play Store publishing. Configure a
protected release keystore and signing secrets before publishing. Without
Supabase build configuration, authentication remains disabled in the APK.

## Supabase (optional)

The app remains usable for local-first shell navigation when Supabase is not
configured. Authentication actions are honestly disabled until both values
below are supplied. Create a Supabase project and configure Email and/or Google
providers in its Authentication settings. Google OAuth additionally requires
provider credentials in Supabase and the corresponding redirect/deep-link
configuration for the target platforms. For Android, allow
`www.shadowarcgames.artfoxel://login-callback/` in Supabase's redirect URL
allowlist; the Android intent filter is already registered. Other platforms
need an equivalent registered callback. Google sign-in stays disabled by
default; after adding Google credentials and enabling the provider in Supabase,
also pass `--dart-define=SUPABASE_GOOGLE_ENABLED=true`.

Pass the Supabase project URL and public anon/publishable key at runtime:

```sh
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_PUBLIC_ANON_KEY
```

`.env.example` documents the variable names only; Flutter does not load it.
Never put a service-role key, OAuth client secret, or other private credential
in Dart source, assets, or a committed environment file. Client-side
configuration is not a substitute for Supabase Row Level Security.

## Structure and current scope

- `lib/app/`: app bootstrap, providers, routing, shell
- `lib/core/`: configuration, diagnostics, design system, shared UI states
- `lib/features/`: authentication, onboarding, home, projects, profile,
  settings, and separate sketch/animation workspace entry points
- `test/`: widget and configuration baseline

Project gallery metadata is stored locally. Empty galleries are real empty
states; cards do not pretend to open projects. Sketch Studio now has a static
canvas document and viewport foundation (document dimensions/DPI, transparent
backgrounds, safe bounds, pan, zoom, rotation, fit/reset, coordinate mapping,
and navigator bounds), plus pointer capture for stylus, mouse, and configurable
finger input. Captured strokes retain document-mapped positions and timestamps;
pressure, tilt, and orientation are included only when reported. This is not
yet a stroke renderer. Animation remains a separate placeholder workspace.
Community is an informational screen until its implementation phase. Brush Lab,
Color Studio, image import, project-file editing, and project
rename/duplicate/delete operations are not implemented yet; the UI does not
present these as working actions.

The supplied fox artwork at `assets/branding/app_icon.png` is registered as a
Flutter asset and used in the onboarding, home, account, and app-loading
experience, and is also used as the Android launcher icon for both legacy and
adaptive Android launchers. The application ID is unchanged.

## Phase 2 / 3 status
Sketch Studio drawing engine, persistence and Brush Lab are described in
[docs/IMPLEMENTATION_STATUS_PHASE_2_3.md](docs/IMPLEMENTATION_STATUS_PHASE_2_3.md).
They have not been compiled or tested yet — run `flutter analyze` and
`flutter test` first.


## Studio status
Phases 2–6 (drawing, layers, selections, colour studio, shapes, rulers, references, filters) are implemented but **unverified**: see `docs/IMPLEMENTATION_STATUS_PHASE_2_3.md` (needs `flutter pub get`, `flutter analyze`, `flutter test`).
