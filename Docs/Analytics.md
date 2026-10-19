# On Screen tracking reference

On Screen is a quiet macOS desktop timestamp/custom-text utility. Its menu bar
contains the controls; it has no Settings window, account, onboarding wizard,
or separate Apply action. Successful `app_launched` means initialization reached
the desktop window and menu. First observed launches are a setup proxy, not an
onboarding-completion funnel or proof that the person looked at the artwork.

On Screen 1.4.2/build 15 uses PostHog as its only analytics SDK. Release
validation and earlier live analytics checks are recorded separately below.

## Traffic and privacy

Schema 2 puts these string properties on every product event and exported log:

| Property | Meaning |
| --- | --- |
| `analytics_environment` | `production`, `development`, or `test`, from bundled build provenance. Ordinary Release builds are still development. |
| `is_internal` | `"true"` for all development/test builds and developer testing of a production binary; otherwise `"false"`. |
| `app_version`, `app_build` | Bundle version/build; PostHog events also retain `$app_version`, `$app_build`, and `$app_namespace`. |
| `analytics_schema_version` | `"2"`, distinguishing this instrumentation from the initial unlabeled trial. |

Public reporting requires **both** `analytics_environment = production` and
`is_internal = "false"`, plus `$app_namespace = info.ericprice.on-screen` for
events. Missing labels are excluded; old test traffic must not be guessed from
IP addresses. Internal validation uses `is_internal = "true"` and schema `"2"`.
Logs use the same labels and `service.name = on-screen-macos`.

The signed distribution packaging script explicitly bundles production/false.
Other builds default to development/true. The build rejects a production label
on ordinary builds; `.env` cannot select it. A runtime test-mode override can
demote a build to test, never promote it to production. The local preference
`analyticsInternalTesting = true` marks even a production binary as internal;
it never enables analytics. No email, account identity, or IP-based exclusion
is used.

The existing `shareUsageStatistics` preference gates analytics, including
daily presence and fixed logs. Startup while opted out skips PostHog setup.
Runtime opt-out blocks capture and queued transport; requests already in flight
can finish. Previously enabled events can remain queued and resume on opt-in.
The existing unset-preference default remains unchanged. Local checks use an
isolated preferences/cache home and intercepted SDK transports.

Custom text, text length, screen contents, file paths, feed URLs, raw errors,
credentials, and personal content never enter event payloads. PostHog strips
unapproved events/properties, creates no person profiles, discards client IPs
at the project, and disables GeoIP enrichment, broad autocapture, replay,
automatic screens/lifecycle capture, exception capture, and feature-flag calls.
Its anonymous installation identity is an installation proxy, not a person.

## Shared snapshots

**Display**: `dateFormat` is a fixed `DateDisplayFormat` ID; `includeTime`,
`updateDaily`, and `randomizeFormat` are saved choices; `timeIncluded` and
`dailyUpdatesActive` describe their effective state; `mode` is `timestamp` or
`custom`. Booleans are strings `"true"`/`"false"`. A format that inherently
includes time may have `includeTime="false"` but `timeIncluded="true"`.

**Preferences**: `openAtLogin`, `automaticUpdateChecks`, `automaticUpdates`
are boolean strings; `openAtLoginStatus` is `enabled`, `disabled`,
`requiresApproval`, `notFound`, or `unknown`. Snapshots describe the moment an
event is captured; they do not imply someone edited those preferences then.

## Product events

Every row also includes the shared traffic/version properties above.

