// Covers MeshGeometry.sharingVertices and MeshGeometry.setIndexData: a
// shared geometry binds its source's vertex streams and only uploads
// indices, and setIndexData swaps the index buffer (through a ring) without
// touching the vertex streams. GPU-gated like the other buffer suites.

import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

bool _gpuAvailable() {
  try {
    gpu.gpuContext.createDeviceBuffer(gpu.StorageMode.hostVisible, 4);
    return true;
  } catch (_) {
    return false;
  }
}

/// Records what the geometry binds, so a test can see which buffers each
/// draw reads.
class _Recording extends MeshGeometry {
  _Recording.fromArrays({required super.positions, super.indices})
    : super.fromArrays();

  _Recording.sharing(super.source, {super.indices}) : super.sharingVertices();

  final List<List<gpu.BufferView>> streamBinds = [];
  final List<gpu.BufferView> indexBinds = [];

  @override
  void setVertexStreams(List<gpu.BufferView> streams, int vertexCount) {
    streamBinds.add(streams);
    super.setVertexStreams(streams, vertexCount);
  }

  @override
  void setIndices(gpu.BufferView indices, gpu.IndexType indexType) {
    indexBinds.add(indices);
    super.setIndices(indices, indexType);
  }
}

/// Two quads side by side: eight vertices, four triangles.
final _positions = Float32List.fromList([
  0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, //
  2, 0, 0, 3, 0, 0, 3, 1, 0, 2, 1, 0,
]);
const _allTriangles = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7];
const _leftQuad = [0, 1, 2, 0, 2, 3];

void main() {
  final skip = _gpuAvailable() ? null : 'Requires a GPU device.';

  group('sharingVertices', () {
    test('binds the source streams and uploads only its own indices', () {
      final source = _Recording.fromArrays(
        positions: _positions,
        indices: _allTriangles,
      );
      final shared = _Recording.sharing(source, indices: _leftQuad);

      expect(shared.streamBinds, hasLength(1));
      expect(shared.streamBinds.single, same(source.streamBinds.last));
      expect(shared.indexBinds.last.lengthInBytes, _leftQuad.length * 2);
      expect(
        shared.indexBinds.last.buffer,
        isNot(same(source.indexBinds.last.buffer)),
      );
      expect(shared.vertexCount, source.vertexCount);
      expect(shared.primitiveType, source.primitiveType);
    }, skip: skip);

    test('keeps the source bounds and no CPU data', () {
      final source = MeshGeometry.fromArrays(
        positions: _positions,
        indices: _allTriangles,
      );
      final shared = MeshGeometry.sharingVertices(source, indices: _leftQuad);

      expect(shared.localBounds!.min, source.localBounds!.min);
      expect(shared.localBounds!.max, Vector3(3, 1, 0));
      expect(shared.retainCpuData, isFalse);
      expect(shared.isReadable, isFalse);
    }, skip: skip);

    test('rejects an updatable source', () {
      final source = MeshGeometry.fromArrays(
        positions: _positions,
        indices: _allTriangles,
        storage: GeometryStorage.updatable,
      );
      expect(
        () => MeshGeometry.sharingVertices(source, indices: _leftQuad),
        throwsArgumentError,
      );
    }, skip: skip);
  });

  group('setIndexData', () {
    test('replaces the indices and leaves the vertex streams bound', () {
      final geometry = _Recording.fromArrays(
        positions: _positions,
        indices: _allTriangles,
      );
      final streamBindsBefore = geometry.streamBinds.length;

      geometry.setIndexData(Uint32List.fromList(_leftQuad));

      expect(geometry.streamBinds, hasLength(streamBindsBefore));
      expect(geometry.indexBinds.last.lengthInBytes, _leftQuad.length * 4);
      // A retained mesh reads back (and raycasts) the new triangles.
      expect(geometry.extractMeshData().indices, _leftQuad);
    }, skip: skip);

    test('writes through a ring of four buffers', () {
      final geometry = _Recording.fromArrays(
        positions: _positions,
        indices: _allTriangles,
      );
      final indices = Uint32List.fromList(_leftQuad);
      final buffers = <gpu.DeviceBuffer>[];
      for (var i = 0; i < 5; i++) {
        geometry.setIndexData(indices);
        buffers.add(geometry.indexBinds.last.buffer);
      }

      expect(buffers.take(4).toSet(), hasLength(4));
      expect(buffers[4], same(buffers[0]));

      // A longer list outgrows the ring and starts a new one.
      geometry.setIndexData(Uint32List(4096));
      expect(buffers, isNot(contains(geometry.indexBinds.last.buffer)));
    }, skip: skip);

    test('works on a shared geometry', () {
      final source = MeshGeometry.fromArrays(
        positions: _positions,
        indices: _allTriangles,
      );
      final shared = _Recording.sharing(source, indices: _leftQuad);
      shared.setIndexData(Uint32List.fromList(_allTriangles));

      expect(shared.streamBinds, hasLength(1));
      expect(shared.indexBinds.last.lengthInBytes, _allTriangles.length * 4);
    }, skip: skip);

    test('requires geometry created with indices', () {
      final geometry = MeshGeometry.fromArrays(
        positions: Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
      );
      expect(
        () => geometry.setIndexData(Uint32List.fromList([0, 1, 2])),
        throwsStateError,
      );
    }, skip: skip);

    test('rejects an index past the last vertex in debug builds', () {
      final geometry = MeshGeometry.fromArrays(
        positions: _positions,
        indices: _allTriangles,
      );
      expect(
        () => geometry.setIndexData(Uint32List.fromList([0, 1, 8])),
        throwsArgumentError,
      );
    }, skip: skip);
  });
}
