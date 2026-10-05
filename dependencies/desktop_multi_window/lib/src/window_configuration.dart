class WindowConfiguration {
  const WindowConfiguration({
    required this.arguments,
    this.hiddenAtLaunch = true,
    this.width,
    this.height,
    this.title,
    this.borderless = false,
    this.alwaysOnTop = false,
    this.skipTaskbar = false,
    this.alignBottomRight = false,
  });

  /// The arguments passed to the new window.
  final String arguments;

  final bool hiddenAtLaunch;

  /// Logical width of the new window. Falls back to the plugin default
  /// (800) when null. Windows only.
  final double? width;

  /// Logical height of the new window. Falls back to the plugin default
  /// (600) when null. Windows only.
  final double? height;

  /// Native window title. Windows only.
  final String? title;

  /// Strip the native caption and resize frame (borderless popup window).
  /// Windows only.
  final bool borderless;

  /// Keep the window above all non-topmost windows. Windows only.
  final bool alwaysOnTop;

  /// Hide the window's button from the taskbar (WS_EX_TOOLWINDOW).
  /// Windows only.
  final bool skipTaskbar;

  /// Place the window at the bottom-right corner of the monitor work area
  /// with a small margin. Windows only.
  final bool alignBottomRight;

  /// Returns a copy with a different [arguments] payload; all window
  /// styling fields are preserved.
  WindowConfiguration copyWithArguments(String newArguments) {
    return WindowConfiguration(
      arguments: newArguments,
      hiddenAtLaunch: hiddenAtLaunch,
      width: width,
      height: height,
      title: title,
      borderless: borderless,
      alwaysOnTop: alwaysOnTop,
      skipTaskbar: skipTaskbar,
      alignBottomRight: alignBottomRight,
    );
  }

  factory WindowConfiguration.fromJson(Map<String, dynamic> json) {
    return WindowConfiguration(
      arguments: json['arguments'] as String? ?? '',
      hiddenAtLaunch: json['hiddenAtLaunch'] as bool? ?? false,
      width: (json['width'] as num?)?.toDouble(),
      height: (json['height'] as num?)?.toDouble(),
      title: json['title'] as String?,
      borderless: json['borderless'] as bool? ?? false,
      alwaysOnTop: json['alwaysOnTop'] as bool? ?? false,
      skipTaskbar: json['skipTaskbar'] as bool? ?? false,
      alignBottomRight: json['alignBottomRight'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'arguments': arguments,
      'hiddenAtLaunch': hiddenAtLaunch,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (title != null) 'title': title,
      'borderless': borderless,
      'alwaysOnTop': alwaysOnTop,
      'skipTaskbar': skipTaskbar,
      'alignBottomRight': alignBottomRight,
    };
  }

  @override
  String toString() {
    return 'WindowConfiguration(arguments: $arguments, hiddenAtLaunch: '
        '$hiddenAtLaunch, width: $width, height: $height, title: $title, '
        'borderless: $borderless, alwaysOnTop: $alwaysOnTop, '
        'skipTaskbar: $skipTaskbar, alignBottomRight: $alignBottomRight)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WindowConfiguration &&
        other.arguments == arguments &&
        other.hiddenAtLaunch == hiddenAtLaunch &&
        other.width == width &&
        other.height == height &&
        other.title == title &&
        other.borderless == borderless &&
        other.alwaysOnTop == alwaysOnTop &&
        other.skipTaskbar == skipTaskbar &&
        other.alignBottomRight == alignBottomRight;
  }

  @override
  int get hashCode {
    return arguments.hashCode ^
        hiddenAtLaunch.hashCode ^
        width.hashCode ^
        height.hashCode ^
        title.hashCode ^
        borderless.hashCode ^
        alwaysOnTop.hashCode ^
        skipTaskbar.hashCode ^
        alignBottomRight.hashCode;
  }
}
