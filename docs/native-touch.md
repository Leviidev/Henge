# Native touch

Native touch sends up to five direct finger contacts to a macOS 27.2 or later
guest through Henge's emulated USB touchscreen. It works with guest SIP enabled.
The default USB path needs no virtual-HID entitlement, Apple Developer account
or guest provisioning profile.

Trackpad mode remains the default and the fallback when the guest helper is
unavailable.

## Setup

1. Install a Henge build containing USB native-touch support.
2. Focus Terminal in the guest. In Henge's Details panel, choose
   **Touch input → Type the Helper Update Command**, then press Return.
3. Allow **Local Network** for **Henge Sharing Agent** when macOS asks. This is
   the ordinary permission for the shared folder, clipboard and touch connection.
4. Enable **Native touch (experimental)** in Details, then close the panel.

The setting is saved. The USB path needs neither Accessibility nor Input
Monitoring permission. Details reports connection failures and falls back to
trackpad mode. Transport timeouts retry after the helper reconnects.

## Behaviour

Contacts are normalized to the displayed guest image, including zoom. The
helper preserves changes in contact membership and coalesces ordinary movement.
It keeps finger identities stable through motion and lift, including the brief
lift-report interval that macOS needs before a contact slot is reused.

Opening a Henge panel, backgrounding the app or changing image geometry releases
the contacts. Sender and helper heartbeats protect stationary touches. If either
stops for 0.7 seconds, the host releases input and restores trackpad mode. The
USB device also has an independent watchdog, so a stalled helper cannot leave a
contact held just because the UI stopped polling status.

USB shutdown delivers lifts and an empty frame before removal. A guest driver
that stops servicing its interrupt ring cannot hold device teardown indefinitely.

External-display sessions use the phone's trackpad controls. A four-finger tap
reveals hidden Henge controls.

## Display association

Recognizing a standard touchscreen descriptor is insufficient: macOS also needs
to associate the device with a display. The helper obtains the main display's
UUID using `CGDisplayCreateUUIDFromDisplayID` and registers an IOKit publication
observer before asking Henge to attach the USB device.

The observer writes a `displayUUID` string on Henge's USB HID device as it is
published. Its child event service inherits that property. This happens before
the desktop caches the service identity: the USB controller holds the standard
Digitizer Report Rate feature reply until the helper verifies the current device's
UUID and acknowledges the mapping. The helper then checks the event-service
association and the display's multitouch capability before advertising readiness.

`displayUUID` routing is undocumented and can change with macOS updates. This
is why the setting remains experimental. Henge does not change SIP, boot policy
or the private external-touch feature flag.

## Guest helpers and transport

The installer delivers two normally signed, unentitled bundles:

- **Henge Sharing Agent.app** owns the existing private connection to Henge at
  `10.0.2.4`, clipboard synchronization and the shared folder mount. Its bundle
  declares the Local Network purpose so macOS can present a recognizable prompt.
- **Henge Touch Agent.app** observes USB publication and encodes contact reports.
  It uses bounded stdin/stdout requests through the sharing helper and has no
  network connection or listening socket of its own.

Both bundles travel in `henge-touch-agent.tar.gz`, preserving their Mac signatures
through IPA signing and installation. The installer verifies signatures before
replacing helpers and keeps a previously installed sharing bundle as a fallback
if an update fails.

The host validates command epochs, contact IDs and coordinates. USB reports carry
an epoch plus a fixed 32-byte HID packet; stale reports cannot reactivate input
after a mode or geometry change. Only the three native-touch HTTP endpoints can
be requested through the companion's pipe connection.

## Development and verification

Build with Xcode 27.3 or newer:

```sh
make test-native-touch test-guest-connection test-usb-touchscreen
tools/check_native_touch.sh
```

The focused checks cover epoch validation, contact membership, idle polling,
HTTP transport, pipe concurrency/cancellation/EOF, USB control and interrupt
transfers, hot-plug, overflow, watchdog release and Swift compilation.

Live validation used a macOS **27.2, build 26B123** guest with SIP and authenticated
root enabled, empty boot arguments and the external-touch flag disabled. The
ordinary helpers carried no restricted entitlement or provisioning profile.
Through the same host input API used by iOS, USB input activated an AppKit button
and delivered five direct contacts, motion, partial lifts, replacement fingers
and a final all-up sequence. The receiver recorded direct contacts rather than
mouse synthesis. The same suite passed after a full shutdown and cold start,
without reinstalling or restarting either helper. Sender expiry and killing the
touch companion both delivered a terminal zero-active-contact event.

## Legacy CoreHID compatibility

The previous CoreHID provider remains available when a host does not advertise
USB support. That provider creates a virtual HID device and still needs
Accessibility and a legitimately authorized
`com.apple.developer.hid.virtual.device` entitlement. These requirements do not
apply to the default USB provider.

The packager retains explicit provisioning support for that compatibility path:

```sh
export HENGE_TOUCH_BUNDLE_ID=your.registered.touch-helper.id
export HENGE_TOUCH_PROFILE=/absolute/path/to/DeveloperID.provisionprofile
export HENGE_TOUCH_IDENTITY='Developer ID Application: Your Name (TEAMID)'
make build/henge-touch-agent.tar.gz
```

A distributable CoreHID profile must authorize all devices. A development profile
requires `HENGE_TOUCH_DEVELOPMENT=1` and must include the guest's Provisioning UDID.
The packager validates platform, expiry, App ID, team, grant and certificate.
No signing variables are required for USB builds; their default signatures claim
no restricted entitlement.