| PostHog event | Trigger and additional properties | Question answered |
| --- | --- | --- |
| `app_launched` | Successful app initialization, including login startup. Display + preferences. | Did this reporting installation initialize successfully, and with which configuration? |
| `app_running_daily` | First eligible observation in a UTC day after successful startup, wake, daily boundary, clock change, or consent enabling. Display + preferences; bounded `reason`. | Was this reporting process awake/running at least once that day? |
| `app_woke` | Machine wake. Display + preferences. | Did the running app resume, with what state? |
| `timestamp_refreshed` | Actual timestamp refresh caused by midnight, reset, or clock/time-zone change, while timestamp mode is active. Display; `reason`, `previousDateFormat`, `randomized`. | Is automatic/manual timestamp maintenance occurring? |
| `display_setting_changed` | Confirmed Date Format, Include Time, Update Daily, or Randomize Format action that changes state. Display; `changedSetting`, categorical `previousValue`, `value`, `previousMode`. | Which display settings do people change, and in which direction? |
| `custom_text_changed` | Confirming Custom Text changes the text or returns to a newly refreshed timestamp. Display only. Cancel and unchanged confirmation send none. | Is custom-text mode used? |
| `text_color_changed` | Actual color/mode change after a 0.25-second quiet interval, or final pending change on termination. `color` is normalized `#RRGGBB`; `mode` is `white`, `black`, or `custom`. | Which color controls are used? |
| `date_format_randomized` | An automatic random selection chooses a different date format. Display; `reason`, `previousDateFormat`. | Is automatic format randomization operating? |
| `preferences_changed` | An observed login/updater preference actually differs from its baseline. Preferences; `changedPreference`, categorical `previousValue`, `value`. One event per changed preference. | Which automatic behaviors change? |
| `updates_checked` | The menu's Check for Updates action. No extra payload. | How often do people request an update check? |
| `update_check_completed` | A started Sparkle update cycle finishes, once. `source`: `manual`, `automatic`, `information`, `unknown`; `outcome`: `up_to_date`, `update_available`, `cancelled`, `failed`, `unknown`. | What observable results do update checks produce? |
| `update_check_failed` | A genuine operational Sparkle failure. `source`; `category`: `network`, `feed`, `download`, `signature`, `configuration`, `installation`, `other`. | Where do updates fail? |
| `open_at_login_failed` | A genuine service registration/unregistration failure. `operation`: `automaticRegistration`, `enable`, `disable`; `category`: `signature`, `permission`, `notFound`, `unavailable`, `configuration`, `internal`, `other`. | Where does automatic startup fail? |
| `about_opened` | Opening the native About panel. | Is product information being sought? |
| `website_clicked` | Clicking the fixed public link in About. `source=about`; no URL captured. | Is the product website link used? |

Selecting the saved date format while custom text is displayed exits custom
mode. It is one real display-setting action; equal date-format old/new values
are explained by `previousMode=custom`, `mode=timestamp`. Programmatic startup,
menu rendering, no-op format/color selections, disabled controls, and slider
intermediate values do not create extra change events. Randomization and
timestamp refresh can describe the same automatic action; do not add them to
intentional customization counts. `mode` on color events has the separate color
meaning shown in the table.

## Presence and update semantics

Daily presence is independent of Update Daily, date format, and custom text.
It saves a monotonic UTC epoch-day marker before capture, emits no missed-day
backfill, and deduplicates across relaunches, timers, and wakes. Sleep cancels
the timer; wake reschedules it. The timer does not wake the computer. Opt-out
sends nothing and does not consume the day's marker. Backward clock changes
wait until a day later than the saved marker. Resetting local app storage or
transport loss can affect this best-effort measure.

This event means **the process was awake/running at an observation that UTC
day**. It does not measure interface attention, time spent, continuous uptime,
screen visibility, or all installations. PostHog dashboard calendar buckets
follow the project's America/New_York time zone; the deduplication boundary is
still UTC. Use explicit UTC windows when comparing emission-day totals.

Sparkle's explicit latest/newer-than-latest result means `up_to_date`.
Availability requires a valid-update callback; it never claims installation.
Explicit cancellation errors/download-cancel callbacks mean `cancelled`.
Unsupported hardware/OS, deferred checks without availability evidence, and
nil-error completions without result evidence are `unknown`. Raw messages stay
local. Cancellation, already-current results, and authorization deferral are
excluded from operational failures.

