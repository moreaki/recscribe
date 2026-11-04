# Automatic sources and routing mute (#59)

Final scope confirmed on 2026-11-04: include available capture sources automatically,
with Mute/Unmute instead of Remove/Add. Manual mute, gain and channel routing remain
unchanged. All sources keep separate original tracks at unity gain, independently
of mix mute. Output mute affects listening only.

Routing cards expose Mute/Unmute independently of their disclosure button.
Expanded routing gain controls omit the redundant mute checkbox; the card header
is the mute control in either disclosure state. Standalone level controls retain
their checkbox because they have no card header. Both use the same AudioLevels /
PlaybackLevels settings. Muting
does not collapse/expand a card, reset gain, or enable monitoring. Mute feedback
uses the existing action row, and the mute button and expanded status keep the
same footprint so toggling does not resize the card. During an audio test, every
collapsed source card shows the raw input and its routed contribution, including
muted sources. Waiting sources show empty meters and a waiting status immediately;
the last levels and held peaks stay visible after Stop. Channel-by-channel detail
remains optional.

Between recordings/tests, the app reconciles eligible connected inputs with the
existing shared hardware observer. Reconnected inputs retain channel choices and
mute preferences; disconnected inputs leave the next capture graph. A running
recording/test is not rebuilt on hotplug. System playback is included; an explicit
application-playback choice is retained. The existing eight-input-device and
1–32-channel limits apply; the UI reports the device limit. Existing input routes
have priority if more than eight devices are available.

Discovery excludes internal default-I/O helpers whose generated UID matches
`CADefaultDeviceAggregate-<process number>-<counter>`. The filter runs after
AVFoundation/HAL discovery is merged, before selection and live device admission.
It applies to helpers from any process, including old persisted helper selections
which normal reconciliation removes. Display names and aggregate transport alone
never exclude a device: deliberately configured aggregates retain their channels,
member UIDs, mute/gain and reconnection settings, even with a helper-like name.
Output-device discovery uses the same UID rule to keep helpers out of listening
output choices as well.

This policy changes selection only. It does not acquire audio or request permission
at launch. Recording still requires applicable Screen Recording/Microphone access.
Source health, permission checks and monitor feedback protection remain in
force: automatic selection cannot guarantee useful audio from a failing, silent
or unsupported device. A fully muted mix stays silent by user choice while the
separate original tracks remain recorded.

The required stereo mix offers Reset mix settings. Monitor and recording playback
offer a volume/mute reset preserving the selected output device. Monitor off is
available in the card header and menu; muting/resetting a disabled monitor never
enables it. No new output buses are introduced.

The Studio navigation row contains Studio, Audio Routing, Recordings and Settings
as peer workspace tabs. Settings renders inside the right-hand pane and adapts to
the available size; capture controls remain visible. The Settings menu, Command-comma,
menu-bar overflow and in-app Settings links all select this same workspace, even
when reopening a closed Studio window. There is no separate Settings scene.
The duplicate Recordings toolbar button and isolated Settings icon are removed.
The embedded Recordings header contains Import and Refresh; its redundant Settings,
Studio and footer Back to Studio shortcuts are omitted in favor of the persistent
top navigation.

Capture summaries omit the redundant “Audio routing…” shortcut, including in
the embedded Settings capture card; the Audio Routing tab provides navigation. These summaries list selected muted sources by the same names as
routing: System audio, cached application display name, or hardware input name.
A bounded persisted name cache retains unplugged input names; never-seen devices
show their UID. Unselected sources are not reported just because a mute preference survives;
selected inputs awaiting reconnection retain their last-known names. Master mix and listening-output mute are separate messages.

The [earlier UI mocks](https://github.com/moreaki/recscribe/pull/61) guided the header
mute controls and named summaries. Their Remove/Add and last-source workflows were
superseded by the confirmed automatic-source/mute-only model.

## Live input continuity

Routing, capture, monitoring and playback use the same app-owned hardware observer.
The embedded Settings workspace includes preserved live-draft management. Native
input continuity stays independent of the bounded whole-preview fallback used by
other capture backends.

The native multi-source backend observes available Core Audio inputs, including
virtual/aggregate devices. A failed input is stopped individually. When the same
UID returns, the writer resumes its existing source track on the original host
clock, without a five-second outage limit; missing time is silence and remains recorded as gap/failure evidence for
review. The other sources keep running. A changed native sample rate is normalized
again; changing the number of channels in an existing source track is not silently
accepted and requires review/new capture.

A new input may join the running recording or test after writer admission is
prepared. A previously unseen input starts muted in the mix; existing gain/mute
preferences are retained. Original audio is still saved. Existing microphone
permission is required; device discovery does not open a permission prompt.
The current format supports eight distinct input identities per take. Each added
source extends the bounded gain-automation map without changing earlier master
or source lanes. Monitor safety is reapplied when a virtual/aggregate input joins.

Reconnect does not restart the whole stereo mix or audio-test preview. Stop and
reconnect share a generation fence so an awaited join cannot start an engine after
Stop. Native input construction is injectable for hardware-free lifecycle tests.

System/app playback is a separate source kind. Browser Webex audio is captured
through browser/system playback, not inferred to be an independent Webex device.
A virtual driver with input channels is an input source in its own right. Its
presence does not block recording or testing and requires no duplicate-route
acknowledgment. Previously unconfigured virtual/aggregate inputs default to muted
in the mix, while their original tracks remain recorded. Existing manual level
settings take precedence. Virtual inputs are labeled by type without speculative
loopback warnings.

Monitoring can run with muted virtual inputs. If a virtual input becomes audible,
only monitoring pauses to prevent feedback; recording and the user's unmute choice
continue unchanged. Listening-output device safety remains independent.
