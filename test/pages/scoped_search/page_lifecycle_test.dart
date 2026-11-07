import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/common/search/scoped_search.dart';
import 'package:pili_aurora/pages/common/search/scoped_search_page.dart';

class _Results extends ScopedSearchNotifier {
  _Results(super.query);

  @override
  Future<ScopedSearchState> build() async => ScopedSearchState(
    items: List.generate(40, (i) => '${query.keyword} $i'),
    nextPage: 2,
    hasMore: false,
  );
}

class _Page extends ConsumerStatefulWidget {
  const _Page(this.query, {super.key});
  final ScopedSearchQuery query;
  @override
  ConsumerState<_Page> createState() => _PageState();
}

class _PageState extends ScopedSearchPageState<_Page> {
  @override
  ScopedSearchQuery queryFor(_Page widget) => widget.query;
  @override
  EdgeInsets get contentPadding => EdgeInsets.zero;
  @override
  Widget get buildLoading => const SliverToBoxAdapter(child: Text('loading'));
  @override
  Widget buildBody(List items) => SliverFixedExtentList.builder(
    itemExtent: 100,
    itemCount: items.length,
    itemBuilder: (_, i) => Text(items[i] as String),
  );
}

void main() {
  testWidgets(
    'owner replacement resets scroll, same owner rebuild preserves it',
    (
      tester,
    ) async {
      final key = GlobalKey<_PageState>();
      final first = (
        kind: ScopedSearchKind.user,
        keyword: 'first',
        mid: null,
        owner: Object(),
      );
      final second = (
        kind: ScopedSearchKind.user,
        keyword: 'second',
        mid: null,
        owner: Object(),
      );
      final container = ProviderContainer(
        overrides: [
          scopedSearchProvider(first).overrideWith(() => _Results(first)),
          scopedSearchProvider(second).overrideWith(() => _Results(second)),
        ],
      );
      addTearDown(container.dispose);
      Future<void> mount(ScopedSearchQuery query) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: _Page(query, key: key)),
          ),
        );
        await tester.pumpAndSettle();
      }

      await mount(first);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      position.jumpTo(900);
      await tester.pumpAndSettle();
      await mount(first);
      expect(position.pixels, 900);
      await mount(second);
      expect(position.pixels, 0);
      expect(find.text('second 0'), findsOneWidget);
      position.jumpTo(900);
      key.currentState!.scrollToTop();
      await tester.pumpAndSettle();
      expect(position.pixels, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
