import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../../models/models.dart';

/// Local persistence built on Hive (per the architecture doc: "Isar / Hive").
/// Message history and contact state are stored as JSON strings — no
/// generated adapters — while key material goes to the secure store
/// (see SessionManager).
class LocalStore {
  LocalStore._();

  static const String _boxPairing = 'pairing';
  static const String _boxContacts = 'contacts';
  static const String _boxLocations = 'locations';

  /// Per-pair message history boxes are opened lazily and cached.
  final Map<String, Box<String>> _messageBoxes = {};

  static Future<LocalStore> init() async {
    await Hive.initFlutter('hotline');
    final store = LocalStore._();
    await Hive.openBox<String>(_boxPairing);
    await Hive.openBox<String>(_boxContacts);
    await Hive.openBox<String>(_boxLocations);
    return store;
  }

  Box<String> get _pairing => Hive.box<String>(_boxPairing);
  Box<String> get _contacts => Hive.box<String>(_boxContacts);
  Box<String> get _locations => Hive.box<String>(_boxLocations);

  // -------------------------------------------------------------- pairing --

  /// The client app stores its single pairing here after redemption.
  Future<void> saveMyPairing(Map<String, dynamic> pairing) async =>
      _pairing.put('myPairing', jsonEncode(pairing));

  Map<String, dynamic>? get myPairing {
    final raw = _pairing.get('myPairing');
    if (raw == null) return null;
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Future<void> clearMyPairing() async => _pairing.delete('myPairing');

  // ------------------------------------------------------------- contacts --

  Future<void> saveContact(Contact c) async =>
      _contacts.put(c.pairId, jsonEncode(c.toJson()));

  Contact? getContact(String pairId) {
    final raw = _contacts.get(pairId);
    if (raw == null) return null;
    return Contact.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
  }

  List<Contact> allContacts() => _contacts.values
      .map((raw) => Contact.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>()))
      .toList();

  Future<void> deleteContact(String pairId) async => _contacts.delete(pairId);

  // -------------------------------------------------------------- messages --

  Future<Box<String>> _messages(String pairId) async {
    return _messageBoxes[pairId] ??= await Hive.openBox<String>('msg_$pairId');
  }

  Future<void> appendMessage(String pairId, ChatMessage m) async {
    final box = await _messages(pairId);
    await box.put(m.id, m.encode());
  }

  Future<void> updateMessage(String pairId, ChatMessage m) => appendMessage(pairId, m);

  Future<ChatMessage?> getMessage(String pairId, String id) async {
    final box = await _messages(pairId);
    final raw = box.get(id);
    return raw == null ? null : ChatMessage.decode(raw);
  }

  Future<List<ChatMessage>> history(String pairId, {int limit = 500}) async {
    final box = await _messages(pairId);
    final all = box.values.map(ChatMessage.decode).toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    return all.length <= limit ? all : all.sublist(all.length - limit);
  }

  Future<void> clearHistory(String pairId) async {
    final box = await _messages(pairId);
    await box.clear();
  }

  // ------------------------------------------------------------- locations --

  Future<void> saveLocation(String pairId, LocationSample s) async =>
      _locations.put(pairId, jsonEncode(s.toJson()));

  LocationSample? locationFor(String pairId) {
    final raw = _locations.get(pairId);
    return raw == null ? null : LocationSample.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
  }
}
