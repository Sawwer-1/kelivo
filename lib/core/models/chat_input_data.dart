class DocumentAttachment {
  final String path; // absolute file path
  final String fileName;
  final String mime; // e.g. application/pdf, text/plain

  const DocumentAttachment({
    required this.path,
    required this.fileName,
    required this.mime,
  });
}

class ChatInputData {
  final String text;
  final List<String> imagePaths; // absolute file paths or data URLs
  final List<DocumentAttachment> documents; // selected files
  final bool allowImagesApiRouting;

  const ChatInputData({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.allowImagesApiRouting = true,
  });
}

/// Result of a composer submission.
///
/// [steered] means the text was accepted as a D1 steering instruction: it
/// will be delivered to the running generation's tool loop between rounds.
/// Consumers must treat it like [sent] (clear the composer); optional UI can
/// additionally show a "delivered mid-generation" hint.
enum ChatInputSubmissionResult { sent, steered, queued, rejected }

class QueuedChatInput {
  final String conversationId;
  final ChatInputData input;

  const QueuedChatInput({required this.conversationId, required this.input});
}
