# Local dependency availability

Settings checks local availability when opened, when the relevant paths change,
after install/download work, and through **Recheck**. Editing paths is debounced.
Discovery reads configured paths and the existing Homebrew search directories;
it never silently replaces a user-selected path.

| Component | When found | When missing |
| --- | --- | --- |
| FFmpeg (optional archive export) | Version, path, Recheck, Reveal; explicit Use detected executable if needed | Install FFmpeg |
| whisper.cpp | Path, Recheck, Reveal; explicit Use detected executable if needed | Install whisper.cpp |
| Ollama | Executable path or positively detected local service; Recheck | Install Ollama |
| Whisper models | Local path, Select and Reveal; size mismatch warning where appropriate | Download and verify |

Unknown/checking state does not display install/download actions. FFmpeg's version
is obtained through a bounded `-version` probe. Final WAV/session jobs use the
native Swift core; no Python runtime setup or pipeline installation is needed.
Executable presence is
retained even if version probing fails, rather than suggesting a duplicate install.
An Ollama service response counts as detection even when it has no local models.
Probe subprocesses do not run during recording/live work; passive file discovery
can still report presence. These checks never start inference or an Ollama server.

Model discovery considers RecScribe's Models directory, selected model paths,
and catalog filenames beside selected models. Filename/size evidence identifies
local candidates without repeatedly hashing gigabytes on Settings refresh.
**Found locally is not a SHA-256 verification claim.** Existing incomplete files
are shown for review, with no duplicate Download button. Missing models retain
the existing checksum-verified download workflow.

Install/download handlers check availability again before invoking Homebrew or
creating a download, including stale confirmation dialogs. Legacy Python-path
settings are ignored; the retired runtime controls are no longer displayed.
Shared Homebrew executables are never uninstalled by these controls.

Actual operation preflight remains authoritative: discovery alone does not prove
that a tool, model or pipeline can successfully process a recording.
