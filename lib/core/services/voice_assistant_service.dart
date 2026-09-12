import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Voice layer for the AI tourism assistant.
///
/// • [listen] — speech-to-text via the device recognizer. Uses the system
///   speech locale so travelers (including foreign visitors) can ask in their
///   own language; live partial text is streamed through [onPartial].
/// • [speak] / [pause] / [resume] / [stopSpeaking] — text-to-speech playback
///   with session tracking, so the UI can render Pause / Resume / Stop
///   controls and never overlap two utterances.
///
/// Both paths fail gracefully: [VoiceException] carries a user-friendly
/// message and the UI falls back to typed input / on-screen text.
class VoiceAssistantService extends ChangeNotifier {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  // ---- Speech-to-text state ----
  bool _initialized = false;
  bool _initializing = false;
  Completer<String?>? _pending;

  // ---- Text-to-speech session state ----
  bool _speaking = false;
  bool _paused = false;
  String? _lastText;
  Completer<void>? _session;

  bool get isListening => _speech.isListening;
  bool get isSpeaking => _speaking;
  bool get isPaused => _paused;

  VoiceAssistantService() {
    _tts.setStartHandler(() {
      _speaking = true;
      _paused = false;
      _notify();
    });
    _tts.setCompletionHandler(_onSessionEnd);
    _tts.setCancelHandler(() => _onSessionEnd());
    _tts.setErrorHandler((dynamic _) => _onSessionEnd());
    _tts.setPauseHandler(() {
      _paused = true;
      _speaking = false;
      _notify();
    });
    _tts.setContinueHandler(() {
      _paused = false;
      _speaking = true;
      _notify();
    });
  }

  void _notify() {
    notifyListeners();
  }

  void _onSessionEnd() {
    _speaking = false;
    _paused = false;
    final Completer<void>? s = _session;
    if (s != null && !s.isCompleted) s.complete();
    _session = null;
    _notify();
  }

  // ---------------------------------------------------------------------
  // Speech-to-text
  // ---------------------------------------------------------------------

  Future<bool> _ensureInitialized() async {
    if (_initialized) return true;
    if (_initializing) {
      while (_initializing && !_initialized) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return _initialized;
    }
    _initializing = true;
    try {
      _initialized = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
      );
    } catch (_) {
      _initialized = false;
    } finally {
      _initializing = false;
    }
    return _initialized;
  }

  void _onStatus(String status) {
    // Recognition finished with no usable result (silence, timeout, no
    // match) — release the listener with null so the UI isn't stuck.
    if (status == 'done') {
      final Completer<String?>? c = _pending;
      if (c != null && !c.isCompleted) c.complete(null);
    }
  }

  void _onError(SpeechRecognitionError error) {
    final Completer<String?>? c = _pending;
    if (c == null || c.isCompleted) return;
    if (error.permanent) {
      c.completeError(VoiceException(_friendlyError(error)));
    }
    // Non-permanent errors (retryable): keep listening.
  }

  String _friendlyError(SpeechRecognitionError e) {
    final String msg = e.errorMsg.toLowerCase();
    if (msg.contains('permission')) {
      return 'Microphone access is off. Enable it in Settings to ask by voice.';
    }
    if (msg.contains('no_match') ||
        msg.contains('speech_timeout') ||
        msg.contains('no result')) {
      return "I didn't catch that. Please try again.";
    }
    if (msg.contains('network')) {
      return 'Speech recognition needs a network connection. '
          'Please check your connection.';
    }
    if (msg.contains('language_not_supported') ||
        msg.contains('language_unavailable')) {
      return 'Your language isn\'t available for voice input. '
          'Please try English or type your question.';
    }
    return 'Voice input failed. Please type your question instead.';
  }

  /// Starts one recognition session and completes with the recognized text
  /// (trimmed), or null when nothing was recognized.
  ///
  /// Stops any in-progress TTS first so speech output never overlaps the
  /// microphone.
  Future<String?> listen({
    void Function(String partial)? onPartial,
  }) async {
    if (!await _ensureInitialized()) {
      throw const VoiceException(
        'Voice input is not available on this device. '
        'You can still type your question below.',
      );
    }
    await stopSpeaking();
    if (_pending != null && !_pending!.isCompleted) {
      // Second tap while listening = "finish now" (accept what was heard).
      await _speech.stop();
      return _pending!.future;
    }

    final Completer<String?> completer = Completer<String?>();
    _pending = completer;

    try {
      final LocaleName? system = await _speech.systemLocale();
      final String localeId = (system != null && system.localeId.isNotEmpty)
          ? system.localeId
          : 'en_US';
      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          if (result.finalResult) {
            final String words = result.recognizedWords.trim();
            if (!completer.isCompleted) completer.complete(words);
          } else {
            onPartial?.call(result.recognizedWords);
          }
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
          autoPunctuation: true,
        ).copyWith(
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
          localeId: localeId,
        ),
      );
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(VoiceException('Could not start voice input: $e'));
      }
    }

    // Safety net: never leave the UI stuck "listening" forever.
    try {
      return await completer.future.timeout(const Duration(seconds: 35));
    } on TimeoutException {
      await cancel();
      return null;
    }
  }

  /// Finishes recognition and returns whatever was heard so far.
  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }

  /// Aborts recognition (discards the result).
  Future<void> cancel() async {
    final Completer<String?>? c = _pending;
    if (c != null && !c.isCompleted) c.complete(null);
    try {
      await _speech.cancel();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Text-to-speech
  // ---------------------------------------------------------------------

  /// Reads [text] aloud (English by default, Hindi when the reply contains
  /// Devanagari script). Returns a future that completes when the utterance
  /// finishes (or is stopped) — it stays pending while paused.
  Future<void> speak(String text, {String? language}) async {
    final String clean = _strip(text);
    if (clean.isEmpty) return;
    await stopSpeaking();
    _lastText = clean;
    final String lang = language ??
        (RegExp(r'[\u0900-\u097F]').hasMatch(clean) ? 'hi-IN' : 'en-US');
    final Completer<void> session = Completer<void>();
    _session = session;
    try {
      await _tts.awaitSpeakCompletion(false);
      await _tts.setLanguage(lang);
      await _tts.setSpeechRate(0.5);
      await _tts.speak(clean);
    } catch (_) {
      _onSessionEnd();
      return;
    }
    await session.future;
  }

  /// Pauses the current utterance (best-effort on Android, SDK 26+).
  Future<void> pause() async {
    if (!_speaking) return;
    try {
      await _tts.pause();
    } catch (_) {
      await stopSpeaking();
    }
  }

  /// Resumes a paused utterance.
  Future<void> resume() async {
    final String? text = _lastText;
    if (text == null || !_paused) return;
    _paused = false;
    _speaking = true;
    _notify();
    try {
      await _tts.speak(text);
    } catch (_) {
      _onSessionEnd();
    }
  }

  /// Stops any in-progress utterance.
  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _onSessionEnd();
  }

  String _strip(String text) => text.replaceAll(RegExp(r'[*_#`>]'), '').trim();

  @override
  void dispose() {
    unawaited(cancel());
    unawaited(stopSpeaking());
    super.dispose();
  }
}

class VoiceException implements Exception {
  const VoiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
