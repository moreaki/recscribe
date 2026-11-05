# Source notices and licensing

RecScribe is distributed under Apache License 2.0 in `LICENSE`. Its license terms
are unchanged. The application copyright statement names the current project
owner. `NOTICE` retains the current project notice and the Apple framework notice.
Unrelated dependency licenses and vendor notices remain applicable to their own
components; this review does not relicense them.

The component review in [recording-foundation.md](provenance/recording-foundation.md)
found no retained authored implementation, test implementation or media/font asset
from the retired baseline. Surviving matches are standard SDK interfaces, generated
Xcode/catalog metadata, file-format constants and compatibility/data contracts.
The superseded product attribution and author statement no longer identify a
covered current component and have been removed from the current tree.

This disposition applies the exclusions for notices that do not pertain to any
remaining part in [Apache-2.0 sections 4(c) and 4(d)](https://www.apache.org/licenses/LICENSE-2.0).
It is based on the documented component review, not merely a successful build or
an empty text search. It is not a clean-room certification.

Historical commits keep their original notices. Existing release archives and
GitHub discussions are unchanged. The current-tree regression guard has no license,
notice, documentation or tool exceptions: it derives retired identities from the
preserved historical snapshot and checks every tracked file and the built app.
