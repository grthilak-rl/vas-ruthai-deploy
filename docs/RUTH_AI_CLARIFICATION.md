# VAS-MS Architecture Clarification for Ruth-AI Team

## Summary: The Issues Are Integration Errors, Not VAS-MS Bugs

The reported issues stem from **incorrect assumptions about VAS-MS architecture**. Ruth-AI is trying to use VAS-MS like the old peer-to-peer VAS, but VAS-MS uses a fundamentally different **MediaSoup SFU architecture**.

## The Root Misunderstanding

### What Ruth-AI Is Expecting (Old VAS - WRONG for VAS-MS)
```javascript
// ❌ INCORRECT - This is how OLD VAS worked
const response = await fetch('/api/devices/{id}/stream', {method: 'POST'});
const data = await response.json();

// Ruth-AI expects server to create WebRTC transport and return:
// - DTLS fingerprints (for server-side WebRTC peer)
// - ICE candidates (for server-side WebRTC peer)
// - SDP offer/answer exchange
```

### How VAS-MS Actually Works (MediaSoup SFU - CORRECT)
```javascript
// ✅ CORRECT - This is how VAS-MS works
// Step 1: Start the server-side pipeline (RTSP → MediaSoup)
const response = await fetch('/api/v1/devices/{id}/start-stream', {method: 'POST'});
const { room_id, websocket_url } = await response.json();

// Step 2: Client connects to MediaSoup via WebSocket
import { Device } from 'mediasoup-client';
const device = new Device();
const ws = new WebSocket(websocket_url);

// Step 3: Client creates its own WebRTC transport
// Step 4: Client creates consumer to receive stream
```

## Why VAS-MS Doesn't Return DTLS/ICE in start-stream Response

### The Architecture:

```
┌─────────────────────────────────────────────────────────────────┐
│                          VAS-MS Server                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  RTSP Camera                                                    │
│      │                                                          │
│      │ RTSP                                                     │
│      ▼                                                          │
│  ┌────────┐         RTP          ┌─────────────┐                │
│  │ FFmpeg ├─────────────────────►│  MediaSoup  │                │
│  └────────┘                      │  (PlainRTP  │                │
│                                  │  Transport) │                │
│                                  └──────┬──────┘                │
│                                         │                       │
│                                         │ WebSocket             │
└─────────────────────────────────────────┼───────────────────────┘
                                          │
                                          │ WebSocket Signaling
                                          │
                                          ▼
                          ┌───────────────────────────┐
                          │     Ruth-AI Client        │
                          │   (mediasoup-client)      │
                          │                           │
                          │  Creates WebRTC Transport │
                          │  (with its own DTLS/ICE)  │
                          └───────────────────────────┘
```

### Key Points:

1. **PlainRTP Transport (Server-Side)**:
   - Created by `POST /api/v1/devices/{id}/start-stream`
   - Used for FFmpeg → MediaSoup communication
   - **Does NOT use WebRTC** (no DTLS, no ICE)
   - Uses plain RTP over UDP
   - **This is why there are no DTLS fingerprints or ICE candidates**

2. **WebRTC Transport (Client-Side)**:
   - Created by Ruth-AI client using `mediasoup-client` library
   - Connects to MediaSoup via WebSocket
   - **Client generates its own DTLS fingerprints and ICE candidates**
   - MediaSoup server responds with its DTLS/ICE during signaling

## The Reported "Issues" Explained

### Issue 1: "Empty DTLS Fingerprints"
**Status**: ❌ Not a bug - Architectural misunderstanding

**Explanation**:
- The `start-stream` endpoint creates a **PlainRTP transport** for FFmpeg
- PlainRTP transports don't use DTLS (they're not WebRTC)
- DTLS is only used when the **client** creates a WebRTC transport via WebSocket
- The client receives DTLS fingerprints during WebSocket signaling, not REST API

**What Ruth-AI Should Do**:
Don't expect DTLS from REST API. Use mediasoup-client to create WebRTC transport via WebSocket.

### Issue 2: "Empty ICE Candidates"
**Status**: ❌ Not a bug - Architectural misunderstanding

**Explanation**:
- PlainRTP transports don't use ICE (no NAT traversal needed for server-local FFmpeg)
- ICE candidates are exchanged during **client-side WebRTC transport creation**
- MediaSoup returns ICE candidates via WebSocket, not REST API

**What Ruth-AI Should Do**:
Don't expect ICE from REST API. Use mediasoup-client to handle ICE via WebSocket.

### Issue 3: "REST API vs WebSocket Signaling"
**Status**: ❌ Integration error - Ruth-AI using wrong approach

**Explanation**:
- VAS-MS **does provide WebSocket endpoint**: `ws://10.30.250.245:8080/ws/mediasoup`
- Ruth-AI should connect to this WebSocket, not make REST API calls for signaling
- The `start-stream` REST API only starts the server-side pipeline
- All MediaSoup signaling happens via WebSocket using `mediasoup-client`

