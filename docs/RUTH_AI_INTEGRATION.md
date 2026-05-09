# Ruth-AI Integration Guide

This document provides guidance for integrating Ruth-AI with VAS-MS (Video Aggregation Service - MediaSoup).

## Overview of Changes

VAS-MS has significant architectural differences from the old VAS API:

### Authentication Changes
- **Old VAS**: JWT-based authentication with login endpoints
- **New VAS-MS**: API key authentication via `X-API-Key` header
- **Impact**: Ruth-AI needs to use API keys instead of JWT tokens

### Streaming Architecture Changes
- **Old VAS**: Peer-to-peer WebRTC with SDP offer/answer exchange
- **New VAS-MS**: MediaSoup SFU (Selective Forwarding Unit) architecture
- **Impact**: Connection flow is different - clients connect to MediaSoup via WebSocket

### New Features in VAS-MS
- **Historical Recordings**: Continuous HLS recording with 1-hour rolling buffer
- **Bookmarks**: Capture 6-second clips from historical footage
- **Snapshots**: Capture still images from live or historical streams
- **MediaSoup SFU**: Better performance and scalability for multiple viewers

## API Key Management

### Creating API Keys

#### Method 1: Using the API
```bash
curl -X POST http://localhost:8080/api/v1/auth/api-keys \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Ruth-AI Integration",
    "description": "API key for Ruth-AI to connect to VAS-MS"
  }'
```

Response:
```json
{
  "id": "84d61d57-3d6b-4fdd-a615-c6c7076a609b",
  "key": "6db9ae0dd96d7f388d2e1bd6631b000c2863ba4bb34c20c56c0370b984d3b254",
  "name": "Ruth-AI Integration",
  "description": "API key for Ruth-AI to connect to VAS-MS",
  "is_active": true,
  "expires_at": null,
  "created_at": "2025-11-18T14:04:15.207373Z"
}
```

**IMPORTANT**: The `key` field is only shown once during creation. Store it securely!

#### Method 2: Using the CLI Tool
```bash
# Inside the backend container
docker exec vas-backend python scripts/manage_api_keys.py create \
  --name "Ruth-AI Integration" \
  --description "API key for Ruth-AI"

# List all API keys
docker exec vas-backend python scripts/manage_api_keys.py list

# Revoke an API key
docker exec vas-backend python scripts/manage_api_keys.py revoke <api_key_id>

# Show API key details
docker exec vas-backend python scripts/manage_api_keys.py show <api_key_id>
```

### Using API Keys

Include the API key in all requests using the `X-API-Key` header:

```bash
curl -H "X-API-Key: YOUR_API_KEY_HERE" \
  http://localhost:8080/api/v1/devices
```

### Disabling Authentication (Development Only)

Set `VAS_REQUIRE_AUTH=false` in environment variables to disable authentication:

```yaml
# docker-compose.yml
environment:
  VAS_REQUIRE_AUTH: "false"  # Disable auth for development
```

## API Endpoint Mapping

### Device Management

| Old VAS Endpoint | New VAS-MS Endpoint | Compatibility Endpoint | Notes |
|------------------|---------------------|------------------------|-------|
| `GET /api/devices` | `GET /api/v1/devices` | `GET /api/devices` | List all devices |
| `GET /api/devices/{id}` | `GET /api/v1/devices/{id}` | `GET /api/devices/{id}` | Get device details |
| `POST /api/devices` | `POST /api/v1/devices` | ❌ Not implemented | Create device |
| `PUT /api/devices/{id}` | `PUT /api/v1/devices/{id}` | ❌ Not implemented | Update device |
| `DELETE /api/devices/{id}` | `DELETE /api/v1/devices/{id}` | ❌ Not implemented | Delete device |
| `POST /api/devices/validate` | `POST /api/v1/devices/validate` | ✅ Implemented | Validate RTSP URL |
| ❌ Not in old VAS | `GET /api/v1/devices/{id}/status` | ✅ Implemented | Get device + streaming status |

### Streaming

