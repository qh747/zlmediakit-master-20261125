# GLOSSARY

Domain vocabulary for ZLMediaKit. Terms here are the ones this repo actually uses in code and in discussion; when a skill needs to name one of these concepts, use these words.

Keep this file small. Add a term only when it has been the source of a real ambiguity.

## Media plane

**MediaSource**
The abstract base for anything that can be published to and played from: `class MediaSource : public TrackSource, public std::enable_shared_from_this<MediaSource>` (`src/Common/MediaSource.h`). Identified by a schema plus a `MediaTuple`. Concrete subclasses like `RtspMediaSource` own a `RingBuffer` that fans packets out to every attached reader. This is the unit that "a stream" refers to.

**MediaTuple**
The `vhost / app / stream` triple (plus optional `params`) that addresses a `MediaSource`; `shortUrl()` returns `vhost/app/stream`. Not the full URL — schema lives on the `MediaSource` itself.

**Track**
A single audio or video stream inside a `MediaSource`, obtained via `TrackSource::getTracks()` / `getTrack(TrackType)`. Distinguished by `TrackType` (`TrackVideo`, `TrackAudio`). One `MediaSource` normally has one video and/or one audio `Track`.

**TrackSource**
The interface (`src/Extension/Track.h`) exposing `getTracks()` / `getTrack(type)`. `MediaSource` implements it; so does anything that can be read from track-by-track rather than packet-by-packet.

## WebRTC plane

**RtcMedia**
One `m=` section of an SDP: `type`, `mid`, `direction`, codec plans, SSRCs, ICE/DTLS/extmap attributes (`webrtc/Sdp.h`). This is the parsed SDP model, not a live stream.

**mid**
The `a=mid:` label identifying one `RtcMedia` within a session. Under BUNDLE, all `mid`s share a single transport. In this repo `mid` is the stable key that survives source switching, so it is what conference seat slots are addressed by.

**MediaTrack**
The runtime binding between an SDP `RtcMedia` and the packet path (`webrtc/WebRtcTransport.h`). Holds the pointer to `RtcMedia`, answer/offer SSRCs, the send-side `NackList`, and `RtpSwitchCorrector`. One `MediaTrack` per non-application `m=` section.

**rtp_id**
The string on a `MediaTrack` identifying which upstream stream is currently bound to this output track — normally an SSRC. Empty means unbound. Rebinding is how a conference seat is handed from one publisher to another.

**RtpSwitchCorrector**
Maintains a fixed seq/timestamp offset per send-side `MediaTrack` so that swapping the upstream source does not make the receiver's jitter buffer see a jump. Offsets are recomputed only when signalled (`onSourceSwitch`), not inferred from packet discontinuities.

**WebRtcTransportImp**
The shared implementation base for `WebRtcPusher` (recv), `WebRtcPlayer` (send), and `WebRtcTalk`. Owns the SDP pair, the SRTP sessions, and the per-`mid` lookup tables. New transport types are added by subclassing this and registering via `WebRtcPluginManager`.

**WebRtcPluginManager**
The registry mapping a `type` query parameter (e.g. `play`, `push`) to a transport factory. Registration is additive: a new type can be added without touching existing transport code.

## Naming notes

Avoid these:
- "stream" when you mean `MediaSource` — say `MediaSource`.
- "track" when you mean `RtcMedia` — an `RtcMedia` is the SDP section; a `MediaTrack` is the runtime binding; a `Track` is a codec-level stream inside a `MediaSource`. All three are distinct.
- "channel" for anything other than `RtpChannel`, which is the receive-side simulcast/RID path.
