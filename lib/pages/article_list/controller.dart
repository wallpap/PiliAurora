import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/models/model_owner.dart';
import 'package:pili_aurora/models/remote/article/article_list/article.dart';
import 'package:pili_aurora/models/remote/article/article_list/list.dart';
import 'package:pili_aurora/services/account_providers.dart';

class ArticleCollection {
  ArticleCollection({
    required this.list,
    required this.author,
    required Iterable<ArticleListItemModel> articles,
  }) : articles = List.unmodifiable(articles);
  final ArticleListInfo? list;
  final Owner? author;
  final List<ArticleListItemModel> articles;
}

final articleCollectionProvider = FutureProvider.autoDispose
    .family<ArticleCollection, String>((ref, id) async {
      final account = ref.watch(mainAccountProvider);
      final data = (await DynamicsHttp.articleList(
        id: id,
        account: account,
      )).data;
      return ArticleCollection(
        list: data.list,
        author: data.author,
        articles: data.articles ?? [],
      );
    }, retry: (_, _) => null);
