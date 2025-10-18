import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.setContentSize(NSSize(width: 1400, height: 850))

    // Hide the titlebar and let content flow behind it.
    self.styleMask.insert([.fullSizeContentView])
    self.titleVisibility = TitleVisibility.hidden
    self.titlebarAppearsTransparent = true

    // Create a toolbar and make it unified so we can push down the traffic lights.
    self.toolbar = NSToolbar()
    self.toolbarStyle = .unified

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
