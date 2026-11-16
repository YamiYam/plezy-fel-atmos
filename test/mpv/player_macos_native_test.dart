import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/platform/player_macos_native.dart';

import '../test_helpers/mock_player_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> withNativePlayer(
    Future<void> Function(PlayerMacOSNative player) body, {
    Future<Object?> Function(MethodCall call)? handler,
  }) => withMockPlayerChannels(
    methodChannelName: 'com.plezy/native_playback',
    eventChannelName: 'com.plezy/native_playback/events',
    methodHandler: handler ?? (call) async => call.method == 'initialize' ? true : null,
    testBody: () async {
      final player = PlayerMacOSNative();
      try {
        await body(player);
      } finally {
        await player.dispose();
      }
    },
  );

  test('native open forwards sidecars, headers and the source-relative start', () async {
    Map<Object?, Object?>? arguments;
    await withNativePlayer(
      (player) async {
        final source = await player.open(
          Media(
            'https://example.test/movie.mkv',
            headers: const {'X-Test': 'media-header'},
            start: const Duration(seconds: 45),
          ),
          play: false,
          timelineOffset: const Duration(seconds: 30),
          externalSubtitles: const [
            SubtitleTrack(
              id: 'external',
              title: 'English',
              language: 'eng',
              codec: 'srt',
              uri: 'https://example.test/movie.srt',
              isDefault: false,
              isForced: true,
              isExternal: true,
            ),
          ],
        );
        expect(source, 42);
        expect(arguments?['startPositionMs'], 15000);
        expect(arguments?['autoPlay'], false);
        expect(arguments?['headers'], {'X-Test': 'media-header'});
        final subtitles = arguments?['externalSubtitles'] as List;
        expect(subtitles.single['uri'], 'https://example.test/movie.srt');
        expect(subtitles.single['isForced'], true);
      },
      handler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'open') {
          arguments = call.arguments as Map;
          return 42;
        }
        return null;
      },
    );
  });

  test('a rejected native open restores timeline and seekability', () async {
    await withNativePlayer(
      (player) async {
        player.handlePropertyChange('time-pos', 120.0);
        player.handlePropertyChange('duration', 600.0);
        player.handlePropertyChange('seekable', true);
        await expectLater(
          player.open(
            Media('https://example.test/rejected.mkv'),
            timelineOffset: const Duration(seconds: 90),
            timelineDuration: const Duration(seconds: 200),
          ),
          throwsA(isA<PlatformException>()),
        );
        expect(player.state.position, const Duration(seconds: 120));
        expect(player.state.duration, const Duration(seconds: 600));
        expect(player.state.seekable, true);
        expect(player.timelineOffset, Duration.zero);
      },
      handler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'open') throw PlatformException(code: 'OPEN_FAILED');
        return null;
      },
    );
  });

  test('a superseded failure cannot roll back a newer native open', () async {
    final first = Completer<Object?>();
    var opens = 0;
    await withNativePlayer(
      (player) async {
        final stale = player.open(Media('https://example.test/first.mkv'));
        final rejected = expectLater(stale, throwsA(isA<PlatformException>()));
        await Future<void>.delayed(Duration.zero);
        await player.open(
          Media('https://example.test/second.mkv', start: const Duration(seconds: 50)),
          timelineDuration: const Duration(seconds: 500),
        );
        first.completeError(PlatformException(code: 'CANCELLED'));
        await rejected;
        expect(player.state.position, const Duration(seconds: 50));
        expect(player.state.duration, const Duration(seconds: 500));
      },
      handler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'open') return ++opens == 1 ? first.future : 2;
        return null;
      },
    );
  });

  test('HDR support comes from the screen rather than an unconditional promise', () async {
    await withNativePlayer(
      (player) async => expect(await player.isHdrOutputSupported(), false),
      handler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'isHdrOutputSupported') return false;
        return null;
      },
    );
  });
}
