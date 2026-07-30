# ClipShare Relay API Reference

The relay only authenticates devices and transports encrypted envelopes. It
never receives clipboard plaintext.

## Service requirements

The relay must start with a unique `JWT_SECRET` of at least 32 bytes. Bind it
to a private network or place it behind TLS when pairing or syncing across an
untrusted network.

## Health check

`GET /healthz`

Returns `200 OK` with the body `ok` when the HTTP server is running.

## Start pairing

`POST /v1/pair/start`

Starts a ten-minute pairing session for the device displaying the QR code.
Rate limited to ten requests per five minutes per direct source IP.

Request JSON:

```json
{
  "device_id": "mac-123",
  "device_name": "MacBook Pro",
  "public_key": "base64-encoded-32-byte-x25519-public-key",
  "platform": "macos"
}
```

`platform` must be `macos` or `android`. `device_id` is limited to 128
characters, `device_name` to 120 characters, and `public_key` must decode to
exactly 32 bytes.

Successful response JSON:

```json
{
  "token": "pairing-token",
  "server_url": "wss://relay.example/pair",
  "expires_at": "2026-07-30T12:10:00Z",
  "device_id": "mac-123",
  "device_pub": "base64-encoded-32-byte-x25519-public-key"
}
```

The QR payload contains this response. The Mac connects as the `originator`;
the Android device connects as the `peer` and submits its own device identity.
Both receive device JWTs after a successful pairing.

## Pairing WebSocket

`GET /pair?token=<pairing-token>&role=<originator|peer>`

The peer sends:

```json
{
  "device_id": "android-456",
  "device_name": "Pixel",
  "public_key": "base64-encoded-32-byte-x25519-public-key",
  "platform": "android"
}
```

The relay rejects an expired token, an invalid identity, unsupported platform,
or a self-pairing attempt. Clients must keep the public key scanned in the QR
code as the pairing trust anchor.

## Device WebSocket

`GET /ws`

Authentication is supplied either as `Authorization: Bearer <device-jwt>` or
as a `Sec-WebSocket-Protocol` value prefixed with `Bearer.`.

### Encrypted route

```json
{
  "id": "globally-unique-message-id",
  "type": "route",
  "to": "recipient-device-id",
  "data": "encrypted-envelope-json",
  "qos": "at-least-once"
}
```

The relay derives `from` from the authenticated token. It verifies that both
devices belong to the same user, persists the route before attempting socket
delivery, and retains it for up to 24 hours until the recipient acknowledges
the same message ID. The encrypted WebSocket route is limited to 8 MiB, which
supports a 5 MiB image payload after envelope and base64 overhead.

### Delivery acknowledgement

```json
{
  "id": "globally-unique-message-id",
  "type": "ack",
  "to": "original-sender-device-id",
  "status": "ok"
}
```

The relay derives `from` from the authenticated recipient and removes only the
matching durable route for that recipient. Clients must treat routes as
at-least-once and deduplicate by the encrypted item ID.
