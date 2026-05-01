# Synthetic Fixtures

This directory contains a tiny deterministic `chat.db` and matching `chat.db-wal` used for local and CI recovery tests.

The fixture is safe to commit because it is generated from scratch by `build-fixture.sh` and contains only:

- handle `+15551234567`
- account `fixture@example.com`
- three normal synthetic inbound messages
- one synthetic inbound retraction with recoverable WAL text: `Recovered fixture message: hello WAL data!`
- one synthetic unencrypted iPhone backup at `iphone-backup/` whose `Manifest.db` maps `Library/SMS/sms.db` to the standard backup file ID

It does not come from `~/Library/Messages`, does not include real GUIDs, and does not contain real message content.

Run `make fixture` to rebuild it.

When inspecting the database with `sqlite3`, copy the fixture to a temporary directory first. Opening `chat.db` directly can replay the sibling WAL and remove `chat.db-wal` from the working tree; `make fixture` restores both files.
