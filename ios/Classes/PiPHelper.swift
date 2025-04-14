import AVKit
import Flutter
import Foundation
import UIKit

class PiPHelper: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPHelper()
    
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var pipController: AVPictureInPictureController?
    
    private var observer: NSObjectProtocol?
    
    private var isEnable: Bool = false
    private var rootWindow: UIWindow?
    
    private var registrar: FlutterPluginRegistrar?
    
    public func setRegistrar(_ registrar: FlutterPluginRegistrar) {
        if self.registrar == nil {
            self.registrar = registrar
        }
    }
    
    var channels: [Int: FlutterMethodChannel] = [:]
    
    public func newFlutterMethodChannel(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "fl_pip", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            self.handle(call, result: result)
        }
        channels[messenger.hash] = channel
    }
    
    private var enableArgs: [String: Any?] = [:]
    
    private var isCallDisable: Bool = false
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "enable":
            if isAvailable(), !isEnable {
                enableArgs = call.arguments as! [String: Any?]
                rootWindow = windows()?.filter { window in
                    window.isKeyWindow
                }.first
                isEnable = enable()
                result(isEnable)
                return
            }
            result(false)
        case "disable":
            isCallDisable = true
            dispose()
            enableArgs = [:]
            setPiPStatus(1)
            result(true)
        case "isActive":
            var map: [String: Any] = [:]
            if isAvailable() {
                map["status"] = (pipController?.isPictureInPictureActive ?? false) ? 0 : 1
            } else {
                map["status"] = 2
            }
            result(map)
        case "toggle":
            let value = call.arguments as! Bool
            if value {
                /// 切换前台
            } else {
                /// 切换后台
                background()
            }
            result(nil)
        case "available":
            result(isAvailable())
        default:
            result(nil)
        }
    }
    
    var audioPath: String?
    
    func enable() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("FlPiP error : AVAudioSession.sharedInstance()")
            return false
        }
        var videoPath = enableArgs["videoPath"] as! String
        
        //默认16.9
        var aspectRatio = 16.0 / 9.0
        if let rate = enableArgs["aspectRatio"] as? [String : Any],
           let width = rate["numerator"] as? Double,
           let height = rate["denominator"] as? Double {
            aspectRatio = width / height
        }
        let packageName = enableArgs["packageName"] as? String
        if registrar != nil {
            if packageName != nil {
                videoPath = registrar!.lookupKey(forAsset: videoPath, fromPackage: packageName!)
            } else {
                if !videoPath.hasPrefix("/var/mobile") {
                    videoPath = registrar!.lookupKey(forAsset: videoPath)
                }
            }
        }
        
        if isAvailable() {
            if rootWindow == nil {
                print("FlPiP error : rootWindow is null")
                return false
            }
            
            playerLayer = AVPlayerLayer()
            
            let x = enableArgs["left"] as? CGFloat ?? 0
            let y = enableArgs["top"] as? CGFloat ?? 0
            let width = enableArgs["width"] as? CGFloat ?? UIScreen.main.bounds.size.width
            let height = width / aspectRatio
            
            playerLayer!.frame = .init(x: x, y: y, width: width, height: height)
            
            player = AVPlayer(url: URL(fileURLWithPath: videoPath))
            playerLayer!.player = player
            playerLayer?.videoGravity = .resizeAspectFill
            //            player!.allowsExternalPlayback = true
            //            player!.accessibilityElementsHidden = true
            pipController = AVPictureInPictureController(playerLayer: playerLayer!)
            pipController!.delegate = self
            
            let enableControls = enableArgs["enableControls"] as! Bool
            pipController!.setValue(enableControls ? 0 : 1, forKey: "controlsStyle")
            
            let enablePlayback = enableArgs["enablePlayback"] as! Bool
            pipController!.setValue(enablePlayback ? 0 : 1, forKey: "requiresLinearPlayback")
            
            if #available(iOS 14.2, *) {
                pipController!.canStartPictureInPictureAutomaticallyFromInline = true
            }
            player!.play()
            rootWindow!.rootViewController?.view?.layer.addSublayer(playerLayer!)
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.4) {
                self.pipController!.startPictureInPicture()
                UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
            }
            
            observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { [weak player] _ in
                player?.seek(to: CMTime.zero)
                player?.play()
            }
            
            return true
        }
        return false
    }
    
    
    public func background() {
        /// 切换后台
        let targetSelect = #selector(NSXPCConnection.suspend)
        if UIApplication.shared.responds(to: targetSelect) {
            UIApplication.shared.perform(targetSelect)
        }
    }
    
    public func isAvailable() -> Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }
    
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if let firstWindow = UIApplication.shared.windows.first, rootWindow != nil {
            let rect = firstWindow.rootViewController?.view.frame ?? CGRect(x: 0, y: 0, width: UIScreen.main.bounds.size.width, height: UIScreen.main.bounds.size.height)
            setPiPStatus(0)
        }
    }
    
    func setPiPStatus(_ int: Int) {
        channels.forEach { channel in
            channel.value.invokeMethod("onPiPStatus", arguments: ["status": int])
        }
    }
    
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if !isCallDisable {
            dispose()
        }
    }
    
    public func dispose() {
        pipController?.stopPictureInPicture()
        if let ob = observer {
            NotificationCenter.default.removeObserver(ob)
        }
        if rootWindow != nil {
            let rect = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.size.width, height: UIScreen.main.bounds.size.height)
            let firstWindow = UIApplication.shared.windows.first
            if firstWindow!.rootViewController is FlutterViewController {
                let flController = (firstWindow!.rootViewController as! FlutterViewController)
                let engine = flController.engine
                engine.viewController = nil
                let newController = FlutterViewController(engine: flController.engine, nibName: flController.nibName, bundle: flController.nibBundle)
                flController.dismiss(animated: true)
                firstWindow!.rootViewController = nil
                newController.view.frame = rect
                rootWindow?.rootViewController = newController
            }
        }
        isCallDisable = false
        pipController = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        setPiPStatus(1)
        isEnable = false
        
    }
    
    public func applicationWillEnterForeground(_ application: UIApplication) {
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.4) {
            self.pipController?.stopPictureInPicture()
        }
        
    }
    
    public func applicationDidEnterBackground(_ application: UIApplication) {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.4) {
            self.pipController?.startPictureInPicture()
        }
    }
    
    public func windows() -> [UIWindow]? {
        return UIApplication.shared.windows
    }
}