A manual no-update cycle finishes when its dialog is dismissed. Repeated
requests may only refocus an existing update dialog; requests and completions
need not match 1:1. A failed cycle has both a completion (`outcome=failed`) and
the existing categorized failure event. Count it once, and keep sources and
time windows consistent before deriving any rate. Do not report install
conversion or an overall app failure rate from these counts.

## Fixed logs

Only three messages are exported. OSLog output is not uploaded. Logs omit
installation/session IDs, screen names, feature flags, and free-form context.

| Log event | Level, trigger, extra properties |
| --- | --- |
| `desktop_app_ready` | Info, after successful initialization; `daily_updates_enabled` boolean. |
| `update_check_requested` | Info, menu request; `source=manual`. |
| `update_check_failed` | Error, same occurrence as the product failure event; bounded `source`, `category`. |

Ready/request logs are normal operation, not warnings. Never add log counts to
the corresponding product-event counts.

## Local testing and verification

1. Run `./script/check_analytics.sh` and `./script/check_running_daily.sh`.
   Real SDK transport is intercepted: no generated failures or private test
   text reach PostHog. Enabled/disabled runs have separate
   temporary homes. Checks assert exact event multisets, safe old/new values,
   completion deduplication, debouncing, provenance, and no opted-out requests.
2. Run `./script/build_and_run.sh --verify` for a development/internal local
   build. It replaces the local app with a recoverable backup; it publishes no
   release. Retain the existing analytics preference.
3. Open About, change a date format, confirm the same format again, toggle
   Include Time/Update Daily, and choose a color. Actual changes should yield
   one corresponding event each; the no-op selection yields none. Restore
   your preferred settings afterward (restoration is another actual change).
4. Choose Check for Updates once and dismiss its result dialog. Expect one
   `updates_checked`, one fixed request log, then one completion if Sparkle
   starts and finishes a cycle. Allow roughly 60 seconds for normal batching.
5. Inspect internal/schema-2 traffic in PostHog. Daily presence should remain
   one for the current UTC day even across relaunch/wake. Do not force fake
   errors, alter your clock, or reset production analytics storage to test it;
   deterministic isolated checks cover those paths.
6. Ask Sprite for a **read-only internal-test** report using the reference
   below. Its ordinary production report should exclude these actions. Check
   Sprite's actual reply separately; PostHog receipt alone cannot prove Sprite
   fetched or interpreted it. Publish only after reviewing these results and
   explicitly approving a release.

Implemented code, intercepted SDK verification, live PostHog receipt, and
Sprite's own response are distinct evidence. See the verification record below
for what has actually been observed.

## Share with Sprite