| Old VAS Endpoint | New VAS-MS Endpoint | Compatibility Endpoint | Notes |
|------------------|---------------------|------------------------|-------|
| `POST /api/devices/{id}/stream` | `POST /api/v1/devices/{id}/start-stream` | `POST /api/devices/{id}/stream` | Start stream (different flow!) |
| `DELETE /api/devices/{id}/stream` | `POST /api/v1/devices/{id}/stop-stream` | `DELETE /api/devices/{id}/stream` | Stop stream |
| `GET /api/streams` | ❌ Not direct equivalent | `GET /api/streams` | List active streams |

### Recordings (New in VAS-MS)

| Endpoint | Description |
|----------|-------------|
| `GET /api/v1/recordings/devices/{device_id}/playlist` | Get HLS playlist for historical recordings |
| `GET /api/v1/recordings/devices/{device_id}/dates` | Get list of dates with available recordings |
| `GET /api/v1/recordings/devices/{device_id}/{segment_name}` | Get recording segment file |

### Bookmarks (New in VAS-MS)

| Endpoint | Description |
|----------|-------------|
| `POST /api/v1/bookmarks/devices/{device_id}/capture/live` | Capture 6-second bookmark from live stream (last 6 seconds) |
| `POST /api/v1/bookmarks/devices/{device_id}/capture/historical` | Capture 6-second bookmark from historical footage (±3s from center timestamp) |
| `GET /api/v1/bookmarks` | List all bookmarks (supports filtering by device_id, pagination) |
| `GET /api/v1/bookmarks/{bookmark_id}` | Get bookmark details |
| `GET /api/v1/bookmarks/{bookmark_id}/video` | Download bookmark video file (MP4) |
| `GET /api/v1/bookmarks/{bookmark_id}/thumbnail` | Get bookmark thumbnail image |
| `PUT /api/v1/bookmarks/{bookmark_id}` | Update bookmark label |
| `DELETE /api/v1/bookmarks/{bookmark_id}` | Delete bookmark and associated files |

### Snapshots (New in VAS-MS)

| Endpoint | Description |
|----------|-------------|
| `POST /api/v1/snapshots/devices/{device_id}/capture/live` | Capture snapshot from live RTSP stream |
| `POST /api/v1/snapshots/devices/{device_id}/capture/historical` | Capture snapshot from historical recordings at specific timestamp |
| `GET /api/v1/snapshots` | List all snapshots (supports filtering by device_id) |
| `GET /api/v1/snapshots/{snapshot_id}` | Get snapshot details |
| `GET /api/v1/snapshots/{snapshot_id}/image` | Download snapshot image (JPEG) |
| `DELETE /api/v1/snapshots/{snapshot_id}` | Delete snapshot and image file |

### API Key Management

| Endpoint | Description |
|----------|-------------|
| `POST /api/v1/auth/api-keys` | Create a new API key |
| `GET /api/v1/auth/api-keys` | List all API keys (supports include_inactive param) |
| `GET /api/v1/auth/api-keys/{key_id}` | Get specific API key details |
| `DELETE /api/v1/auth/api-keys/{key_id}` | Revoke (deactivate) an API key |
| `POST /api/v1/auth/api-keys/{key_id}/activate` | Reactivate a previously revoked API key |

## Streaming Architecture Differences

### Old VAS (Peer-to-Peer WebRTC)

1. Client sends SDP offer to server
2. Server creates peer connection and responds with SDP answer
3. ICE candidates are exchanged
4. Direct peer-to-peer connection established

### New VAS-MS (MediaSoup SFU)

1. Client calls `POST /api/devices/{id}/stream` to start stream
2. Server responds with MediaSoup connection details:
   ```json
   {
     "status": "success",
     "stream_id": "device-uuid",
     "room_id": "device-uuid",
     "websocket_url": "ws://10.30.250.245:8080/ws/mediasoup",
     "mediasoup_url": "ws://10.30.250.245:3001",
     "connection_info": {
       "type": "mediasoup",
       "instructions": "Connect to websocket_url using mediasoup-client library"
     }
   }
   ```
