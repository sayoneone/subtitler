import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let help = HelpWindowController()
  private var helpChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // «Как пользоваться» (lib/ui/help/help_window.dart): {"title": …}.
    let channel = FlutterMethodChannel(
      name: "ru.subtitler/help",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "open", let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let title = (call.arguments as? [String: Any])?["title"] as? String
      result(self.help.show(title: title ?? "Subtitler", beside: self))
    }
    helpChannel = channel

    // Программа заканчивается вместе с главным окном — руководство тоже.
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: self, queue: .main
    ) { [weak self] _ in
      self?.help.close()
    }

    super.awakeFromNib()
  }
}

/// Окно «Как пользоваться»: своё окно со своим движком Flutter и точкой
/// входа helpMain из lib/main.dart. Плагины ему не нужны и не
/// регистрируются. На Windows то же делает windows/runner/help_window.cpp.
final class HelpWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var engine: FlutterEngine?

  /// Открывает окно рядом с [beside] или выводит вперёд уже открытое.
  /// Возвращает, на экране ли оно.
  func show(title: String, beside main: NSWindow) -> Bool {
    if let window = window {
      window.makeKeyAndOrderFront(nil)
      return true
    }
    // Каждый новый движок ставит себя обработчиком выхода программы
    // (FlutterAppDelegate.terminationHandler — слабая ссылка, в открытых
    // заголовках её нет). Не вернуть главный — и выход спрашивал бы окно
    // руководства, а после его закрытия никого: программа закрывалась бы
    // мимо AppShell._onExitRequested, не дописав правки и журнал.
    let delegate = NSApp.delegate as? NSObject
    let handlerKey = "terminationHandler"
    let canRestore =
      delegate?.responds(to: NSSelectorFromString(handlerKey)) == true
      && delegate?.responds(to: NSSelectorFromString("setTerminationHandler:")) == true
    let mainHandler = canRestore ? delegate?.value(forKey: handlerKey) : nil

    let engine = FlutterEngine(name: "help", project: nil, allowHeadlessExecution: false)
    // Без окна движок не запускается: сначала вид, потом запуск.
    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    guard engine.run(withEntrypoint: "helpMain") else { return false }
    if let mainHandler = mainHandler {
      delegate?.setValue(mainHandler, forKey: handlerKey)
    }
    let window = NSWindow(contentViewController: controller)
    window.title = title
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.setContentSize(NSSize(width: 900, height: 860))
    // У правого края экрана главного окна: при первом запуске нужны оба —
    // руководство и поле ключа в главном окне.
    if let screen = main.screen ?? NSScreen.main {
      let work = screen.visibleFrame
      var frame = window.frame
      frame.size.height = min(frame.size.height, work.height)
      frame.origin.x = max(work.minX, work.maxX - frame.width - 16)
      frame.origin.y = work.maxY - frame.height
      window.setFrame(frame, display: false)
    } else {
      window.center()
    }
    window.makeKeyAndOrderFront(nil)
    self.window = window
    self.engine = engine
    return true
  }

  func close() {
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
    engine?.shutDownEngine()
    engine = nil
  }
}
