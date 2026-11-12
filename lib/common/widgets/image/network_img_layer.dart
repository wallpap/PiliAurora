import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';
import 'package:cached_network_image_ce/cached_network_image.dart'
    show BaseCacheManager;

class NetworkImgLayer extends StatelessWidget {
  const NetworkImgLayer({
    super.key,
    required this.src,
    required this.width,
    required this.height,
    this.type = .def,
    this.fadeOutDuration = const Duration(milliseconds: 120),
    this.fadeInDuration = const Duration(milliseconds: 120),
    this.quality = 1,
    this.borderRadius = Style.mdRadius,
    this.getPlaceHolder,
    this.fit = .cover,
    this.alignment = .center,
    this.cacheWidth,
    this.sourceSize,
    this.cacheManager,
  });

  final String? src;
  final double width;
  final double height;
  final ImageType type;
  final Duration fadeOutDuration;
  final Duration fadeInDuration;
  final int quality;
  final BorderRadius borderRadius;
  final ValueGetter<Widget>? getPlaceHolder;
  final BoxFit fit;
  final Alignment alignment;
  final bool? cacheWidth;
  final Size? sourceSize;
  final BaseCacheManager? cacheManager;

  static Color? reduceLuxColor = Pref.reduceLuxColor;
  static bool reduce = false;

  @override
  Widget build(BuildContext context) {
    final isEmote = type == ImageType.emote;
    final isAvatar = type == ImageType.avatar;
    if (src?.isNotEmpty == true) {
      Widget child = _buildImage(context, isEmote: isEmote, isAvatar: isAvatar);
      if (isEmote) {
        return child;
      } else if (isAvatar) {
        return ClipOval(child: child);
      } else {
        return ClipRRect(borderRadius: borderRadius, child: child);
      }
    } else {
      return getPlaceHolder?.call() ??
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar);
    }
  }

  Widget _buildImage(
    BuildContext context, {
    required bool isEmote,
    required bool isAvatar,
  }) {
    int? memCacheWidth, memCacheHeight;
    final decodeTarget =
        width.isFinite && height.isFinite && width > 0 && height > 0
        ? ImageDecodeTarget.forDisplay(
            Size(width, height),
            MediaQuery.devicePixelRatioOf(context),
            fit,
          )
        : null;
    if (sourceSize case final source?
        when decodeTarget != null &&
            source.width.isFinite &&
            source.height.isFinite &&
            source.width >= 1 &&
            source.height >= 1) {
      final target = decodeTarget.targetSize(
        source.width.toInt(),
        source.height.toInt(),
      );
      memCacheWidth = target.width;
      memCacheHeight = target.height;
    } else if (cacheWidth ?? width <= height) {
      memCacheWidth = width.cacheSize(context);
    } else {
      memCacheHeight = height.cacheSize(context);
    }
    return CachedImage(
      cacheManager: cacheManager,
      imageUrl:
          sourceSize == null &&
              (fit == BoxFit.cover ||
                  fit == BoxFit.fitHeight ||
                  fit == BoxFit.fitWidth)
          ? ImageUtils.thumbnailUrl(src, quality)
          : ImageUtils.thumbnailUrlForSize(
              src,
              quality: quality,
              width: memCacheWidth,
              height: memCacheHeight,
            ),
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      // 限制列表长图的解码面积；原图查看器单独按原始分辨率加载。
      maxDecodePixels: 1 << 20,
      decodeTarget: decodeTarget,
      fit: fit,
      alignment: alignment,
      fadeOutDuration: fadeOutDuration,
      fadeInDuration: fadeInDuration,
      filterQuality: FilterQuality.low,
      placeholder: (_, _) =>
          getPlaceHolder?.call() ??
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar),
      errorBuilder: (_, _, _) =>
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar),
      colorBlendMode: reduce ? BlendMode.modulate : null,
      color: reduce ? reduceLuxColor : null,
    );
  }

  Widget _placeholder(
    BuildContext context, {
    required bool isEmote,
    required bool isAvatar,
  }) {
    return Container(
      width: width,
      height: height,
      clipBehavior: isEmote ? Clip.none : Clip.antiAlias,
      decoration: BoxDecoration(
        shape: isAvatar ? BoxShape.circle : BoxShape.rectangle,
        color: ColorScheme.of(context).onInverseSurface.withValues(alpha: 0.4),
        borderRadius: isEmote || isAvatar ? null : borderRadius,
      ),
      child: Center(
        child: Image.asset(
          Assets.themed(
            isAvatar ? Assets.avatarPlaceHolder : Assets.loading,
            Theme.of(context).brightness,
          ),
          width: width,
          height: height,
          cacheWidth: width.cacheSize(context),
          colorBlendMode: reduce ? BlendMode.modulate : null,
          color: reduce ? reduceLuxColor : null,
        ),
      ),
    );
  }
}
