import AppKit
import SwiftUI

/// Multi-line composer backed by `NSTextView`.
///
/// It grows from one to five lines and then scrolls inside itself, so a long
/// draft never gets clipped and the mouse wheel keeps working.
struct MessageEditor: View {
    @Binding var text: String
    var isEnabled: Bool
    var placeholder: String = "Сообщение"
    var onSend: () -> Void

    @State private var editorHeight: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 1)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }

            MessageTextView(
                text: $text,
                isEnabled: isEnabled,
                onSend: onSend,
                height: $editorHeight
            )
            .frame(height: editorHeight)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Palette.input, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MessageTextView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var onSend: () -> Void
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        let font = NSFont.systemFont(ofSize: 13)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = NSColor(Palette.text)
        textView.insertionPointColor = NSColor(Palette.accent)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.heightTracksTextView = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.string = text
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor(Palette.text)
        ]

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.wasEnabled = isEnabled

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight()
            if isEnabled {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = textView.string.utf16.count
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }

        if textView.isEditable != isEnabled {
            textView.isEditable = isEnabled
        }

        let justEnabled = isEnabled && !context.coordinator.wasEnabled
        context.coordinator.wasEnabled = isEnabled

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight()
            if justEnabled {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var wasEnabled = false

        private var lastHeight: CGFloat = 0

        init(_ parent: MessageTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            recalculateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            // Shift+Enter inserts a newline, plain Enter sends the message.
            if NSEvent.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSend()
            return true
        }

        func recalculateHeight() {
            guard
                let textView,
                let layoutManager = textView.layoutManager,
                let container = textView.textContainer
            else {
                return
            }

            if let scrollView, scrollView.contentSize.width > 0 {
                let width = scrollView.contentSize.width
                if abs(container.containerSize.width - width) > 0.5 {
                    container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                }
            }

            layoutManager.ensureLayout(for: container)
            let font = textView.font ?? NSFont.systemFont(ofSize: 13)
            let lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
            let insets = textView.textContainerInset.height * 2
            let minHeight = lineHeight + insets
            let maxHeight = lineHeight * 5 + insets
            let used = layoutManager.usedRect(for: container).height + insets
            let target = min(max(used, minHeight), maxHeight)

            guard abs(target - lastHeight) > 0.5 else { return }
            lastHeight = target

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if abs(self.parent.height - target) > 0.5 {
                    self.parent.height = target
                }
            }
        }
    }
}
