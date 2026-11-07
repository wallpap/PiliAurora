import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart' show Error;
import 'package:pili_aurora/pages/log_table/controller.dart';
import 'package:pili_aurora/utils/extension/widget_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class LogPage extends ConsumerWidget {
  const LogPage({required this.type, super.key});
  final LogType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(logTableProvider(type));
    Future<void> reload() => ref
        .refresh(logTableProvider(type).future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});

    final padding = MediaQuery.viewPaddingOf(context);
    return SimpleScaffold(
      appBar: AppBar(title: Text(type.title)),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(
              left: 10 + padding.left,
              right: 10 + padding.right,
              bottom: 100 + padding.bottom,
            ),
            sliver: snapshot.isLoading
                ? linearLoading
                : snapshot.hasError
                ? HttpError(
                    errMsg: (snapshot.error is Error
                        ? (snapshot.error as Error).errMsg
                        : '加载失败，请重试'),
                    onReload: reload,
                  )
                : _buildBody(snapshot.requireValue, reload),
          ),
        ],
      ).constraintWidth(constraints: const BoxConstraints(maxWidth: 680)),
    );
  }

  Widget _buildBody(
    List<LogRow> response,
    Future<void> Function() reload,
  ) {
    return response.isNotEmpty
        ? Builder(
            builder: (context) {
              final colorScheme = ColorScheme.of(context);
              final outline = colorScheme.outline.withValues(alpha: 0.1);
              final divider = Divider(height: 1, color: outline);
              final sliverDivider = SliverToBoxAdapter(child: divider);
              final dividerV = VerticalDivider(width: 1, color: outline);
              return SliverMainAxisGroup(
                slivers: [
                  sliverDivider,
                  SliverToBoxAdapter(
                    child: ColoredBox(
                      color: colorScheme.onInverseSurface,
                      child: _item(
                        type.header,
                        dividerV,
                        isHeader: true,
                      ),
                    ),
                  ),
                  sliverDivider,
                  SliverList.separated(
                    itemCount: response.length,
                    itemBuilder: (context, index) =>
                        _item(response[index], dividerV),
                    separatorBuilder: (context, index) => divider,
                  ),
                  sliverDivider,
                ],
              );
            },
          )
        : HttpError(onReload: reload);
  }

  Widget _item(LogRow item, Widget divider, {bool isHeader = false}) {
    Widget text(int flex, String text) => Expanded(
      flex: flex,
      child: Padding(
        padding: isHeader
            ? const EdgeInsets.symmetric(vertical: 6)
            : const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: isHeader
                ? const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)
                : const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );

    Widget content = Row(
      children: [
        divider,
        for (final (i, j) in item) ...[
          text(i, j),
          divider,
        ],
      ],
    );
    return IntrinsicHeight(
      child: isHeader ? content : SelectionArea(child: content),
    );
  }
}
