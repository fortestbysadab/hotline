import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config.dart';

/// Thin REST client for the relay's untrusted management API.
/// (see backend/src/routes/api.js)
class RelayApi {
  RelayApi({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? RelayConfig.relayUrl;

  final http.Client _client;
  final String baseUrl;

  Map<String, String> get _ownerHeaders => <String, String>{
        'authorization': 'Bearer ${RelayConfig.ownerToken}',
        'content-type': 'application/json',
      };

  Future<Map<String, dynamic>> _parse(http.Response res) async {
    final body = jsonDecode(res.body.isEmpty ? '{}' : res.body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw RelayException(
        (body is Map && body['error'] != null) ? body['error'] as String : 'HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    return (body as Map).cast<String, dynamic>();
  }

  /// App B: publish the owner identity + signed prekey bundle.
  Future<void> registerOwner(Map<String, String> body) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/owner/register'),
      headers: _ownerHeaders,
      body: jsonEncode(body),
    );
    await _parse(res);
  }

  /// App B: mint a single-use invite code.
  Future<InviteCreated> createInvite(String ownerId) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/invites'),
      headers: _ownerHeaders,
      body: jsonEncode(<String, String>{'ownerId': ownerId}),
    );
    final body = await _parse(res);
    return InviteCreated(
      code: body['code'] as String,
      expiresAtMs: (body['expiresAt'] as num).toInt(),
    );
  }

  /// App A: exchange an invite code for a pair + the owner's prekey bundle.
  Future<Map<String, dynamic>> redeemInvite({
    required String code,
    required String clientPubKey,
    String? clientSigningPub,
    String? clientDisplayName,
  }) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/invites/redeem'),
      headers: <String, String>{'content-type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'code': code.trim(),
        'clientPubKey': clientPubKey,
        if (clientSigningPub != null) 'clientSigningPub': clientSigningPub,
        if (clientDisplayName != null) 'clientDisplayName': clientDisplayName,
      }),
    );
    return _parse(res);
  }

  /// App B: list active pairs (command center contact list refresh).
  Future<List<dynamic>> listPairs(String ownerId) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/api/pairs?ownerId=$ownerId'),
      headers: _ownerHeaders,
    );
    final body = await _parse(res);
    return body['pairs'] as List<dynamic>? ?? <dynamic>[];
  }

  /// App B: instantly revoke a client's access.
  Future<void> revokePair(String pairId) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/api/pairs/$pairId/revoke'),
      headers: _ownerHeaders,
    );
    await _parse(res);
  }

  Future<bool> healthy() async {
    try {
      final res = await _client.get(Uri.parse('$baseUrl/api/health'));
      return res.statusCode == 200;
    } on Exception {
      return false;
    }
  }
}

class InviteCreated {
  InviteCreated({required this.code, required this.expiresAtMs});
  final String code;
  final int expiresAtMs;
}

class RelayException implements Exception {
  RelayException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'RelayException($statusCode): $message';
}
