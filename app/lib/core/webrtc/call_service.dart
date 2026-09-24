import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../network/socket_service.dart';

/// WebRTC 1-to-1 calling (audio or video) over DTLS-SRTP, orchestrated by the
/// relay's signaling events. Media flows peer-to-peer; the server only sees
/// SDP/ICE metadata. ICE servers (STUN, optional TURN) are provided in the
/// socket `hello` payload.
class CallService extends ChangeNotifier {
  CallService({required this.socket});

  final SocketService socket;

  CallPhase phase = CallPhase.idle;
  String? callId;
  bool isVideo = false;
  bool incoming = false;
  String? error;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();
  bool renderersReady = false;

  bool micMuted = false;
  bool speakerOn = true;
  bool cameraOff = false;

  List<Map<String, dynamic>> iceServers = const <Map<String, dynamic>>[
    <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
  ];

  VoidCallback? onIncomingCall;

  void updateIceServers(List<Map<String, dynamic>> servers) {
    if (servers.isNotEmpty) iceServers = servers;
  }

  // ---------------------------------------------------------------- flow --

  Future<void> startCall({required bool video}) async {
    if (phase != CallPhase.idle) return;
    callId = DateTime.now().microsecondsSinceEpoch.toString();
    isVideo = video;
    incoming = false;
    phase = CallPhase.dialing;
    error = null;
    notifyListeners();
    try {
      await _preparePeerConnection();
      await _obtainLocalMedia(video);
      final offer = await _pc!.createOffer(<String, dynamic>{
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': video ? 1 : 0,
      });
      await _pc!.setLocalDescription(offer);
      socket.callInvite(callId: callId!, media: video ? 'video' : 'audio');
      socket.rtcOffer(callId!, offer.sdp!);
    } catch (e) {
      error = '$e';
      await endCall(notifyRemote: false);
    }
    notifyListeners();
  }

  Future<void> acceptIncoming() async {
    if (callId == null) return;
    phase = CallPhase.connecting;
    notifyListeners();
    try {
      await _preparePeerConnection();
      await _obtainLocalMedia(isVideo);
      // SDP offer arrived earlier and is buffered in [_pendingOffer].
      if (_pendingOffer != null) {
        await _pc!.setRemoteDescription(RTCSessionDescription(_pendingOffer, 'offer'));
        _drainPendingIce();
        final answer = await _pc!.createAnswer(<String, dynamic>{});
        await _pc!.setLocalDescription(answer);
        socket.callAccept(callId!);
        socket.rtcAnswer(callId!, answer.sdp!);
      }
    } catch (e) {
      error = '$e';
      await endCall();
    }
    notifyListeners();
  }

  Future<void> rejectIncoming() async {
    if (callId != null) socket.callReject(callId!);
    await _teardown();
    notifyListeners();
  }

  Future<void> endCall({bool notifyRemote = true}) async {
    if (notifyRemote && callId != null) socket.callEnd(callId!);
    await _teardown();
    notifyListeners();
  }

  Future<void> toggleMute() async {
    micMuted = !micMuted;
    final track = _localStream?.getAudioTracks();
    for (final t in track ?? <MediaStreamTrack>[]) {
      t.enabled = !micMuted;
    }
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    if (!isVideo) return;
    cameraOff = !cameraOff;
    for (final t in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !cameraOff;
    }
    notifyListeners();
  }

  // ------------------------------------------------------- socket events --

  String? _pendingOffer;
  final List<Map<String, dynamic>> _pendingRemoteIce = [];

  /// Wire these from the app state controller.
  Future<void> handleSignal(String type, Map<String, dynamic> data) async {
    switch (type) {
      case 'call_invite':
        if (phase == CallPhase.idle) {
          callId = data['callId'] as String?;
          isVideo = data['media'] == 'video';
          incoming = true;
          phase = CallPhase.ringing;
          notifyListeners();
          onIncomingCall?.call();
        } else {
          socket.callReject(data['callId'] as String? ?? '');
        }
        break;
      case 'call_accept':
        // Callee accepted; offer already sent, ICE will flow.
        break;
      case 'call_reject':
      case 'call_end':
        await _teardown();
        notifyListeners();
        break;
      case 'rtc_offer':
        if (callId == null || data['callId'] != callId) return;
        _pendingOffer = data['sdp'] as String?;
        if (phase == CallPhase.connecting && _pc != null && _pendingOffer != null) {
          await _pc!.setRemoteDescription(RTCSessionDescription(_pendingOffer, 'offer'));
          _drainPendingIce();
        }
        break;
      case 'rtc_answer':
        if (callId == null || data['callId'] != callId) return;
        await _pc?.setRemoteDescription(RTCSessionDescription(data['sdp'] as String, 'answer'));
        _drainPendingIce();
        break;
      case 'rtc_ice':
        if (callId == null || data['callId'] != callId) return;
        final cand = (data['candidate'] as Map?)?.cast<String, dynamic>();
        if (cand == null) return;
        await _pc?.addCandidate(
          RTCIceCandidate(
            cand['candidate'] as String?,
            cand['sdpMid'] as String?,
            (cand['sdpMLineIndex'] as num?)?.toInt(),
          ),
        );
        break;
    }
  }

  void _drainPendingIce() async {
    final list = List<Map<String, dynamic>>.from(_pendingRemoteIce);
    _pendingRemoteIce.clear();
    for (final cand in list) {
      await _pc?.addCandidate(
        RTCIceCandidate(
          cand['candidate'] as String?,
          cand['sdpMid'] as String?,
          (cand['sdpMLineIndex'] as num?)?.toInt(),
        ),
      );
    }
  }

  // -------------------------------------------------------------- internals --

  Future<void> _preparePeerConnection() async {
    if (!renderersReady) {
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      renderersReady = true;
    }
    _pc = await createPeerConnection(
      <String, dynamic>{'iceServers': iceServers, 'sdpSemantics': 'unified-plan'},
      <String, dynamic>{},
    );
    _pc!.onIceCandidate = (cand) {
      if (callId == null) return;
      socket.rtcIce(callId!, <String, dynamic>{
        'candidate': cand.candidate,
        'sdpMid': cand.sdpMid,
        'sdpMLineIndex': cand.sdpMLineIndex,
      });
    };
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        remoteRenderer.srcStream = _remoteStream;
        if (phase == CallPhase.dialing || phase == CallPhase.connecting) {
          phase = CallPhase.active;
          notifyListeners();
        }
      }
    };
    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        endCall();
      }
    };
  }

  Future<void> _obtainLocalMedia(bool video) async {
    final media = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': true,
      'video': video
          ? <String, dynamic>{'facingMode': 'user', 'width': 1280, 'height': 720}
          : false,
    });
    _localStream = media;
    localRenderer.srcStream = media;
    for (final track in media.getTracks()) {
      await _pc?.addTrack(track, media);
    }
  }

  Future<void> _teardown() async {
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    for (final t in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      try {
        await t.stop();
      } catch (_) {}
    }
    _localStream = null;
    _remoteStream = null;
    localRenderer.srcStream = null;
    remoteRenderer.srcStream = null;
    _pendingOffer = null;
    _pendingRemoteIce.clear();
    phase = CallPhase.idle;
    callId = null;
    incoming = false;
    micMuted = false;
    cameraOff = false;
  }

  @override
  void dispose() {
    _teardown();
    if (renderersReady) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }
}

enum CallPhase { idle, dialing, ringing, connecting, active, ended }