3. Client connects to WebSocket URL using mediasoup-client library
4. Client creates a consumer to receive the video stream
5. Multiple clients can consume the same producer (better scalability)

### Code Changes Required in Ruth-AI

**Old approach (won't work with VAS-MS):**
```javascript
// This won't work with MediaSoup!
const response = await fetch('/api/devices/{id}/stream', {
  method: 'POST',
  body: JSON.stringify({ offer: sdpOffer })
});
const { answer } = await response.json();
peerConnection.setRemoteDescription(answer);
```

**New approach (MediaSoup):**
```javascript
// 1. Start the stream
const response = await fetch('/api/devices/{id}/stream', {
  method: 'POST',
  headers: { 'X-API-Key': 'YOUR_API_KEY' }
});
const { websocket_url, room_id } = await response.json();

// 2. Connect to MediaSoup via WebSocket
import { Device } from 'mediasoup-client';
const device = new Device();

const ws = new WebSocket(websocket_url);
// ... MediaSoup client connection flow
// See: https://mediasoup.org/documentation/v3/mediasoup-client/
```

## Migration Path

### Option 1: Update Ruth-AI to use MediaSoup (Recommended)

**Pros:**
- Better performance and scalability
- Access to new features (historical recordings, bookmarks)
- Future-proof architecture

**Cons:**
- Requires code changes in Ruth-AI
- Need to integrate mediasoup-client library

**Steps:**
1. Install mediasoup-client: `npm install mediasoup-client`
2. Replace WebRTC peer connection code with MediaSoup client code
3. Update API calls to use API key authentication
4. Test with VAS-MS

### Option 2: Use Compatibility Endpoints (Temporary)

**Pros:**
- Minimal code changes
- Quick integration

**Cons:**
- Still requires MediaSoup client library on frontend
- Doesn't fully replicate old VAS behavior
- Not recommended for long-term use

**Steps:**
1. Update Ruth-AI to use `/api/devices` instead of `/api/v1/devices`
2. Add `X-API-Key` header to all requests
3. Update streaming code to use MediaSoup (still required!)

## Example Integration

### Device Validation
```bash
# Validate RTSP URL before adding device
curl -X POST http://localhost:8080/api/v1/devices/validate \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Camera",
    "rtsp_url": "rtsp://root:password@172.16.16.123/live1s1.sdp"
  }'
```

Response:
```json
{
  "valid": true,
  "rtsp_url": "rtsp://root:password@172.16.16.123/live1s1.sdp",
  "ssrc": 2222314122,
  "message": "Device validated successfully"
}
```

### Get Device Status
```bash
curl -H "X-API-Key: YOUR_API_KEY" \
  http://localhost:8080/api/v1/devices/{device_id}/status
```

Response:
```json
{
  "device_id": "838fe284-8507-4465-80fe-28177359be2c",
  "name": "Warehouse camera 123",
  "rtsp_url": "rtsp://root:password@172.16.16.123/live1s1.sdp",
  "is_active": true,
  "streaming": {
    "active": false,
    "room_id": null,
    "started_at": null
  }
}
```

### Access Historical Recordings
```bash
# Get available recording dates
curl -H "X-API-Key: YOUR_API_KEY" \
  http://localhost:8080/api/v1/recordings/devices/{device_id}/dates

# Get HLS playlist for playback
curl -H "X-API-Key: YOUR_API_KEY" \
  http://localhost:8080/api/v1/recordings/devices/{device_id}/playlist
```

Response (dates):
```json
{
  "status": "success",
  "device_id": "838fe284-8507-4465-80fe-28177359be2c",
  "dates": [
    {
      "date": "20251118",
      "formatted": "2025-11-18",
      "segments_count": 450
    },
    {
      "date": "20251117",
      "formatted": "2025-11-17",
      "segments_count": 600
    }
  ]
}
```

### Capture Snapshot from Live Stream
```bash
curl -X POST -H "X-API-Key: YOUR_API_KEY" \
  http://localhost:8080/api/v1/snapshots/devices/{device_id}/capture/live
```

Response:
```json
{
  "status": "success",
  "snapshot": {
    "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "device_id": "838fe284-8507-4465-80fe-28177359be2c",
    "timestamp": "2025-11-18T14:30:00.123456Z",
    "source": "live",
    "file_size": 245678,
    "url": "/api/v1/snapshots/a1b2c3d4-e5f6-7890-abcd-ef1234567890/image"
  }
}
```

### Capture Snapshot from Historical Footage
```bash
curl -X POST -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"timestamp": "2025-11-18T14:30:00"}' \
  http://localhost:8080/api/v1/snapshots/devices/{device_id}/capture/historical
```

### Create Bookmark from Live Stream
```bash
# Capture last 6 seconds from live stream
curl -X POST -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"label": "Detected anomaly at warehouse entrance"}' \
  http://localhost:8080/api/v1/bookmarks/devices/{device_id}/capture/live
```

Response:
```json
{
  "status": "success",
  "bookmark": {
    "id": "b1c2d3e4-f5a6-7890-bcde-f12345678901",
    "device_id": "838fe284-8507-4465-80fe-28177359be2c",
    "device_name": "Warehouse camera 123",
    "center_timestamp": "2025-11-18T14:30:03.000Z",
    "start_timestamp": "2025-11-18T14:30:00.000Z",
    "end_timestamp": "2025-11-18T14:30:06.000Z",
    "label": "Detected anomaly at warehouse entrance",
    "source": "live",
    "duration": 6.0,
    "file_size": 1245678,
    "video_url": "/api/v1/bookmarks/b1c2d3e4-f5a6-7890-bcde-f12345678901/video",
    "thumbnail_url": "/api/v1/bookmarks/b1c2d3e4-f5a6-7890-bcde-f12345678901/thumbnail"
  }
}
```

### Create Bookmark from Historical Footage
```bash
# Capture 6-second clip centered at specific timestamp (±3 seconds)
curl -X POST -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "center_timestamp": "2025-11-18T14:30:00",
    "label": "Person entered restricted area"
  }' \
  http://localhost:8080/api/v1/bookmarks/devices/{device_id}/capture/historical
```

### List All Bookmarks
```bash
# List all bookmarks
curl -H "X-API-Key: YOUR_API_KEY" \
  http://localhost:8080/api/v1/bookmarks

# Filter by device and paginate
curl -H "X-API-Key: YOUR_API_KEY" \
  "http://localhost:8080/api/v1/bookmarks?device_id={device_id}&skip=0&limit=20"
```

Response:
```json
{
  "bookmarks": [
    {
      "id": "b1c2d3e4-f5a6-7890-bcde-f12345678901",
      "device_id": "838fe284-8507-4465-80fe-28177359be2c",
      "device_name": "Warehouse camera 123",
      "center_timestamp": "2025-11-18T14:30:03.000Z",
      "start_timestamp": "2025-11-18T14:30:00.000Z",
      "end_timestamp": "2025-11-18T14:30:06.000Z",
      "label": "Detected anomaly at warehouse entrance",
      "source": "historical",
      "duration": 6.0,
      "file_size": 1245678,
      "created_at": "2025-11-18T14:35:00.000Z",
      "video_url": "/api/v1/bookmarks/b1c2d3e4-f5a6-7890-bcde-f12345678901/video",
      "thumbnail_url": "/api/v1/bookmarks/b1c2d3e4-f5a6-7890-bcde-f12345678901/thumbnail"
    }
  ],
  "total": 45,
  "page": 1,
  "page_size": 20
}
```

### Download Bookmark Video
```bash
# Download the 6-second video clip
curl -H "X-API-Key: YOUR_API_KEY" \
  -o bookmark.mp4 \
  http://localhost:8080/api/v1/bookmarks/{bookmark_id}/video
```

### List All Snapshots
```bash
# List all snapshots
curl -H "X-API-Key: YOUR_API_KEY" \
  http://localhost:8080/api/v1/snapshots

# Filter by device
curl -H "X-API-Key: YOUR_API_KEY" \
  "http://localhost:8080/api/v1/snapshots?device_id={device_id}&limit=50"
```

## Historical Feed Integration (Recordings Playback)

VAS-MS automatically records all live streams to disk with a **1-hour rolling buffer** (600 segments at 6 seconds each). This allows Ruth-AI to:
- Play back historical footage
- Review past events
- Create bookmarks and snapshots from historical data
- Access recordings by date

### How Historical Recording Works

```
┌──────────────────────────────────────────────────────────┐
│ Automatic Recording Process                              │
├──────────────────────────────────────────────────────────┤
│                                                           │
│  1. Stream starts → Recording begins automatically       │
│  2. FFmpeg creates HLS segments (6 seconds each)         │
│  3. Segments stored in /recordings/hot/{device_id}/      │
│  4. Organized by date: YYYYMMDD/segment_XXX.ts          │
│  5. Rolling buffer: Keeps last 600 segments (~1 hour)   │
│  6. Old segments auto-deleted when buffer is full        │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

### Recording Structure

```
/recordings/hot/
└── {device_id}/
    ├── stream.m3u8              # Master playlist (always current)
    ├── 20251118/                # Today's recordings
    │   ├── segment_001.ts
    │   ├── segment_002.ts
    │   └── segment_600.ts
    └── 20251117/                # Yesterday's recordings
        ├── segment_001.ts
        └── segment_450.ts
```

### Integration Example: Historical Feed Player

#### Step 1: Check Available Recording Dates

```javascript
// Get list of dates with available recordings
const response = await fetch(
  `http://10.30.250.245:8080/api/v1/recordings/devices/${deviceId}/dates`,
  {
    headers: { 'X-API-Key': 'YOUR_API_KEY' }
  }
);

const data = await response.json();
// Response:
// {
//   "status": "success",
//   "device_id": "838fe284-8507-4465-80fe-28177359be2c",
//   "dates": [
//     {"date": "20251118", "formatted": "2025-11-18", "segments_count": 450},
//     {"date": "20251117", "formatted": "2025-11-17", "segments_count": 600}
//   ]
// }
```

#### Step 2: Get HLS Playlist for Playback

```javascript
// Get the HLS playlist URL
const playlistUrl = `http://10.30.250.245:8080/api/v1/recordings/devices/${deviceId}/playlist`;

// Option A: Use HLS.js for web playback
import Hls from 'hls.js';

const video = document.getElementById('video');
if (Hls.isSupported()) {
  const hls = new Hls({
    xhrSetup: (xhr) => {
      // Add API key if authentication is enabled
      xhr.setRequestHeader('X-API-Key', 'YOUR_API_KEY');
    }
  });

  hls.loadSource(playlistUrl);
  hls.attachMedia(video);

  hls.on(Hls.Events.MANIFEST_PARSED, () => {
    video.play();
  });
}

// Option B: Native HLS support (Safari, iOS)
else if (video.canPlayType('application/vnd.apple.mpegurl')) {
  video.src = playlistUrl;
  video.addEventListener('loadedmetadata', () => {
    video.play();
  });
}
```

#### Step 3: Timeline Navigation

```javascript
// HLS.js provides timeline controls
const duration = hls.media.duration;  // Total recording duration in seconds
const currentTime = hls.media.currentTime;  // Current playback position

// Seek to specific time (e.g., 30 minutes ago)
video.currentTime = duration - (30 * 60);

// Seek to specific timestamp
const targetDate = new Date('2025-11-18T14:30:00');
const recordingStart = new Date(data.dates[0].formatted);
const offset = (targetDate - recordingStart) / 1000;  // seconds
video.currentTime = offset;
```

#### Step 4: Create Bookmark from Historical Moment

```javascript
// When user sees something interesting in historical feed
async function createBookmarkAtCurrentTime() {
  const currentTimestamp = new Date(
    recordingStart.getTime() + (video.currentTime * 1000)
  );

  const response = await fetch(
    `http://10.30.250.245:8080/api/v1/bookmarks/devices/${deviceId}/capture/historical`,
    {
      method: 'POST',
      headers: {
        'X-API-Key': 'YOUR_API_KEY',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        center_timestamp: currentTimestamp.toISOString(),
        label: 'Event detected during review'
      })
    }
  );

  const bookmark = await response.json();
  // Bookmark contains 6-second clip (±3s from timestamp)
  // Can be downloaded via bookmark.video_url
}
```

#### Step 5: Capture Snapshot from Historical Feed

```javascript
async function captureSnapshotAtCurrentTime() {
  const currentTimestamp = new Date(
    recordingStart.getTime() + (video.currentTime * 1000)
  );

  const response = await fetch(
    `http://10.30.250.245:8080/api/v1/snapshots/devices/${deviceId}/capture/historical`,
    {
      method: 'POST',
      headers: {
        'X-API-Key': 'YOUR_API_KEY',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        timestamp: currentTimestamp.toISOString()
      })
    }
  );

  const snapshot = await response.json();
  // Snapshot image can be accessed via snapshot.url
}
```

### Complete Ruth-AI Integration Example

```javascript
import Hls from 'hls.js';
import { Device } from 'mediasoup-client';

