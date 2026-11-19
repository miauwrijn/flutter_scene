// Covers buildMaterials' includeDirectories: a material #includes GLSL of
// the app's own, the files are build dependencies, and a missing directory
// fails with a clear error.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_scene/src/fmat/build_materials.dart';
import 'package:flutter_scene/src/generated_assets/generated_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks/hooks.dart';

BuildInput _input(Uri packageRoot, Uri buildRoot, OS targetOS) {
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: packageRoot,
      packageName: 'app',
      outputDirectoryShared: buildRoot.resolve('shared/'),
      outputFile: buildRoot.resolve('output.json'),
    )
    ..setupBuildInput();
  builder.config.setupBuild(linkingEnabled: false);
  CodeAssetExtension(
    targetArchitecture: Architecture.arm64,
    targetOS: targetOS,
    linkModePreference: LinkModePreference.dynamic,
    iOS: targetOS == OS.iOS
        ? IOSCodeConfig(targetSdk: IOSSdk.iPhoneOS, targetVersion: 13)
        : null,
    android: targetOS == OS.android
        ? AndroidCodeConfig(targetNdkApi: 21)
        : null,
  ).setupBuildInput(builder);
  return builder.build();
}

const _fragment = '''
#version 460 core
precision highp float;
uniform sampler2D source_texture;
in vec2 v_uv;
out vec4 frag_color;
void main() {
  frag_color = texture(source_texture, v_uv);
}
''';

const _vertex = '''
in vec2 position;
out vec2 v_uv;
void main() {
  v_uv = position * 0.5 + 0.5;
  gl_Position = vec4(position, 0.0, 1.0);
}
''';

// Reads its color from a GLSL file of the app's own, found on the include
// path only through [buildMaterials]' includeDirectories.
const _material = '''
material {
  name: "Flat",
  shading_model: unlit,
}

fragment {
  #include <app_tint.glsl>

  void Surface(inout MaterialInputs material) {
    material.base_color = AppTint();
    PrepareMaterial(material);
  }
}
''';

const _appTint = '''
vec4 AppTint() { return vec4(1.0, 0.5, 0.25, 1.0); }
''';

void _write(Directory root, String path, String contents) => (File.fromUri(
  root.uri.resolve(path),
)..parent.createSync(recursive: true)).writeAsStringSync(contents);

/// A package with a raw shader bundle `tiny` and one `.fmat` material.
Directory _package() {
  final root = Directory.systemTemp.createTempSync('fs_hook_package');
  _write(
    root,
    'pubspec.yaml',
    'name: app\nflutter:\n  assets:\n    - $generatedAssetsEntry\n',
  );
  _write(root, 'shaders/tiny.frag', _fragment);
  _write(root, 'shaders/tiny.vert', _vertex);
  _write(
    root,
    'shaders/tiny.shaderbundle.json',
    '{"TinyFragment": {"type": "fragment", "file": "shaders/tiny.frag"},'
        ' "TinyVertex": {"type": "vertex", "file": "shaders/tiny.vert"}}',
  );
  _write(root, 'assets/flat.fmat', _material);
  _write(root, 'glsl/app_tint.glsl', _appTint);
  // A hook `flutter test` runs in process has no package resolver, so the
  // engine's shaders are found through the package config.
  _write(
    root,
    '.dart_tool/package_config.json',
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'flutter_scene',
          'rootUri': Directory.current.absolute.uri.toString(),
          'packageUri': 'lib/',
        },
      ],
    }),
  );
  return root;
}

/// Every file below [root], relative to it.
bool _builtBundle(Directory root) => Directory.fromUri(
  root.uri.resolve('$generatedAssetsDirectory/'),
).listSync(recursive: true).any((e) => e.path.endsWith('.shaderbundle'));

void main() {
  late Directory package;
  late Directory app;

  setUp(() {
    package = _package();
    app = Directory.systemTemp.createTempSync('fs_include_app');
  });
  tearDown(() {
    package.deleteSync(recursive: true);
    app.deleteSync(recursive: true);
  });

  test('a material includes GLSL from an include directory', () async {
    final output = BuildOutputBuilder();
    await buildMaterials(
      buildInput: _input(package.uri, app.uri, OS.android),
      buildOutput: output,
      includeDirectories: [package.uri.resolve('glsl/')],
    );
    expect(_builtBundle(package), isTrue);
    final dependencies = (output.build().json['dependencies'] as List)
        .cast<String>();
    // Native paths: backslashes on Windows.
    expect(
      dependencies.any(
        (d) => d.replaceAll(r'\', '/').endsWith('glsl/app_tint.glsl'),
      ),
      isTrue,
    );
  });

  test('includeDirectorySources lists the .glsl files in order', () {
    _write(package, 'glsl/a_first.glsl', '');
    _write(package, 'glsl/notes.txt', '');
    _write(package, 'glsl/nested/deeper.glsl', '');
    final names = [
      for (final f in includeDirectorySources(package.uri.resolve('glsl/')))
        f.uri.pathSegments.last,
    ];
    expect(names, ['a_first.glsl', 'app_tint.glsl']);
  });

  test('a missing include directory fails clearly', () async {
    await expectLater(
      buildMaterials(
        buildInput: _input(package.uri, app.uri, OS.android),
        buildOutput: BuildOutputBuilder(),
        includeDirectories: [package.uri.resolve('missing/')],
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('is not a directory'),
        ),
      ),
    );
  });
}
