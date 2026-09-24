import 'dart:convert';

/// Message kinds carried INSIDE the E2EE envelope (server never sees these).
enum MessageKind { chat, fileMeta, fileChunk, system }

enum SendStatus { sending, sent, delivered, read, failed }

/// A decrypted chat message, as stored locally (Hive JSON) and rendered.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.kind,
    required this.outgoing,
    required this.timestampMs,
    this.status = SendStatus.sent,
    this.text,
    this.fileId,
    this.fileName,
    this.fileSize,
    this.fileMime,
    this.filePath,
  });

  final String id;
  final MessageKind kind;
  final bool outgoing;
  final int timestampMs;
  SendStatus status;

  String? text; // chat
  String? fileId; // file metadata
  String? fileName;
  int? fileSize;
  String? fileMime;
  String? filePath; // set once a file is fully received/decrypted

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind.name,
        'outgoing': outgoing,
        'timestampMs': timestampMs,
        'status': status.name,
        'text': text,
        'fileId': fileId,
        'fileName': fileName,
        'fileSize': fileSize,
        'fileMime': fileMime,
        'filePath': filePath,
      };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        kind: MessageKind.values.firstWhere(
          (k) => k.name == (j['kind'] as String? ?? 'chat'),
          orElse: () => MessageKind.chat,
        ),
        outgoing: (j['outgoing'] as bool? ?? false),
        timestampMs: (j['timestampMs'] as num).toInt(),
        status: SendStatus.values.firstWhere(
          (s) => s.name == (j['status'] as String? ?? 'sent'),
          orElse: () => SendStatus.sent,
        ),
        text: j['text'] as String?,
        fileId: j['fileId'] as String?,
        fileName: j['fileName'] as String?,
        fileSize: (j['fileSize'] as num?)?.toInt(),
        fileMime: j['fileMime'] as String?,
        filePath: j['filePath'] as String?,
      );

  String encode() => jsonEncode(toJson());
  static ChatMessage decode(String raw) =>
      ChatMessage.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
}

/// A paired contact as displayed in the Owner's command center (App B) or as
/// the fixed Owner peer in the client app (App A).
class Contact {
  Contact({
    required this.pairId,
    required this.displayName,
    required this.keyFingerprint,
    this.status = 'active',
    this.lastSeenMs,
  });

  final String pairId;
  final String displayName;
  final String keyFingerprint; // short hash of the peer identity key
  final String status;
  int? lastSeenMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pairId': pairId,
        'displayName': displayName,
        'keyFingerprint': keyFingerprint,
        'status': status,
        'lastSeenMs': lastSeenMs,
      };

  static Contact fromJson(Map<String, dynamic> j) => Contact(
        pairId: j['pairId'] as String,
        displayName: j['displayName'] as String? ?? 'Unnamed',
        keyFingerprint: j['keyFingerprint'] as String? ?? '',
        status: j['status'] as String? ?? 'active',
        lastSeenMs: (j['lastSeenMs'] as num?)?.toInt(),
      );
}

/// Decrypted live-location sample (App B map + presence cards).
class LocationSample {
  LocationSample({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.altitude,
    required this.batteryLevel,
    required this.isCharging,
    required this.timestampMs,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
  final double speed;
  final double altitude;
  final int batteryLevel;
  final bool isCharging;
  final int timestampMs;

  bool get isMoving => speed > 1.4; // > ~5 km/h, per the sampling spec

  Map<String, dynamic> toJson() => <String, dynamic>{
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'speed': speed,
        'altitude': altitude,
        'batteryLevel': batteryLevel,
        'isCharging': isCharging,
        'timestampMs': timestampMs,
      };

  static LocationSample fromJson(Map<String, dynamic> j) => LocationSample(
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        accuracy: (j['accuracy'] as num? ?? 0).toDouble(),
        speed: (j['speed'] as num? ?? 0).toDouble(),
        altitude: (j['altitude'] as num? ?? 0).toDouble(),
        batteryLevel: (j['batteryLevel'] as num? ?? 0).toInt(),
        isCharging: (j['isCharging'] as bool? ?? false),
        timestampMs: (j['timestampMs'] as num).toInt(),
      );
}