class VASMSClient {
  constructor(apiUrl, apiKey) {
    this.apiUrl = apiUrl;
    this.apiKey = apiKey;
  }

  // ============================================
  // LIVE FEED (MediaSoup WebRTC)
  // ============================================
  async startLiveStream(deviceId) {
    // Start the stream
    const response = await fetch(
      `${this.apiUrl}/api/v1/devices/${deviceId}/start-stream`,
      {
        method: 'POST',
        headers: { 'X-API-Key': this.apiKey }
      }
    );

    const { websocket_url, room_id } = await response.json();

    // Connect via MediaSoup (see RUTH_AI_CLARIFICATION.md for full flow)
    const device = new Device();
    const ws = new WebSocket(websocket_url);
    // ... MediaSoup connection setup

    return { device, ws, room_id };
  }

  // ============================================
  // HISTORICAL FEED (HLS Playback)
  // ============================================
  async loadHistoricalFeed(deviceId, videoElement) {
    // Get available dates
    const datesResponse = await fetch(
      `${this.apiUrl}/api/v1/recordings/devices/${deviceId}/dates`,
      { headers: { 'X-API-Key': this.apiKey } }
    );
    const { dates } = await datesResponse.json();

    if (!dates || dates.length === 0) {
      throw new Error('No recordings available');
    }

    // Load HLS playlist
    const playlistUrl = `${this.apiUrl}/api/v1/recordings/devices/${deviceId}/playlist`;

    const hls = new Hls({
      xhrSetup: (xhr) => {
        xhr.setRequestHeader('X-API-Key', this.apiKey);
      }
    });

    hls.loadSource(playlistUrl);
    hls.attachMedia(videoElement);

    return { hls, dates };
  }

