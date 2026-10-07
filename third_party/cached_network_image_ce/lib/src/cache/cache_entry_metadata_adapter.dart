import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:hive_ce/hive.dart';

class CacheEntryMetadataAdapter extends TypeAdapter<CacheEntryMetadata> {
  @override
  final int typeId = 122;

  @override
  CacheEntryMetadata read(BinaryReader reader) => CacheEntryMetadata(
        url: reader.readString(),
        fileExtension: reader.readString(),
        validTill: DateTime.fromMillisecondsSinceEpoch(reader.readInt()),
        length: reader.readUint32(),
        eTag: reader.read(),
      );

  @override
  void write(BinaryWriter writer, CacheEntryMetadata obj) {
    writer
      ..writeString(obj.url)
      ..writeString(obj.fileExtension)
      ..writeInt(obj.validTill.millisecondsSinceEpoch)
      ..writeUint32(obj.length)
      ..write(obj.eTag);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CacheEntryMetadataAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
