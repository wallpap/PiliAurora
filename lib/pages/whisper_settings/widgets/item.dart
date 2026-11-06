import 'dart:math';

import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart'
    show SelectItem, Setting, SettingSwitch;
import 'package:material_ui/material_ui.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class ImSettingsItem extends StatelessWidget {
  const ImSettingsItem({
    super.key,
    required this.item,
    required this.onSet,
    required this.onRedirect,
  });

  final Setting item;
  final Future<void> Function(Setting setting) onSet;
  final VoidCallback onRedirect;

  @override
  Widget build(BuildContext context) {
    const titleStyle = TextStyle(fontSize: 14);
    final colorScheme = ColorScheme.of(context);
    final outline = colorScheme.outline;
    final subtitleStyle = TextStyle(fontSize: 13, color: outline);

    if (item.hasSwitch_1()) {
      Future<void> onChanged() async {
        final updated = item.deepCopy();
        updated.switch_1.switchOn = !updated.switch_1.switchOn;
        await onSet(updated);
      }

      return ListTile(
        dense: true,
        onTap: onChanged,
        title: Text(
          item.switch_1.title,
          style: titleStyle,
        ),
        subtitle: item.switch_1.hasSubtitle()
            ? Text(item.switch_1.subtitle, style: subtitleStyle)
            : null,
        trailing: Transform.scale(
          alignment: Alignment.centerRight,
          scale: 0.8,
          child: Switch(
            value: item.switch_1.switchOn,
            onChanged: (value) => onChanged(),
          ),
        ),
      );
    }

    if (item.hasRedirect()) {
      SelectItem? selected;
      SettingSwitch? sw1tch;
      if (item.redirect.settingPage.subSettings.isNotEmpty) {
        for (final subItem in item.redirect.settingPage.subSettings.values) {
          if (subItem.hasSelect()) {
            for (final i in subItem.select.item) {
              if (i.selected) {
                selected = i;
                break;
              }
            }
          } else if (subItem.hasSwitch_1()) {
            if (subItem.switch_1.switchOn) {
              sw1tch = subItem.switch_1;
              break;
            }
          }
        }
      }
      return ListTile(
        dense: true,
        onTap: onRedirect,
        title: Text(
          item.redirect.title,
          style: titleStyle,
        ),
        subtitle: item.redirect.hasSubtitle()
            ? Text(item.redirect.subtitle, style: subtitleStyle)
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected != null)
              Text(
                selected.text,
                style: TextStyle(fontSize: 13, color: outline),
              )
            else if (sw1tch != null)
              Text(
                sw1tch.title,
                style: TextStyle(fontSize: 13, color: outline),
              )
            else if (item.redirect.hasSelectedSummary())
              Text(
                item.redirect.selectedSummary,
                style: TextStyle(fontSize: 13, color: outline),
              ),
            Icon(color: outline, Icons.keyboard_arrow_right),
          ],
        ),
      );
    }

    if (item.hasSelect()) {
      late final divider = Divider(
        height: 1,
        indent: 16,
        color: outline.withValues(alpha: 0.1),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(
          max(0, item.select.item.length * 2 - 1),
          (index) {
            if (index.isOdd) {
              return divider;
            }
            final e = item.select.item[index ~/ 2];
            return ListTile(
              dense: true,
              onTap: () async {
                if (e.selected) return;
                final updated = item.deepCopy();
                for (final option in updated.select.item) {
                  option.selected = option.text == e.text;
                }
                await onSet(updated);
              },
              title: Text(e.text, style: titleStyle),
              trailing: e.selected
                  ? Icon(size: 20, Icons.check, color: colorScheme.primary)
                  : null,
            );
          },
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