**What Ruth-AI Should Do**:
Stop making REST API calls for MediaSoup operations. Use the WebSocket endpoint with mediasoup-client library.

### Issue 4: "Snake_case vs camelCase"
**Status**: ⚠️ Minor - Can be handled by Ruth-AI client

**Explanation**:
- VAS-MS returns snake_case (Python convention)
- MediaSoup client expects camelCase (JavaScript convention)
- This is normal for Python backends with JS clients
- Ruth-AI can convert between formats, or mediasoup-client might handle it

**What Ruth-AI Should Do**:
Use mediasoup-client which handles the communication protocol properly.

## Correct Integration Flow

### Step-by-Step Guide for Ruth-AI:

```javascript
// ═══════════════════════════════════════════════════════════════
// STEP 1: Install mediasoup-client
// ═══════════════════════════════════════════════════════════════
// npm install mediasoup-client

import { Device } from 'mediasoup-client';

// ═══════════════════════════════════════════════════════════════
// STEP 2: Start the server-side stream (REST API)
// ═══════════════════════════════════════════════════════════════
async function startStream(deviceId) {
  const response = await fetch(`http://10.30.250.245:8080/api/v1/devices/${deviceId}/start-stream`, {
    method: 'POST',
    headers: {
      'X-API-Key': 'YOUR_API_KEY' // Optional if VAS_REQUIRE_AUTH=false
    }
  });

  const data = await response.json();

  // Response contains:
  // {
  //   "status": "success",
  //   "room_id": "device-uuid",
  //   "websocket_url": "ws://10.30.250.245:8080/ws/mediasoup",
  //   "transport_id": "...",
  //   "producers": { "video": "producer-id" }
  // }

  return data;
}

// ═══════════════════════════════════════════════════════════════
// STEP 3: Connect to MediaSoup via WebSocket
// ═══════════════════════════════════════════════════════════════
async function connectToMediaSoup(websocketUrl, roomId) {
  // Create MediaSoup device
  const device = new Device();

  // Connect to WebSocket
  const ws = new WebSocket(websocketUrl);

  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });

  // ═══════════════════════════════════════════════════════════════
  // STEP 4: Load device with router RTP capabilities
  // ═══════════════════════════════════════════════════════════════
  // Send request to get router capabilities
  ws.send(JSON.stringify({
    type: 'getRouterRtpCapabilities',
    roomId: roomId
  }));

  const routerCapabilities = await new Promise(resolve => {
    ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (data.type === 'routerRtpCapabilities') {
        resolve(data.capabilities);
      }
    };
  });

  await device.load({ routerRtpCapabilities: routerCapabilities });

  // ═══════════════════════════════════════════════════════════════
  // STEP 5: Create WebRTC receive transport (THIS creates DTLS/ICE!)
  // ═══════════════════════════════════════════════════════════════
  ws.send(JSON.stringify({
    type: 'createWebRtcTransport',
    roomId: roomId,
    direction: 'recv'
  }));

  const transportInfo = await new Promise(resolve => {
    ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (data.type === 'transportCreated') {
        resolve(data.transport);
      }
    };
  });

  // NOW you get DTLS fingerprints and ICE candidates!
  // transportInfo contains:
  // {
  //   "id": "transport-id",
  //   "iceParameters": {...},
  //   "iceCandidates": [...],  // ← HERE are your ICE candidates!
  //   "dtlsParameters": {       // ← HERE are your DTLS fingerprints!
  //     "role": "auto",
  //     "fingerprints": [{
  //       "algorithm": "sha-256",
  //       "value": "AB:CD:EF:..."
  //     }]
  //   }
  // }

  const recvTransport = device.createRecvTransport(transportInfo);

  // ═══════════════════════════════════════════════════════════════
  // STEP 6: Connect the transport
  // ═══════════════════════════════════════════════════════════════
  recvTransport.on('connect', ({ dtlsParameters }, callback, errback) => {
    ws.send(JSON.stringify({
      type: 'connectWebRtcTransport',
      transportId: recvTransport.id,
      dtlsParameters: dtlsParameters
    }));

    ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (data.type === 'transportConnected') {
        callback();
      }
    };
  });

  // ═══════════════════════════════════════════════════════════════
  // STEP 7: Create consumer to receive video
  // ═══════════════════════════════════════════════════════════════
  ws.send(JSON.stringify({
    type: 'consume',
    transportId: recvTransport.id,
    producerId: 'video-producer-id', // From step 2 response
    rtpCapabilities: device.rtpCapabilities
  }));

  const consumerInfo = await new Promise(resolve => {
    ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (data.type === 'consumerCreated') {
        resolve(data.consumer);
      }
    };
  });

  const consumer = await recvTransport.consume(consumerInfo);

  // ═══════════════════════════════════════════════════════════════
  // STEP 8: Display video in HTML
  // ═══════════════════════════════════════════════════════════════
  const stream = new MediaStream([consumer.track]);
  const videoElement = document.getElementById('video');
  videoElement.srcObject = stream;
  videoElement.play();
}

