import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Sessions are written under a fresh temporary folder.
class FakeDocuments extends PathProviderPlatform {
  FakeDocuments() : root = Directory.systemTemp.createTempSync('dance_trainer_test');
  final Directory root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;
  @override
  Future<String?> getTemporaryPath() async => root.path;

  /// iOS keeps the app's own data here (store/app_dirs.dart).
  String get supportPath => '${root.path}/support';
  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

/// A just_audio backend that is ready at once and plays silently, plus the
/// audio-session channels it talks to.
void installFakeAudio() {
  JustAudioPlatform.instance = _FakeAudio();
  for (final ch in [
    'com.ryanheise.audio_session',
    'com.ryanheise.android_audio_manager',
    'com.ryanheise.av_audio_session',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(ch), (call) async => call.method == 'requestAudioFocus' ? true : null);
  }
}

class _FakeAudio extends JustAudioPlatform {
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => _FakePlayer(request.id);
  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async => DisposePlayerResponse();
  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();
}

class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;
  @override
  Future<LoadResponse> load(LoadRequest request) async {
    Timer.run(() => _events.add(PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: const Duration(minutes: 5),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null)));
    return LoadResponse(duration: const Duration(minutes: 5));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async => SetSpeedResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async => SetVolumeResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async => SetLoopModeResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async => SetShuffleModeResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async => SetPitchResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async => SetSkipSilenceResponse();
  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest r) async =>
      SetAndroidAudioAttributesResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async => DisposeResponse();
}
