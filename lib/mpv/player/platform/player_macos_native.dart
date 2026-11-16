import 'package:flutter/services.dart';

import '../../../models/audio_channel_limit.dart';
import '../../models.dart';
import '../player_base.dart';

/// Opt-in Apple-native FEL and object-audio backend. Standard builds retain mpv.
class PlayerMacOSNative extends PlayerBase {
  static const enabled = bool.fromEnvironment('PLEZY_MACOS_NATIVE');

  @override
  final methodChannel = const MethodChannel('com.plezy/native_playback');
  @override
  final eventChannel = const EventChannel('com.plezy/native_playback/events');
  @override
  String get logPrefix => 'NativePlayback';
  @override
  String get playerType => 'aether';
  @override
  bool get supportsSecondarySubtitles => false;
  @override
  bool get providesNativeStats => true;
  @override
  bool get nativeDisposeIsStaleGuarded => true;

  Future<void>? _initializing;
  int _openGeneration = 0;

  Future<void> _ensureInitialized() async {
    if (initialized) return;
    await (_initializing ??= _initialize());
  }

  Future<void> _initialize() async {
    try {
      final result = await invoke<bool>('initialize', {'instanceId': nativeInstanceId});
      if (result != true || disposed) throw const PlayerInitializationException();
      initialized = true;
    } catch (error) {
      _initializing = null;
      rethrow;
    }
  }

  @override
  void handlePlayerEvent(String name, Map? data) {
    if (name == 'properties') {
      final values = data?['values'];
      if (values is Map) {
        for (final entry in values.entries) {
          if (entry.key is String) {
            handlePropertyChange(entry.key as String, entry.value, sourceId: data?['sourceId'] as int?);
          }
        }
      }
      return;
    }
    super.handlePlayerEvent(name, data);
  }

  @override
  Future<int?> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    if (isLive) throw UnsupportedError('Live TV requires the standard mpv build.');
    await _ensureInitialized();
    final generation = ++_openGeneration;
    final previousState = state;
    final previousPosition = currentPosition;
    final previousTimelineDuration = configuredTimelineDuration;
    final previousTimelineOffset = this.timelineOffset;
    final previousSubtitles = snapshotExternalSubtitleMetadata();
    configureTimeline(duration: timelineDuration, offset: timelineOffset);
    final start = media.start ?? timelineOffset;
    clearTracks();
    setExternalSubtitleMetadata(externalSubtitles);
    resetPlaybackProgress(start);
    setSeekable(false);
    try {
      return await invoke<int>('open', {
        'uri': media.uri,
        'headers': media.headers,
        'startPositionMs': sourcePositionFor(start).inMilliseconds,
        'autoPlay': play,
        'isLive': isLive,
        'externalSubtitles': [
          for (final track in externalSubtitles ?? <SubtitleTrack>[])
            if (track.uri?.isNotEmpty == true)
              {
                'uri': track.uri,
                'title': track.title,
                'language': track.language,
                'codec': track.codec,
                'isDefault': track.isDefault,
                'isForced': track.isForced,
              },
        ],
      });
    } catch (_) {
      if (!disposed && generation == _openGeneration) {
        configureTimeline(duration: previousTimelineDuration, offset: previousTimelineOffset);
        restorePlaybackProgress(previousState, position: previousPosition);
        restoreTracks(previousState);
        restoreExternalSubtitleMetadata(previousSubtitles);
        setSeekable(previousState.seekable);
      }
      rethrow;
    }
  }

  @override
  Future<void> play() => invoke('play');
  @override
  Future<void> pause() => invoke('pause');
  @override
  Future<void> stop() async {
    _openGeneration++;
    await invoke('stop');
    setSeekable(false);
    await setVisible(false);
  }

  @override
  Future<void> seek(Duration position) =>
      runSeek(position, () => invoke('seek', {'positionMs': sourcePositionFor(position).inMilliseconds}));

  @override
  Future<void> selectAudioTrack(AudioTrack track) => invoke('selectAudioTrack', {'trackId': track.id});
  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) => invoke('selectSubtitleTrack', {'trackId': track.id});

  @override
  Future<void> setVolume(double volume) async {
    await invoke('setVolume', {'volume': volume});
    setVolumeState(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    await invoke('setRate', {'rate': rate});
    setRateState(rate);
  }

  @override
  Future<void> setProperty(String name, String value) async {
    await _ensureInitialized();
    await invoke('setProperty', {'name': name, 'value': value});
  }

  @override
  Future<String?> getProperty(String name) => invoke<String>('getProperty', {'name': name});

  @override
  Future<void> command(List<String> args) async {
    throw UnsupportedError('mpv commands are not available in the experimental native backend.');
  }

  @override
  Future<void> configureSubtitleFonts() async {
    logController.add(
      const PlayerLog(
        prefix: 'subtitles',
        level: PlayerLogLevel.warn,
        text:
            'Experimental native playback supports bitmap subtitles but flattens styled text; libass styling is unavailable.',
      ),
    );
  }

  @override
  Future<void> setAudioNormalization(bool enabled) async {
    if (enabled) throw UnsupportedError('Disable normalization to use object-aware native audio.');
  }

  @override
  Future<void> setAudioPassthrough(bool enabled) async {
    if (enabled) throw UnsupportedError('Native playback renders object audio; it does not bitstream TrueHD.');
  }

  @override
  Future<void> setAudioChannelLimit(
    AudioChannelLimit limit, {
    required int centerBoostDb,
    required bool normalize,
  }) async {
    if (limit != AudioChannelLimit.original) {
      throw UnsupportedError('Use the original channel layout for native object audio.');
    }
  }

  @override
  Future<bool> setVisible(bool visible, {bool restoreOnWindowVisible = false}) async {
    if (!initialized) return false;
    return await invoke<bool>('setVisible', {'visible': visible}) ?? false;
  }

  @override
  Future<void> updateFrame() async {
    if (initialized) await invoke('updateFrame');
  }

  @override
  Future<bool> isHdrOutputSupported() async {
    await _ensureInitialized();
    return await invoke<bool>('isHdrOutputSupported') ?? false;
  }

  @override
  Future<void> setVideoZoom(double scale) async {
    if (scale != 1) throw UnsupportedError('Native playback supports fit modes, not custom zoom.');
  }

  @override
  Future<void> setAudioDevice(AudioDevice device) async {
    if (device.name != 'auto') {
      throw UnsupportedError('Native playback uses the macOS default audio device.');
    }
  }

  @override
  Future<void> setBoxFitMode(int mode) => invoke('setBoxFitMode', {'mode': mode});

  @override
  Future<Map<String, dynamic>> getStats() async {
    final result = await invoke<Map>('getStats');
    return result?.cast<String, dynamic>() ?? const {};
  }
}
