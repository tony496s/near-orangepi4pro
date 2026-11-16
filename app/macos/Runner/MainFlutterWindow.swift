import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Same logical size as the 1480x320 bar display on the board.
    self.setContentSize(NSSize(width: 1480, height: 320))
    self.contentMinSize = NSSize(width: 1480, height: 320)
    self.contentMaxSize = NSSize(width: 1480, height: 320)
    self.title = "Near"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
