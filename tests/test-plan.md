# Clipboard Sync - Playwright MCP Test Plan

## Overview
This document outlines all tests to be executed using Playwright MCP through Claude Code.

---

## Test Suite 1: API Endpoint Tests

### Test 1.1: Health Check Endpoint
**Objective:** Verify the server is running and responding

**Steps:**
1. Navigate to `http://localhost:8081/healthz`
2. Verify HTTP status is 200
3. Verify response body contains "ok"

**Expected Result:**
- Status: 200 OK
- Body: "ok"

---

### Test 1.2: Pairing Start Endpoint
**Objective:** Test device pairing initialization

**Steps:**
1. Make POST request to `http://localhost:8081/v1/pair/start`
2. Headers: `Content-Type: application/json`
3. Body:
```json
{
  "device_id": "test-mac-device-001",
  "platform": "macos",
  "public_key": "test-public-key-base64-encoded-string-here"
}
```
4. Capture response

**Expected Result:**
- Status: 200 OK
- Response contains:
  - `token` (string, pairing token)
  - `expires_at` (timestamp)
  - `qr_data` (base64 encoded QR payload)

---

### Test 1.3: Invalid Pairing Request
**Objective:** Test error handling for malformed requests

**Steps:**
1. POST to `http://localhost:8081/v1/pair/start`
2. Body: `{}` (missing required fields)

**Expected Result:**
- Status: 400 Bad Request
- Response contains error message

---

## Test Suite 2: WebSocket Connection Tests

### Test 2.1: WebSocket Connection with Valid JWT
**Objective:** Verify WebSocket connection with authentication

**Prerequisites:**
- Need a valid JWT token (generate via pairing flow or mock)

**Steps:**
1. Connect to WebSocket: `ws://localhost:8081/ws`
2. Set header: `Sec-WebSocket-Protocol: Bearer.<valid-jwt-token>`
3. Wait for connection to establish
4. Verify connection is open

**Expected Result:**
- WebSocket connects successfully
- No connection errors

---

### Test 2.2: WebSocket Connection Without Auth
**Objective:** Verify authentication is enforced

**Steps:**
1. Attempt to connect to `ws://localhost:8081/ws` without auth header
2. Observe connection behavior

**Expected Result:**
- Connection rejected or closed immediately
- Error message about missing/invalid authentication

---

### Test 2.3: Pairing WebSocket Flow
**Objective:** Test device pairing via WebSocket

**Steps:**
1. Start pairing via POST `/v1/pair/start` (save token)
2. Connect to `ws://localhost:8081/pair?token=<pairing-token>`
3. Send pairing message:
```json
{
  "type": "pair",
  "device_id": "test-android-device-001",
  "platform": "android",
  "public_key": "test-android-public-key-base64"
}
```
4. Wait for pairing response

**Expected Result:**
- WebSocket accepts connection
- Server responds with pairing success
- Response includes device tokens

---

## Test Suite 3: Message Routing Tests

### Test 3.1: Send Encrypted Message
**Objective:** Test message routing between paired devices

**Prerequisites:**
- Two paired devices (simulated with 2 WebSocket connections)

**Steps:**
1. Connect Device A (Mac) to `/ws` with JWT_A
2. Connect Device B (Android) to `/ws` with JWT_B
3. Device A sends encrypted envelope:
```json
{
  "type": "route",
  "payload": {
    "v": 1,
    "from": "device-a-id",
    "to": "device-b-id",
    "seq": 1,
    "nonce": "base64-nonce",
    "ciphertext": "base64-encrypted-data"
  }
}
```
4. Monitor Device B for incoming message

**Expected Result:**
- Device B receives the message
- Message structure is intact
- Device A receives ACK

---

### Test 3.2: Message to Offline Device (Queue)
**Objective:** Verify offline message queuing

**Steps:**
1. Connect Device A
2. Send message to Device B (offline)
3. Disconnect Device A
4. Connect Device B
5. Check if Device B receives queued message

**Expected Result:**
- Message is queued when Device B is offline
- Device B receives message upon reconnection
- Message has correct timestamp