// ═══════════════════════════════════════════════════════════════
// Usage
// ═══════════════════════════════════════════════════════════════
const { room_id, websocket_url } = await startStream('device-uuid');
await connectToMediaSoup(websocket_url, room_id);
```

## What VAS-MS Actually Returns (And Why It's Correct)

### Response from `POST /api/v1/devices/{id}/start-stream`:

```json
{
  "status": "success",
  "device_id": "838fe284-8507-4465-80fe-28177359be2c",
  "room_id": "838fe284-8507-4465-80fe-28177359be2c",
  "transport_id": "f85a5d3d-4c20-4712-9dfa-ac5676d7ea0b",
  "producers": {
    "video": "producer-id-here"
  },
  "stream": {
    "stream_id": "838fe284-8507-4465-80fe-28177359be2c",
    "status": "active",
    "ffmpeg_pid": 12345
  }
}
```

**Why no DTLS/ICE?**
- This endpoint creates a **PlainRTP transport** for FFmpeg (server-side)
- Not a WebRTC transport (no DTLS/ICE needed)
- Client creates WebRTC transport via WebSocket (gets DTLS/ICE there)

### What Ruth-AI Gets from WebSocket (After connecting):

When Ruth-AI properly uses mediasoup-client and connects via WebSocket, it will receive:

```javascript
// Response from WebSocket createWebRtcTransport message:
{
  "type": "transportCreated",
  "transport": {
    "id": "client-transport-id",
    "iceParameters": {
      "usernameFragment": "abc123",
      "password": "def456"
    },
    "iceCandidates": [
      {
        "foundation": "udpcandidate",
        "priority": 2130706431,
        "ip": "10.30.250.245",
        "port": 40185,
        "type": "host",
        "protocol": "udp"
      }
    ],
    "dtlsParameters": {
      "role": "auto",
      "fingerprints": [
        {
          "algorithm": "sha-256",
          "value": "A1:B2:C3:D4:E5:F6:..." // Real certificate fingerprint
        }
      ]
    },
    "sctpParameters": null
  }
}
```

**This is where Ruth-AI gets DTLS and ICE!** Not from the REST API.

## Action Items for Ruth-AI Team

### ❌ Stop Doing:
1. Expecting DTLS fingerprints from REST API
2. Expecting ICE candidates from REST API
3. Making REST API calls for MediaSoup transport/consumer operations
4. Treating VAS-MS like peer-to-peer WebRTC

### ✅ Start Doing:
1. Install `mediasoup-client` library
2. Use REST API **only** for starting/stopping streams
3. Use WebSocket for all MediaSoup signaling
4. Let mediasoup-client handle transport creation and connection
5. Follow the official MediaSoup client documentation

## Testing VAS-MS is Working Correctly

### Quick Test - Verify WebSocket Endpoint:

```bash
# Test that WebSocket endpoint is available
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: test" \
  http://10.30.250.245:8080/ws/mediasoup
```

Expected: `101 Switching Protocols` response

### Verify Stream is Running:

```bash
# 1. Start a stream
curl -X POST http://10.30.250.245:8080/api/v1/devices/{device_id}/start-stream

# 2. Check device status
curl http://10.30.250.245:8080/api/v1/devices/{device_id}/status

# Should show: "streaming": {"active": true, "room_id": "..."}
```

## Summary

| Issue Reported | Actual Status | Solution |
|----------------|---------------|----------|
| "Empty DTLS fingerprints" | ❌ Not a bug | Use WebSocket, not REST API |
| "Empty ICE candidates" | ❌ Not a bug | Use WebSocket, not REST API |
| "REST API vs WebSocket" | ❌ Integration error | Connect to WebSocket endpoint |
| "Snake_case vs camelCase" | ⚠️ Normal | Use mediasoup-client |

**Bottom Line**: VAS-MS is working correctly. Ruth-AI needs to update their integration to use MediaSoup SFU architecture with the `mediasoup-client` library instead of trying to use it like the old peer-to-peer VAS.

## References

- [MediaSoup Client Documentation](https://mediasoup.org/documentation/v3/mediasoup-client/)
- [MediaSoup Client API](https://mediasoup.org/documentation/v3/mediasoup-client/api/)
- [VAS-MS Integration Guide](./RUTH_AI_INTEGRATION.md)
- VAS-MS WebSocket Endpoint: `ws://10.30.250.245:8080/ws/mediasoup`
- VAS-MS Interactive API Docs: `http://10.30.250.245:8080/docs`
