# flutter_webrtc uses JNI callbacks — keep the webrtc bridge classes.
-keep class com.cloudwebrtc.webrtc.** { *; }
# flutter_background_service notification + isolate bootstrapping.
-keep class id.flutter.flutter_background_service.** { *; }
# cryptography/Hive run in Dart VM; no extra keep rules needed.
# Socket.io engine (OkHttp) — strip only debug logging.
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