> Read On Screen project **673543** and its [usage and reliability dashboard](https://us.posthog.com/project/673543/dashboard/2228959).
> For ordinary reporting, require `analytics_environment=production` and
> `is_internal="false"`; exclude missing labels. For a requested local test,
> use `is_internal="true"` and `analytics_schema_version="2"`, report the
> environment and time window, and keep it out of adoption/reliability claims.
> `app_running_daily` measures observed awake/running process presence, never
> engaged users or continuous runtime. Intentional use is described by actual
> display/custom-text/color changes; quiet days alone do not imply abandonment.
> Update availability is not installation; `unknown` is not a failure. Request,
> completion, and failure counts have different triggers. Fixed logs at
> `service.name=on-screen-macos` describe the same operations; do not double count.
> Report meaningful changes or categorized production failures with counts,
> source/version, window, and sample-size caveats. Do not change settings,
> create alerts, or take action from this read-only brief.

## Current verification: 2026-10-19, 1.4.2/build 15

The universal Developer ID signed package passed notarization
(`a7df958b-e090-4b84-9e8a-817790767af4`), stapler validation, and Gatekeeper
assessment. [Version 1.4.2](https://github.com/ericprice/on-screen/releases/tag/v1.4.2)
was published from commit `d9cad84`. Its GitHub release body is empty, and the
Sparkle feed contains no embedded or linked release notes. The uploaded assets'
SHA-256 digests match the verified local ZIP and appcast.

The 103 date-format, 16 scheduler, and 126 font/layout checks passed.
Distribution validation confirmed production/external analytics configuration.
The released app was installed and launched locally. Analytics behavior is
unchanged; live telemetry was last verified on 1.4.1/build 14 as recorded below.

## Historical verification: 2026-10-19, 1.4.1/build 14

All 15 product-event types passed real-SDK checks with intercepted transport,
including enabled/disabled privacy and consent cases. The 38 daily-presence,
103 date-format, 16 scheduler, 126 font/layout, and 17 configuration checks
passed.

The universal Developer ID signed archive passed notarization
(`b9d1019a-d0eb-4f8a-85ea-43491ec9aa23`), stapler validation, and Gatekeeper
assessment. [Version 1.4.1](https://github.com/ericprice/on-screen/releases/tag/v1.4.1)
was published from commit `26185ee`. Its GitHub release body is empty, and the
Sparkle feed contains no embedded or linked release notes.

Live inspection confirmed `app_launched` at `12:24:21.939 UTC` and its matching
`desktop_app_ready` log at `12:24:21.745990 UTC`. Both carried all five provenance
fields: `analytics_environment=production`, `is_internal="true"`,
`app_version=1.4.1`, `app_build=14`, and `analytics_schema_version="2"`. The
product event also carried `$app_namespace=info.ericprice.on-screen`. This was
internal testing of the production binary, rather than public-user traffic.

All eight production dashboard charts completed forced-fresh queries without
errors. Empty results are expected under the strict production/external
filters, which exclude this internal validation traffic and unlabeled events.
Other action paths have not all been generated live on this binary. Sprite's
confirmation below concerns the older local build; it has not independently
rechecked this release.

## Historical verification: 2026-10-19, 1.4/build 13

These observations were recorded before the current single-SDK source change.
They remain evidence for that local build, rather than a verification of the
1.4.1/build 14 distribution app.

Verified on 2026-10-19 using the then-active SDKs with intercepted transports:
exact event/payload parity, display old/new values and mode transitions,
update outcome/source categories and completion deduplication, color debounce,
authoritative provenance on every event/fixed log, privacy allowlists, zero
startup-opt-out requests, later-opt-in recovery, and blocking/resuming queued
uploads in both then-active services. The 38 deterministic daily-presence
checks passed. The app build and 103 date-format, 16 scheduling, and 126 font/layout checks
also passed. Build-provenance validation accepted 7 safe contexts and rejected
14 unsafe contexts. At that point, a new signed production archive had not been
created.

Live MCP inspection confirmed schema-2 development/internal traffic from the
local app, version 1.4/build13: one launch, one `app_running_daily`, one About
opening, two date-format changes (`kawara` → `iso8601` → `kawara`), one manual
request, and one manual `up_to_date` completion. Those seven events arrived
at 07:17–07:19 America/New_York. The ready and manual-request fixed logs carry
the same metadata. Other event/error paths passed isolated checks but have
not all been generated live; no synthetic failures were uploaded.

All eight production dashboard charts execute and exclude internal/unlabeled
traffic. The [internal validation view](https://us.posthog.com/project/673543/insights/ZLmkfjSp)
uses a recent two-hour window and displays the test counts separately. Earlier
unlabeled trial events are excluded from production charts. On Eric's machine,
the separate `analyticsInternalTesting` marker was true at the time; analytics
consent was retained. Nothing had been published at that observation.

Eric relayed Sprite's confirmation on 2026-10-19: it read the brief and
verification notes, matched all seven events and two informational logs,
correctly distinguished daily process presence from engagement, and confirmed
the development/internal/schema-2 labels and production exclusions. This
completed the local app → PostHog → Sprite interpretation check for that build.
It does not establish observation of real public traffic or Sprite's independent
review of 1.4.1.