  // ============================================
  // BOOKMARKS & SNAPSHOTS
  // ============================================
  async createBookmark(deviceId, timestamp, label) {
    const response = await fetch(
      `${this.apiUrl}/api/v1/bookmarks/devices/${deviceId}/capture/historical`,
      {
        method: 'POST',
        headers: {
          'X-API-Key': this.apiKey,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          center_timestamp: timestamp,
          label: label
        })
      }
    );

    return await response.json();
  }

  async getBookmarks(deviceId) {
    const response = await fetch(
      `${this.apiUrl}/api/v1/bookmarks?device_id=${deviceId}`,
      { headers: { 'X-API-Key': this.apiKey } }
    );

    return await response.json();
  }
}

// Usage in Ruth-AI:
const client = new VASMSClient('http://10.30.250.245:8080', 'YOUR_API_KEY');

// Show live feed
const liveVideo = document.getElementById('live-video');
await client.startLiveStream(deviceId);

// Show historical feed
const historicalVideo = document.getElementById('historical-video');
const { hls, dates } = await client.loadHistoricalFeed(deviceId, historicalVideo);

// Create bookmark when AI detects event in historical review
await client.createBookmark(
  deviceId,
  '2025-11-18T14:30:00',
  'Anomaly detected by Ruth-AI during review'
);
```

### Key Differences: Live vs Historical Feed

| Feature | Live Feed (WebRTC) | Historical Feed (HLS) |
|---------|-------------------|----------------------|
| **Protocol** | MediaSoup WebRTC | HLS (HTTP Live Streaming) |
| **Latency** | Low (~200-500ms) | Higher (~5-10 seconds) |
| **Integration** | mediasoup-client | HLS.js or native |
| **Use Case** | Real-time monitoring | Review past events |
| **Playback Controls** | Not applicable | Seek, pause, rewind |
| **Bookmarks** | Last 6 seconds only | Any point in history |
| **Data Retention** | N/A (not recorded) | 1 hour rolling buffer |

### Recording Retention and Management

**Default Configuration:**
- **Retention**: 600 segments (1 hour at 6 seconds each)
- **Storage Location**: `/recordings/hot/{device_id}/`
- **Auto-cleanup**: Old segments deleted when buffer full
- **Format**: HLS (MPEG-TS segments + M3U8 playlist)

**To check recording status:**
```bash
# Check if recordings exist
curl http://10.30.250.245:8080/api/v1/recordings/devices/{device_id}/dates