---

### Test 3.3: ACK/NACK Response
**Objective:** Test acknowledgment flow

**Steps:**
1. Connect two devices
2. Device A sends message to Device B
3. Monitor for ACK response to Device A

**Expected Result:**
- Device A receives ACK message
- ACK contains correct sequence number
- ACK has `status: "delivered"`

---

## Test Suite 4: Encryption Tests

### Test 4.1: Verify Server Cannot Decrypt
**Objective:** Confirm zero-knowledge architecture

**Steps:**
1. Send encrypted message through server
2. Check server logs (if accessible)
3. Verify ciphertext remains encrypted

**Expected Result:**
- Server logs show encrypted payloads only
- No plaintext clipboard content in logs
- Server processes messages without decryption

---

## Test Suite 5: Error Handling Tests

### Test 5.1: Invalid Message Format
**Objective:** Test server resilience to malformed messages

**Steps:**
1. Connect to WebSocket
2. Send invalid JSON: `{invalid json`
3. Observe server response

**Expected Result:**
- Server handles gracefully
- Connection remains open or closes with error
- No server crash

---

### Test 5.2: Message to Non-Existent Device
**Objective:** Test routing to invalid device ID

**Steps:**
1. Connect Device A
2. Send message to non-existent device ID
3. Wait for response

**Expected Result:**
- Server returns NACK
- Error indicates device not found
- Device A is notified

---

## Test Suite 6: Performance Tests

### Test 6.1: Latency Measurement
**Objective:** Measure round-trip message latency

**Steps:**
1. Connect two devices
2. Send 10 messages from Device A to Device B
3. Measure time from send to receive for each
4. Calculate average latency

**Expected Result:**
- Average latency < 400ms (target)
- No message loss
- Consistent timing

---

### Test 6.2: Concurrent Connections
**Objective:** Test multiple simultaneous connections

**Steps:**
1. Connect 10 device pairs (20 total connections)
2. Send messages concurrently
3. Verify all messages are delivered

**Expected Result:**
- All connections remain stable
- All messages delivered correctly
- No significant latency degradation

---

## Test Suite 7: Reconnection Tests

### Test 7.1: Client Disconnect and Reconnect
**Objective:** Test reconnection handling

**Steps:**
1. Connect Device A
2. Forcibly close connection
3. Reconnect Device A
4. Send message after reconnection

**Expected Result:**
- Reconnection succeeds
- Message delivery works after reconnection
- No duplicate messages

---

### Test 7.2: Offline Queue Persistence
**Objective:** Verify messages survive disconnections

**Steps:**
1. Device A sends 5 messages while Device B is offline
2. Wait 1 minute
3. Connect Device B
4. Verify all 5 messages are delivered

**Expected Result:**
- All messages queued successfully
- Messages delivered in correct order
- No message loss

---

## Test Execution Order

**Recommended execution:**
1. Start with API tests (Suite 1) - no dependencies
2. WebSocket connection tests (Suite 2) - requires API
3. Message routing (Suite 3) - requires WebSocket
4. Encryption validation (Suite 4) - parallel with routing
5. Error handling (Suite 5) - can run independently
6. Performance (Suite 6) - after functional tests pass
7. Reconnection (Suite 7) - final integration tests

---

## Test Environment Setup Checklist

- [ ] Docker Compose services running (postgres-test, redis-test)
- [ ] Backend server running on port 8081
- [ ] Test environment variables loaded from `.env.test`
- [ ] Database migrations completed
- [ ] Redis is accessible and empty

---

## Success Criteria

**All tests passing indicates:**
- ✅ Backend API is functional
- ✅ WebSocket connectivity works
- ✅ Authentication/authorization enforced
- ✅ Message routing operational
- ✅ Encryption preserved (zero-knowledge)
- ✅ Error handling robust
- ✅ Performance meets targets (<400ms)
- ✅ Reconnection logic works
- ✅ Offline queue functional

**System is PRODUCTION READY if all tests pass.**
