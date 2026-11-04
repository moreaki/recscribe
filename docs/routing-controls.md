# Automatic sources and routing mute (#59)

Final scope confirmed on 2026-11-04: include available capture sources automatically,
with Mute/Unmute instead of Remove/Add. Manual mute, gain and channel routing remain
unchanged. All sources keep separate original tracks at unity gain, independently
of mix mute. Output mute affects listening only.

Routing cards expose Mute/Unmute independently of their disclosure button.
The header and expanded fader share AudioLevels / PlaybackLevels settings. Muting
does not collapse/expand a card, reset gain, or enable monitoring.

Between recordings/tests, the app reconciles eligible connected inputs with the
existing shared hardware observer. Reconnected inputs retain channel choices and
mute preferences; disconnected inputs leave the next capture graph. A running
recording/test is not rebuilt on hotplug. System playback is included; an explicit
application-playback choice is retained. The existing eight-input-device and
1–32-channel limits apply; the UI reports the device limit. Existing input routes
have priority if more than eight devices are available.

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

Studio and menu-bar summaries list selected muted sources by the same names as
routing: System audio, cached application display name, or hardware input name.
A bounded persisted name cache retains unplugged input names; never-seen devices
show their UID. Unselected sources are not reported just because a mute preference survives;
selected inputs awaiting reconnection retain their last-known names. Master mix and listening-output mute are separate messages.

The [earlier UI mocks](https://github.com/moreaki/recscribe/pull/61) guided the header
mute controls and named summaries. Their Remove/Add and last-source workflows were
superseded by the confirmed automatic-source/mute-only model.

## Live input continuity

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