# Check device streaming status
curl http://10.30.250.245:8080/api/v1/devices/{device_id}/status
```

**Storage requirements:**
- 1080p @ 2 Mbps: ~900 MB per hour per camera
- 720p @ 1 Mbps: ~450 MB per hour per camera
- 480p @ 500 Kbps: ~225 MB per hour per camera

### Troubleshooting Historical Feed

**Problem**: "No recordings available"
```bash
# Check if device is/was streaming
curl http://10.30.250.245:8080/api/v1/devices/{device_id}/status

# Verify recording directory exists
docker exec vas-backend ls -lh /recordings/hot/{device_id}/
```

**Problem**: "HLS playback not working"
```javascript
// Enable HLS.js debug mode
const hls = new Hls({
  debug: true,
  xhrSetup: (xhr) => {
    xhr.setRequestHeader('X-API-Key', 'YOUR_API_KEY');
  }
});
```

**Problem**: "Segments not found"
- Check that stream was running at the requested time
- Verify segments haven't been rotated out (1 hour retention)
- Check recording dates endpoint for available timeframes

## Configuration

### Backend Environment Variables

```yaml
# docker-compose.yml
environment:
  # Authentication
  VAS_REQUIRE_AUTH: "true"              # Enable/disable API key auth
  VAS_API_KEY: "default_api_key_here"   # Default API key (optional)

  # MediaSoup
  MEDIASOUP_HOST_IP: "10.30.250.245"    # Host IP for MediaSoup
  MEDIASOUP_URL: "ws://10.30.250.245:3001"
  BACKEND_HOST: "10.30.250.245:8080"

  # Recording
  RECORDING_RETENTION_SEGMENTS: "600"   # Keep 600 segments (~1 hour)

  # Database
  DATABASE_URL: "postgresql://vas:vas_password@db:5432/vas_db"
