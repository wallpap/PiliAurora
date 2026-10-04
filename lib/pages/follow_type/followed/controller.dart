import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/models/remote/follow/data.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';

class FollowedController extends FollowTypeController {
  @override
  Future<LoadingState<FollowData>> customGetData() =>
      UserHttp.followedUp(mid: mid, pn: page);
}
