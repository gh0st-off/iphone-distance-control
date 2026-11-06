// iOSAgent — iOS jailbreak remote agent
// Runtime: iOS 16.7, jailbroken
// FILL: change SERVER_IP ligne 13

import Foundation
import UIKit
import UserNotifications
import CoreLocation

// ─── CONFIG ──────────────────────────────────────────────────────────────────

let SERVER_IP   = "192.168.1.22"   // FILL: IP de ton ordi
let SERVER_PORT = 4747
let DEVICE_ID   = ProcessInfo.processInfo.environment["HOSTNAME"] ?? UUID().uuidString

// ─── LOCATION HELPER ─────────────────────────────────────────────────────────

class LocationHelper: NSObject, CLLocationManagerDelegate {
    static let shared = LocationHelper()
    private let mgr   = CLLocationManager()
    private var callback: ((CLLocation?) -> Void)?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.requestAlwaysAuthorization()
    }

    func getOnce(_ cb: @escaping (CLLocation?) -> Void) {
        callback = cb
        mgr.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        callback?(locs.last); callback = nil
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        callback?(nil); callback = nil
    }
}

// ─── AGENT CORE ──────────────────────────────────────────────────────────────

class AgentCore: NSObject, URLSessionWebSocketDelegate {
    var task:           URLSessionWebSocketTask?
    var session:        URLSession?
    var reconnectTimer: Timer?

    func start() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        connect()
    }

    func connect() {
        let url = URL(string: "ws://\(SERVER_IP):\(SERVER_PORT)/agent")!
        task    = session!.webSocketTask(with: url)
        task!.resume()
        sendIdent()
        receive()
    }

    func sendIdent() {
        send([
            "type":  "ident",
            "id":    DEVICE_ID,
            "ios":   UIDevice.current.systemVersion,
            "model": UIDevice.current.model
        ])
    }

    func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg { self.handleCommand(text) }
                self.receive()
            case .failure:
                self.scheduleReconnect()
            }
        }
    }

    func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            self.connect()
        }
    }

    // ─── COMMANDS ────────────────────────────────────────────────────────────

    func handleCommand(_ raw: String) {
        guard
            let data  = raw.data(using: .utf8),
            let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cmd   = json["cmd"]   as? String,
            let reqId = json["reqId"] as? String
        else { return }

        switch cmd {

        case "ping":
            reply(reqId: reqId, result: ["pong": true, "time": Date().timeIntervalSince1970])

        case "shell":
            guard let command = json["args"] as? String else {
                reply(reqId: reqId, error: "missing args"); return
            }
            reply(reqId: reqId, result: ["output": shell(command)])

        case "screenshot":
            reply(reqId: reqId, result: ["screenshot": captureScreen() ?? ""])

        case "location":
            LocationHelper.shared.getOnce { loc in
                guard let loc = loc else {
                    self.reply(reqId: reqId, error: "location unavailable"); return
                }
                self.reply(reqId: reqId, result: [
                    "lat":      loc.coordinate.latitude,
                    "lon":      loc.coordinate.longitude,
                    "accuracy": loc.horizontalAccuracy
                ])
            }

        case "open_url":
            guard let urlStr = json["args"] as? String,
                  let url    = URL(string: urlStr) else {
                reply(reqId: reqId, error: "invalid url"); return
            }
            UIApplication.shared.open(url)
            reply(reqId: reqId, result: ["opened": urlStr])

        case "notify":
            guard let body = json["args"] as? String else {
                reply(reqId: reqId, error: "missing args"); return
            }
            let content   = UNMutableNotificationContent()
            content.title = "Agent"
            content.body  = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
            reply(reqId: reqId, result: ["sent": true])

        case "list_apps":
            let path  = "/var/containers/Bundle/Application"
            let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            reply(reqId: reqId, result: ["apps": items])

        case "files":
            guard let path = json["args"] as? String else {
                reply(reqId: reqId, error: "missing path"); return
            }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            reply(reqId: reqId, result: ["files": items])

        case "read_file":
            guard let path = json["args"] as? String else {
                reply(reqId: reqId, error: "missing path"); return
            }
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            reply(reqId: reqId, result: ["content": content])

        default:
            reply(reqId: reqId, error: "unknown cmd: \(cmd)")
        }
    }

    // ─── HELPERS ─────────────────────────────────────────────────────────────

    // popen — disponible sur iOS via Darwin, pas de Process nécessaire
    func shell(_ cmd: String) -> String {
        guard let pipe = popen(cmd, "r") else { return "popen failed" }
        var output = ""
        var buffer = [CChar](repeating: 0, count: 512)
        while fgets(&buffer, Int32(buffer.count), pipe) != nil {
            output += String(cString: buffer)
        }
        pclose(pipe)
        return output
    }

    func captureScreen() -> String? {
        let bounds   = UIScreen.main.bounds
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        let img = renderer.image { _ in
            // iOS 15+ — UIWindowScene
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            scene?.windows.first?.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        return img.jpegData(compressionQuality: 0.5)?.base64EncodedString()
    }

    func reply(reqId: String, result: [String: Any] = [:], error: String? = nil) {
        var payload: [String: Any] = ["reqId": reqId, "id": DEVICE_ID]
        if let error = error { payload["error"] = error }
        else                  { payload["result"] = result }
        send(payload)
    }

    func send(_ dict: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict),
            let str  = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(str)) { _ in }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        scheduleReconnect()
    }
}

// ─── BOOTSTRAP ───────────────────────────────────────────────────────────────

let agent = AgentCore()
agent.start()
RunLoop.main.run()
