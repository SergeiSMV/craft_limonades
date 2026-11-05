/// Константы для размеров.
abstract final class AppSizes {
  //* --- Icon Sizes ------------------------------------------------------- *//
  static const double kIcon2 = 2;
  static const double kIcon4 = 4;
  static const double kIcon6 = 6;
  static const double kIcon10 = 10;
  static const double kIcon16 = 16;
  static const double kIcon18 = 18;
  static const double kIcon20 = 20;
  static const double kIcon24 = 24;
  static const double kIcon25 = 25;
  static const double kIcon28 = 28;
  static const double kIcon30 = 30;
  static const double kIcon36 = 36;
  static const double kIcon40 = 40;
  static const double kIcon48 = 48;
  static const double kIcon50 = 50;
  static const double kIcon56 = 56;
  static const double kIcon60 = 60;
  static const double kIcon64 = 64;
  static const double kIcon80 = 80;
  static const double kIcon85 = 85;
  static const double kIcon90 = 90;
  static const double kIcon96 = 96;
  static const double kIcon140 = 140;
  static const double kIcon180 = 180;
  static const double kIcon200 = 200;
  static const double kIcon256 = 256;

  //* --- Служебные экраны -------------------------------------------------- *//
  /// Ширина колонки подписей в сводке диагностики сканера.
  static const double kProbeLabelWidth = 150;

  //* --- Маркеры ---------------------------------------------------------- *//
  static const double kDotMark = 8; // точка-отметка выбранного варианта

  //* --- Text Sizes ------------------------------------------------------- *//
  static const double kText12 = 12;
  static const double kText13 = 13;
  static const double kText14 = 14;
  static const double kText15 = 15;
  static const double kText16 = 16;
  static const double kText18 = 18;
  static const double kText20 = 20;
  static const double kText22 = 22;
  static const double kText24 = 24;
  static const double kText28 = 28;
  static const double kText32 = 32;
  static const double kText48 = 48;

  //* --- Image Sizes ------------------------------------------------------ *//
  static const double kImagePlaceholder =
      240; // иллюстрация-заглушка (ошибка/пусто)
  static const double kPhotoThumb =
      96; // миниатюра фото проблемы склада (ADHOC-45): три в ряд на ширине ТСД

  //* --- Button Sizes ----------------------------------------------------- *//
  static const double kButtonHeight64 = 64;

  //* --- Web-портал (layout) ---------------------------------------------- *//
  static const double kSidebarWidth = 240; // боковая панель портала (ADHOC-56)
  // Окно портала уже — меню уезжает в выдвижную панель (ADHOC-25); порог md Polaris (ADHOC-56).
  static const double kPortalCompactWidth = 768;
  // Плоский стиль портала (ADHOC-56).
  static const double kControlHeight = 32; // кнопка, поле ввода
  static const double kNavItemHeight = 36; // пункт бокового меню
  // Подпись раздела слева от карточки — при ширине от этой; уже — над карточкой.
  static const double kAnnotatedWidth = 720;
  // Разделы настроек списком слева — при ширине от этой; уже — вкладками сверху.
  static const double kSettingsNavWidth = 960;
  static const double kSettingsNavColumn = 200; // колонка разделов настроек
  static const double kSettingsMaxWidth = 1160; // предел ширины страницы настроек
  // Меню фильтра списка (ADHOC-56): не шире и не выше — длинный справочник прокручивается.
  static const double kPortalSelectMenuWidth = 440;
  static const double kPortalSelectMenuMargin = 32; // меню уже экрана на поля по краям
  // Подписи пункта меню не достаётся: отступы пункта (24), галочка (16) с зазором, поля меню.
  static const double kPortalSelectItemReserve = 64;
  static const double kPortalSelectMenuHeight = 360;
  // Номенклатура склада (ADHOC-56): от этой ширины карточки — колонками, уже — строками.
  static const double kGoodsColumnsWidth = 720;
  static const double kGoodsColCode = 96; // колонка «Код»
  static const double kGoodsColUom = 56; // колонка «Ед.»
  static const double kGoodsColQty = 104; // колонка «Остаток» (с единицей)
  static const double kGoodCardLabel = 184; // подпись реквизита в карточке товара
  static const double kPortalListMaxWidth = 1200; // предел ширины страницы-списка
  // Ячейки (ADHOC-57): карточка ячейки справа от списка — при ширине страницы от порога; уже —
  // окном по нажатию на строку. Список колонками — от своей ширины карточки, уже — строками.
  static const double kCellsSideWidth = 340;
  static const double kCellsSearchWidth = 260; // поиск по адресу на панели
  static const double kCellsSideMinPage = 960;
  static const double kCellsColumnsWidth = 600;
  static const double kCellsColRack = 72; // колонка «Стеллаж»
  static const double kCellsColTier = 48; // колонка «Ярус»
  static const double kCellsColPos = 64; // колонка «Позиция»
  static const double kCellsColBeam = 96; // колонка «Балка»
  static const int kCellsRackPreview = 4; // стеллажей выборки называем, остальные — числом
  static const double kPortalCheckbox = 18; // галочка портала
  static const double kPortalCheckboxMark = 14; // галочка или черта внутри
  static const double kDisabledOpacity = 0.5; // недоступная кнопка портала
  // Строка документа уже — кнопки уходят под текст, иначе заголовку остаётся пара букв.
  // Таблица документов (ADHOC-26) — пороги по ширине самой таблицы: от «полных действий» —
  // кнопки с подписями, уже — иконками; уже минимума (телефон) — строки вместо таблицы.
  static const double kDocTableFullActionsWidth = 900;
  // Минимум — сумма минимумов колонок с компактными действиями (~780) с запасом: уже него таблица
  // шире своей плашки, и плашка молча обрезала бы действия.
  static const double kDocTableMinWidth = 840;
  static const double kDocSearchMaxWidth = 460; // поле поиска над таблицей
  // Колонки: документ и контрагент делят остаток долями, но не уже минимума; время, статус
  // и действия — по содержимому.
  static const double kColDoc = 2;
  static const double kColParty = 3;
  static const double kColDocMin = 140;
  static const double kColPartyMin = 180;
  static const double kHeaderHeight = 72; // верхняя панель контента
  // Неактивная позиция на ТСД — серая, пока не отсканировано её место (ADHOC-31).
  static const double kInactiveOpacity = 0.45;
  // Календарь портала в диалоге (ADHOC-30): ширина и высота сетки месяца.
  static const double kPortalCalendarWidth = 320;
  static const double kPortalCalendarHeight = 340;
  // Список выбора из справочника в диалоге портала (ADHOC-30), не выше.
  static const double kPortalPickListMaxHeight = 220;
  static const double kPortalDialogWidth =
      520; // диалог с таблицей или выбором (пересчёт, P10-05)
  static const double kPortalTreeIndent =
      16; // отступ уровня дерева групп в выборе (P10-05)
  static const double kContentMaxWidth =
      900; // предел ширины карточки (по макету)
  static const double kFormWidth = 480; // правая панель формы входа
  static const double kFormHeight = 700; // высота правой панели формы входа
  static const double kBrandMaxWidth = 500; // бренд-текст на панели входа
  static const double kLoginFieldHeight = 48; // поле логина и пароля — в рост прежних

  //* --- ТСД: главное меню (плитки) --------------------------------------- *//
  static const double kMenuTileSpacing = 12; // зазор между плитками сетки
  static const double kChipSpacing = 8; // зазор между чипами быстрых фильтров
  static const double kMenuTileAspect =
      1.05; // соотношение сторон плитки (≈квадрат)
}
