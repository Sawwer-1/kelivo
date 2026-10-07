import 'dart:async';

enum ChatAction {
  newTopic,
  toggleLeftPanelAssistants,
  toggleLeftPanelTopics,
  focusInput,
  switchModel,
  enterGlobalSearch,
  exitGlobalSearch,
}

/// F2 QuickCapture: a screenshot-plus-question ready to go through the
/// normal composer path. Emitted by QuickCaptureService, consumed where the
/// [HomePageController] lives (home_page.dart).
class QuickCaptureSend {
  const QuickCaptureSend({required this.text, required this.imagePath});

  final String text;
  final String imagePath;
}

class ChatActionBus {
  ChatActionBus._();
  static final ChatActionBus instance = ChatActionBus._();

  final _controller = StreamController<ChatAction>.broadcast();
  final _quickCaptureController =
      StreamController<QuickCaptureSend>.broadcast();
  Stream<ChatAction> get stream => _controller.stream;
  Stream<QuickCaptureSend> get quickCaptureSends =>
      _quickCaptureController.stream;
  void fire(ChatAction action) => _controller.add(action);
  void fireQuickCaptureSend(QuickCaptureSend payload) =>
      _quickCaptureController.add(payload);
  void dispose() {
    _controller.close();
    _quickCaptureController.close();
  }
}
