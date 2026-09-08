import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/geometry/geometry.dart'
    show bindUnskinnedFrameInfo;
import 'package:flutter_scene/src/render/instance_packing.dart';
import 'package:flutter_scene/src/render/render_scene.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/shaders.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';

/// Selects which scene nodes an object-filtered draw includes.
///
/// Used by the object-filtered draw (the selection mask, and the public
/// `RenderPassContext.drawObjects`) to pick a subset of the scene's
/// drawable geometry to render flat into a target.
/// {@category Rendering}
class NodeFilter {
  /// Includes every visible drawable node.
  const NodeFilter.all() : _layerMask = null, _predicate = null;

  /// Includes nodes whose render layers intersect [mask].
  const NodeFilter.layers(int mask) : _layerMask = mask, _predicate = null;

  /// Includes nodes for which [predicate] returns true.
  ///
  /// The predicate is called with each candidate node every frame, so keep
  /// it cheap (a set membership test is ideal).
  const NodeFilter.where(bool Function(Object node) predicate)
    : _predicate = predicate,
      _layerMask = null;

  final int? _layerMask;
  final bool Function(Object node)? _predicate;

  /// Whether [item] passes this filter.
  bool _matches(RenderItem item, int viewLayerMask) {
    if ((item.layers & viewLayerMask) == 0) return false;
    final mask = _layerMask;
    if (mask != null) return (item.layers & mask) != 0;
    final predicate = _predicate;
    if (predicate != null) {
      final node = item.sourceNode;
      return node != null && predicate(node);
    }
    return true;
  }
}

/// What an object-filtered draw writes for each covered pixel.
/// 
/// {@category Rendering}
enum MaskContent {
  /// The per-item color as given: a flat silhouette.
  flat,

  /// The per-item color multiplied by the material's textured base color
  /// (linear; base color factor, texture and weighted vertex color), so a
  /// pass can shade with the surface's own albedo at full resolution. Alpha
  /// is the per-item color's alpha.
  albedo,

  /// The material's shading normal — the geometric normal perturbed by its
  /// normal map, as the color pass lights with — in world space, encoded
  /// `n * 0.5 + 0.5` in rgb. Alpha is the per-item color's alpha. The
  /// per-item rgb is ignored.
  normal,
}

/// Draws a filtered set of the scene's geometry flat into [target], each
/// item filled with a solid color (coverage in alpha), with its own cleared
/// depth so the filtered objects self-occlude but are not occluded by the
/// rest of the scene (an x-ray silhouette, what a selection mask wants).
///
/// Reuses the engine's geometry binding (instancing, skinning, winding) so
/// the silhouette matches the main pass exactly on every backend. This is
/// the shared implementation behind the built-in selection mask and the
/// public object-filtered draw.
void renderObjectMask({
  required gpu.Texture target,
  required gpu.Texture depth,
  required Vector4 clearColor,
  required Matrix4 cameraTransform,
  required Vector3 cameraPosition,
  required RenderScene renderScene,
  required TransientWriter transientsBuffer,
  required int layerMask,
  required NodeFilter filter,
  required Vector4 Function(RenderItem item) colorOf,
  MaskContent content = MaskContent.flat,
}) {
  final renderTarget = gpu.RenderTarget.singleColor(
    gpu.ColorAttachment(texture: target, clearValue: clearColor),
    depthStencilAttachment: gpu.DepthStencilAttachment(
      texture: depth,
      depthClearValue: 1.0,
    ),
  );
  final commandBuffer = gpu.gpuContext.createCommandBuffer();
  final renderPass = commandBuffer.createRenderPass(renderTarget);
  final encoder = _ObjectMaskEncoder(
    renderPass,
    transientsBuffer,
    cameraTransform,
    cameraPosition,
    layerMask,
    filter,
    colorOf,
    content,
  );
  renderScene.cull(encoder.frustum, encoder.submit);
  rendererSubmissions.submit(commandBuffer);
}

/// Records each filtered item's geometry flat into a color mask. Mirrors the
/// depth-prepass encoder (standard vertex shaders, instancing/skinning,
/// winding), paired with the flat `MaskFragment`.
class _ObjectMaskEncoder {
  _ObjectMaskEncoder(
    this._renderPass,
    this._transientsBuffer,
    this._cameraTransform,
    this._cameraPosition,
    this._layerMask,
    this._filter,
    this._colorOf,
    this._content,
  ) {
    frustum = Frustum.matrix(_cameraTransform);
    _renderPass.setDepthWriteEnable(true);
    _renderPass.setColorBlendEnable(false);
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    _renderPass.setCullMode(gpu.CullMode.backFace);
    _renderPass.setWindingOrder(gpu.WindingOrder.clockwise);
  }

