The real bin/fm-sharkboard.sh ran with the installed sharkctl CLI against a loopback SHark board API emulator (loopback-shark-emulator.mjs).
Port 47811 is the origin in the dedicated FM_SHARKBOARD_CONFIG file. Port 47812 is the ambient HARK_API_URL decoy, which expects the ambient HARK_TOKEN.
On each emulator, the "auth" column shows whether the request carried the token that emulator expects.
In the HEAD~1 transcript, every request went to the decoy (47812) with the ambient token: the pre-fix override bug.
In the HEAD transcript, every request went to 47811 with the dedicated config token, and the decoy received nothing.
No production SHark, phone, or notification was involved.