```

## Troubleshooting

### Authentication Errors

**Error**: `401 Unauthorized - API key required`
- Ensure you're including the `X-API-Key` header in requests
- Verify the API key is active: `docker exec vas-backend python scripts/manage_api_keys.py list`

**Error**: `403 Forbidden - Invalid or expired API key`
- Check if the API key is still active
- Verify you're using the correct key value

### Streaming Issues

**Error**: `Failed to capture SSRC from RTSP source`
- Check if the RTSP URL is correct and reachable
- Verify FFmpeg is installed: `docker exec vas-backend ffmpeg -version`
- Check network connectivity to the camera

**Error**: WebSocket connection rejected
- Verify `/socket.io` and `/ws` paths are exempt from auth in middleware
- Check backend logs: `docker logs vas-backend`

### Recording Issues

**No recordings available**
- Recordings start automatically when a device stream is started
- Check if device is streaming: `GET /api/v1/devices/{id}/status`
- Verify recording path exists: `docker exec vas-backend ls /recordings/hot/{device_id}`

## Support

For issues or questions:
- Check backend logs: `docker logs vas-backend --tail 100 -f`
- Check MediaSoup logs: `docker logs vas-mediasoup --tail 100 -f`
- Review API documentation: http://localhost:8080/docs
- File issues at: https://github.com/your-org/vas-ms/issues

## Complete API Endpoint Reference

### Quick Reference: All Available Endpoints

#### Device Management
- `POST /api/v1/devices` - Create new device
- `GET /api/v1/devices` - List all devices
- `GET /api/v1/devices/{id}` - Get device details
- `PUT /api/v1/devices/{id}` - Update device
- `DELETE /api/v1/devices/{id}` - Delete device
- `POST /api/v1/devices/validate` - Validate RTSP URL without saving
- `GET /api/v1/devices/{id}/status` - Get device status with streaming state
- `POST /api/v1/devices/{id}/start-stream` - Start WebRTC stream
- `POST /api/v1/devices/{id}/stop-stream` - Stop stream

#### Legacy Compatibility Endpoints
- `GET /api/devices` - List devices (old VAS format)
- `GET /api/devices/{id}` - Get device (old VAS format)
- `POST /api/devices/{id}/stream` - Start stream (MediaSoup)
- `DELETE /api/devices/{id}/stream` - Stop stream
- `GET /api/streams` - List active streams

#### Recordings & Historical Footage
- `GET /api/v1/recordings/devices/{device_id}/playlist` - Get HLS playlist
- `GET /api/v1/recordings/devices/{device_id}/dates` - List available recording dates
- `GET /api/v1/recordings/devices/{device_id}/{segment}` - Get HLS segment
- `POST /api/v1/recordings/streams/{stream_id}/start` - Start recording
- `POST /api/v1/recordings/streams/{stream_id}/stop` - Stop recording
- `GET /api/v1/recordings/streams/{stream_id}` - Get recording info

#### Bookmarks (6-second clips)
- `POST /api/v1/bookmarks/devices/{device_id}/capture/live` - Capture from live stream
- `POST /api/v1/bookmarks/devices/{device_id}/capture/historical` - Capture from history
- `GET /api/v1/bookmarks` - List all bookmarks
- `GET /api/v1/bookmarks/{id}` - Get bookmark details
- `GET /api/v1/bookmarks/{id}/video` - Download video (MP4)
- `GET /api/v1/bookmarks/{id}/thumbnail` - Get thumbnail image
- `PUT /api/v1/bookmarks/{id}` - Update label
- `DELETE /api/v1/bookmarks/{id}` - Delete bookmark

#### Snapshots (still images)
- `POST /api/v1/snapshots/devices/{device_id}/capture/live` - Capture from live
- `POST /api/v1/snapshots/devices/{device_id}/capture/historical` - Capture from history
- `GET /api/v1/snapshots` - List all snapshots
- `GET /api/v1/snapshots/{id}` - Get snapshot details
- `GET /api/v1/snapshots/{id}/image` - Download image (JPEG)
- `DELETE /api/v1/snapshots/{id}` - Delete snapshot

#### API Key Management
- `POST /api/v1/auth/api-keys` - Create new API key
- `GET /api/v1/auth/api-keys` - List API keys
- `GET /api/v1/auth/api-keys/{id}` - Get key details
- `DELETE /api/v1/auth/api-keys/{id}` - Revoke key
- `POST /api/v1/auth/api-keys/{id}/activate` - Reactivate key

#### System Health
- `GET /health` - Basic health check
- `GET /health/detailed` - Detailed health status
- `GET /` - API information
- `GET /docs` - Interactive API documentation (Swagger UI)

## Additional Resources

- [MediaSoup Client API](https://mediasoup.org/documentation/v3/mediasoup-client/api/)
- [MediaSoup Client Installation](https://mediasoup.org/documentation/v3/mediasoup-client/installation/)
- [FastAPI Documentation](https://fastapi.tiangolo.com/)
- [HLS Streaming Guide](https://developer.apple.com/streaming/)
- [Interactive API Docs](http://localhost:8080/docs) - Test endpoints directly in browser