  final gpu.RenderPass _renderPass;
  final TransientWriter _transientsBuffer;
  final Matrix4 _cameraTransform;
  final Vector3 _cameraPosition;
  final int _layerMask;
  final NodeFilter _filter;
  final Vector4 Function(RenderItem item) _colorOf;
  final MaskContent _content;

  static final gpu.Shader _maskShader = baseShaderLibrary['MaskFragment']!;
  static final gpu.Shader _albedoShader =
      baseShaderLibrary['MaskAlbedoFragment']!;
  static final gpu.Shader _normalShader =
      baseShaderLibrary['MaskNormalFragment']!;

  gpu.Shader get _fragmentShader => switch (_content) {
    MaskContent.flat => _maskShader,
    MaskContent.albedo => _albedoShader,
    MaskContent.normal => _normalShader,
  };

  late final Frustum frustum;
  gpu.RenderPipeline? _boundPipeline;

  void submit(RenderItem item) {
    if (!item.drawsColor) return;
    if (!_filter._matches(item, _layerMask)) return;
    _renderPass.clearBindings();
    final geometry = item.geometry;
    // Skinned items draw through the full bind path below; apply this item's
    // skeleton to the (possibly shared) geometry first.
    item.applyJointsTexture(geometry);
    item.applyMorphWeights(geometry);
    // Unskinned geometry fills the mask through a position-only shader and
    // layout; skinned geometry falls back to its full vertex shader and bind.
    // A `vertex { }` material displaces geometry, so pick against its displaced
    // silhouette by running the material's vertex variant here too. This pass
    // binds the real camera, so a camera-relative displacement is correct.
    // The surface contents sample the material through the full varyings
    // (UVs, normal, tangent), so they skip the position-only path as the
    // masked depth prepass does.
    final surfaceContent = _content != MaskContent.flat;
    final depthVertex = surfaceContent ? null : geometry.depthOnlyVertex;
    final materialVertex = item.material.materialVertexShader(
      depthVertex != null ? 'depth' : geometry.materialVertexVariant,
    );
    final activeVertex =
        materialVertex ?? depthVertex?.shader ?? geometry.vertexShader;
    final fragmentShader = _fragmentShader;
    // Without the position-only path this runs the material's color vertex
    // variant, which declares its per-instance attribute inputs, so the
    // instance record has to be as wide here as in the color pass (see the
    // depth prepass encoder).
    final instanceSchema = depthVertex == null
        ? item.material.instanceAttributes
        : null;
    final attributeFloats = instanceSchema?.floatCount ?? 0;
    // The instance-rate record sits in the slot after the bound vertex
    // streams: slot 1 on the position-only path, [vertexStreamCount] on the
    // full path — and on the full path it is the wide instance-data record
    // (transform, color, material attributes), not the bare transform. The
    // first version of the surface contents bound a transform at slot 1 on
    // the full path: every object landed at a garbage transform, the mask
    // came out cleared, and the pass multiplying by it showed nothing.
    final instanceSlot = depthVertex != null ? 1 : geometry.vertexStreamCount;
    final pipeline = resolvePipeline(
      activeVertex,
      fragmentShader,
      vertexLayout:
          depthVertex?.layout ??
          geometry.instancedVertexLayoutFor(instanceSchema),
    );
    if (!identical(_boundPipeline, pipeline)) {
      _renderPass.bindPipeline(pipeline);
      _boundPipeline = pipeline;
    }
    _renderPass.setPrimitiveType(geometry.primitiveType);
    // Per item, since a double-sided geometry (a billboard) would otherwise be
    // back-face culled out of the mask. Reset for every item so it does not
    // leak to the next.
    _renderPass.setCullMode(
      geometry.isDoubleSided ? gpu.CullMode.none : gpu.CullMode.backFace,
    );
    final highlight = _colorOf(item);
    final color = Float32List(4)
      ..[0] = highlight.x
      ..[1] = highlight.y
      ..[2] = highlight.z
      ..[3] = highlight.w == 0 ? 1.0 : highlight.w;
    _renderPass.bindUniform(
      fragmentShader.getUniformSlot('MaskInfo'),
      _transientsBuffer.emplace(ByteData.sublistView(color)),
    );
    if (surfaceContent) {
      // Each surface shader declares only the sampler it reads (see
      // Material.bindMaskSurface for why the other must not be bound).
      item.material.bindMaskSurface(
        _renderPass,
        fragmentShader,
        _transientsBuffer,
        baseColor: _content == MaskContent.albedo,
        normal: _content == MaskContent.normal,
      );
    }

    // Binds the vertex/index buffers and the per-frame uniform for one draw.
    void bindDraw(Matrix4 worldTransform) {
      if (depthVertex != null) {
        geometry.bindPositionStream(_renderPass);
        bindUnskinnedFrameInfo(
          _renderPass,
          _transientsBuffer,
          activeVertex,
          _cameraTransform,
          _cameraPosition,
          depthBias: item.material.depthBias,
        );
      } else {
        geometry.bind(
          _renderPass,
          _transientsBuffer,
          worldTransform,
          _cameraTransform,
          _cameraPosition,
          shaderOverride: materialVertex,
          depthBias: item.material.depthBias,
        );
      }
      if (materialVertex != null) {
        item.material.bindVertexStage(
          _renderPass,
          materialVertex,
          _transientsBuffer,
        );
      }
    }

    final instances = item.instanceTransforms;
    if (instances != null) {
      if (geometry.instancedVertexLayout == null) {
        for (final instanceTransform in instances) {
          bindDraw(item.worldTransform * instanceTransform);
          final flip =
              item.windingFlipped != (instanceTransform.determinant() < 0);
          _renderPass.setWindingOrder(
            flip
                ? gpu.WindingOrder.counterClockwise
                : gpu.WindingOrder.clockwise,
          );
          geometry.draw(_renderPass);
        }
        return;
      }
      bindDraw(item.worldTransform);
      final PackedInstances packed = depthVertex == null
          ? packInstanceData(
              item.worldTransform,
              instances,
              item.instanceColors!,
              nodeWindingFlipped: item.windingFlipped,
              instanceWindingFlipped: item.instanceWindingFlipped,
              attributeData: item.instanceAttributeData,
              attributeFloats: attributeFloats,
              scratch: transientInstancePackingScratch,
            )
          : packInstanceTransforms(
              item.worldTransform,
              instances,
              nodeWindingFlipped: item.windingFlipped,
              scratch: transientInstancePackingScratch,
            );
      void bindPacked(Float32List buffer) {
        if (depthVertex == null) {
          bindInstanceData(_renderPass, buffer, slot: instanceSlot);
        } else {
          bindInstanceTransforms(_renderPass, buffer, slot: instanceSlot);
        }
      }
      if (packed.ccwCount > 0) {
        bindPacked(packed.ccw);
        _renderPass.setWindingOrder(gpu.WindingOrder.clockwise);
        geometry.draw(_renderPass, instanceCount: packed.ccwCount);
      }
      if (packed.cwCount > 0) {
        bindPacked(packed.cw);
        _renderPass.setWindingOrder(gpu.WindingOrder.counterClockwise);
        geometry.draw(_renderPass, instanceCount: packed.cwCount);
      }
      return;
    }

    bindDraw(item.worldTransform);
    // Only bind a model-transform instance buffer when the geometry expects one
    // at the slot after its vertex streams. A geometry that supplies its own
    // per-instance buffer (a billboard batch) sets this false; binding here
    // would clobber slot 1 and the shader would read its instance attributes as
    // a transform matrix.
    if (geometry.instancedVertexLayout != null &&
        geometry.bindsModelTransformInstance) {
      if (depthVertex == null) {
        bindSingleInstanceData(
          _renderPass,
          item.worldTransform,
          slot: instanceSlot,
          attributeFloats: attributeFloats,
        );
      } else {
        bindSingleInstanceTransform(
          _renderPass,
          item.worldTransform,
          slot: instanceSlot,
        );
      }
    }
    _renderPass.setWindingOrder(
      item.windingFlipped
          ? gpu.WindingOrder.counterClockwise
          : gpu.WindingOrder.clockwise,
    );
    geometry.draw(_renderPass);
  }
}
