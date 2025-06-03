import 'package:ai_buddy/feature/gemini/gemini.dart';

// ignore: avoid_classes_with_only_static_members
class ContentValidator {
  /// Clean and validate content to prevent duplicates
  static Content cleanContent(Content content) {
    final uniqueParts = <Parts>[];
    final seenTexts = <String>{};

    for (final part in content.parts ?? <Parts>[]) {
      if (part.text != null &&
          part.text!.isNotEmpty &&
          !seenTexts.contains(part.text!)) {
        // Fixed: Added ! to ensure non-null
        seenTexts.add(part.text!);
        uniqueParts.add(part);
      }
    }

    return Content(parts: uniqueParts);
  }

  /// Validate content before API calls
  static bool isValidContent(Content content) {
    return content.parts != null &&
        content.parts!.isNotEmpty &&
        content.parts!.any((Parts part) =>
            part.text?.isNotEmpty == true); // Fixed: Explicit type
  }
}
