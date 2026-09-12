import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Voice layer for the AI tourism assistant.
///
/// • [listen] — speech-to-text via the device recognizer. Uses the system
///   speech locale so travelers (including foreign visitors) can ask in their
///   own language; live partial text is streamed through [onPartial].
/// • [speak] — text-to-speech so the assistant can read its answer aloud.
///
/// Both paths fail gracefully: [VoiceException] carries a user-friendly
/// message and the UI falls back to typed input / on-screen text.
class VoiceAssistantService {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _initialized = false;
  bool _initializing = false;
  Completer<String?>? _pending;

  bool get isListening => _speech.isListening;

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
  Future<String?> listen({
    void Function(String partial)? onPartial,
  }) async {
    if (!await _ensureInitialized()) {
      throw const VoiceException(
        'Voice input is not available on this device. '
        'You can still type your question below.',
      );
    }
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

  /// Reads [text] aloud. Defaults to English, auto-switching to Hindi when
  /// the reply contains Devanagari script.
  Future<void> speak(String text, {String? language}) async {
    final String clean = text.replaceAll(RegExp(r'[*_#`>]'), '').trim();
    if (clean.isEmpty) return;
    try {
      final String lang = language ??
          (RegExp(r'[\u0900-\u097F]').hasMatch(clean) ? 'hi-IN' : 'en-US');
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage(lang);
      await _tts.setSpeechRate(0.5);
      await _tts.speak(clean);
    } catch (_) {
      // TTS is a convenience; never block the chat on it.
    }
  }

  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  void dispose() {
    unawaited(cancel());
    unawaited(stopSpeaking());
  }
}

class VoiceException implements Exception {
  const VoiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
