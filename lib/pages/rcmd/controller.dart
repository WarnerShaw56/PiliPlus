import 'dart:async';

import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:PiliPlus/features/ai_recommendation/preferences.dart';
import 'package:PiliPlus/features/ai_recommendation/repository.dart';
import 'package:PiliPlus/features/ai_recommendation/service.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';

class RcmdController extends CommonListController {
  late bool enableSaveLastData = Pref.enableSaveLastData;
  final bool appRcmd = Pref.appRcmd;
  late final bool useAiHome = AiRecommendationPreferences.replacesHome;

  final Rxn<AiRecommendationFeed> aiFeed = Rxn<AiRecommendationFeed>(
    AiRecommendationRepository.read(),
  );
  final RxnString aiError = RxnString(AiRecommendationRepository.lastError);
  final RxBool aiLoading = false.obs;

  int? lastRefreshAt;
  late bool savedRcmdTip = Pref.savedRcmdTip;

  @override
  bool get isEnd => false;

  @override
  void onInit() {
    super.onInit();
    page = 0;
    if (useAiHome) {
      if (AiRecommendationPreferences.mode == AiRecommendationMode.vps ||
          aiFeed.value == null) {
        unawaited(refreshAi());
      }
    } else {
      queryData();
    }
  }

  @override
  Future<LoadingState> customGetData() {
    return appRcmd
        ? VideoHttp.rcmdVideoListApp(freshIdx: page)
        : VideoHttp.rcmdVideoList(freshIdx: page, ps: 20);
  }

  @override
  bool handleError(String? errMsg) {
    return enableSaveLastData;
  }

  @override
  void handleListResponse(List dataList) {
    if (enableSaveLastData && page == 0) {
      if (loadingState.value case Success(:final response)) {
        if (response != null && response.isNotEmpty) {
          if (savedRcmdTip) {
            lastRefreshAt = dataList.length;
          }
          if (response.length > 200) {
            dataList.addAll(response.take(50));
          } else {
            dataList.addAll(response);
          }
        }
      }
    }
  }

  @override
  Future<void> onRefresh() {
    if (useAiHome) return refreshAi();
    page = 0;
    isEnd = false;
    return queryData();
  }

  Future<void> refreshAi() async {
    if (aiLoading.value) return;
    aiLoading.value = true;
    try {
      aiFeed.value = await AiRecommendationService().refresh();
      aiError.value = null;
    } catch (error) {
      aiError.value = error.toString();
    } finally {
      aiLoading.value = false;
    }
  }

  @override
  Future<void> onLoadMore() {
    if (useAiHome) return Future<void>.value();
    return super.onLoadMore();
  }

  @override
  Future<void> onReload() {
    if (useAiHome) return refreshAi();
    return super.onReload();
  }
}
