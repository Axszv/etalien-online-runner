# ETAlien task runner

This repository contains the protocol layer for the ETAlien mobile task page.

The Android client fetches the current reward ladder from:

```text
GET /award/v1/ad/activity
```

The response is protobuf `AdActivityResponse` and includes the current watch
count, next required count, next reward, and the per-stage `videoBar` list.
The request uses the client signing scheme recovered from version 3.13.10.

## Configuration

Set these environment variables for a read-only inspection:

```text
ETALIEN_TOKEN       raw value of the Authorization header
ETALIEN_DVC         device identifier used in x-eta
ETALIEN_CHANNEL     channel value used in x-eta (default: official)
```

Run:

```text
node src/cli.mjs inspect
```

The included GitHub Actions workflow runs at approximately 09:31 Beijing time
and prints the server-provided task snapshot. GitHub schedules can be delayed.

For a fresh mobile session, the client also exposes the SMS login protocol:

```text
node src/cli.mjs login-code PHONE
node src/cli.mjs login PHONE CODE
```

An independent WeChat QR session is available without reading the desktop
client files:

```text
node src/cli.mjs qr-start
node src/cli.mjs qr-poll
```

Open the URL printed by `qr-start`, authorize it in WeChat, then run
`qr-poll`. The same generated device ID is reused for polling and later API
calls.

The CLI masks the authorization value in normal output and saves the full
session to the ignored `.session.json` file. Deployments should store those
values in the platform secret store rather than committing the file.

The first implementation intentionally separates task discovery from ad
playback. A successful ad reward requires a valid rewarded-ad SDK callback;
the business API does not expose a direct mobile reward-submit endpoint.
