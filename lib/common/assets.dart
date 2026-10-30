import 'dart:ui' show Brightness;

abstract final class Assets {
  static const digitalNum = 'digital_id_num';

  static const logo = 'assets/images/logo/logo.png';
  static const logo2 = 'assets/images/logo/logo_2.png';
  static const logoIco = 'assets/images/logo/ico/app_icon.ico';
  static const logoDark = 'assets/images/logo/logo_dark.png';
  static const logoIcoDark = 'assets/images/logo/ico/app_icon_dark.ico';

  static const vipIcon = 'assets/images/big-vip.svg';
  static const avatarPlaceHolder = 'assets/images/noface.jpeg';
  static const loading = 'assets/images/loading.png';
  static const playIcon = 'assets/images/play.png';
  static const buffering = 'assets/images/loading.webp';
  static const topicHeader = 'assets/images/topic-header-bg.png';
  static const trendingBanner = 'assets/images/trending_banner.png';
  static const ai = 'assets/images/ai.png';
  static const error = 'assets/images/error.svg';
  static const loadingDark = 'assets/images/loading_dark.png';
  static const avatarPlaceHolderDark = 'assets/images/noface_dark.jpeg';
  static const aiDark = 'assets/images/ai_dark.png';
  static const errorDark = 'assets/images/error_dark.svg';
  static const vipIconDark = 'assets/images/big-vip_dark.svg';
  static const topicHeaderDark = 'assets/images/topic-header-bg_dark.png';

  static const _darkVariants = {
    logo: logoDark,
    logoIco: logoIcoDark,
    loading: loadingDark,
    avatarPlaceHolder: avatarPlaceHolderDark,
    ai: aiDark,
    error: errorDark,
    vipIcon: vipIconDark,
    topicHeader: topicHeaderDark,
  };

  static String themed(String asset, Brightness brightness) =>
      brightness == Brightness.dark ? _darkVariants[asset] ?? asset : asset;

  static const livingChart = 'assets/images/live.gif';
  static const livingStatic = 'assets/images/live.png';
  static const livingRect = 'assets/images/live/live.gif';
  static const livingBackground = 'assets/images/live/default_bg.webp';

  static const thunder1 = 'assets/images/paycoins/ic_thunder_1.png';
  static const thunder2 = 'assets/images/paycoins/ic_thunder_2.png';
  static const thunder3 = 'assets/images/paycoins/ic_thunder_3.png';
  static const coinsEmpty = 'assets/images/paycoins/ic_22_not_enough_pay.png';
  static const coinsReadyOne = 'assets/images/paycoins/ic_22_mario.png';
  static const coinsReadyTwo = 'assets/images/paycoins/ic_22_gun_sister.png';
  static const coinTossOne = 'assets/images/paycoins/coin_toss_one.gif';
  static const coinTossTwo = 'assets/images/paycoins/coin_toss_two.gif';
  static const payBox = 'assets/images/paycoins/ic_pay_coins_box.png';
  static const coinsOne = 'assets/images/paycoins/ic_coins_one.png';
  static const coinsTwo = 'assets/images/paycoins/ic_coins_two.png';
  static const left = 'assets/images/paycoins/ic_left.png';
  static const leftDisable = 'assets/images/paycoins/ic_left_disable.png';
  static const right = 'assets/images/paycoins/ic_right.png';
  static const rightDisable = 'assets/images/paycoins/ic_right_disable.png';
  static const panelClose = 'assets/images/paycoins/ic_panel_close.png';

  static const List<String> mpvAnime4KShaders = [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_VL.glsl',
    'Anime4K_Upscale_CNN_x2_VL.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ];

  static const mpvAnime4KShadersLite = [
    'Anime4K_Clamp_Highlights.glsl',
    // 原尺寸仅执行一套恢复网络，避免重复滤波和额外中间纹理。
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_S.glsl',
  ];
}
