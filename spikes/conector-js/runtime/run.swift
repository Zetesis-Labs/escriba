// Disposable JavaScriptCore host. Only a fake credential and a loopback origin.
import Foundation
import JavaScriptCore
import Darwin

typealias ShouldTerminate = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
typealias SetExecutionTimeLimit = @convention(c) (OpaquePointer?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

let args = CommandLine.arguments
guard args.count == 5 else { print("usage: swift runtime/run.swift bundle.js input.json output.json http://127.0.0.1:PORT"); exit(2) }
let fakeCredential = "poc-swift-only-credential"
func redact(_ text: String) -> String { text.replacingOccurrences(of: fakeCredential, with: "[REDACTED]") }
func json(_ value: Any) -> String { guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let result = String(data:data,encoding:.utf8) else { return "{}" }; return redact(result) }
guard let origin = URLComponents(string:args[4]), origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil, origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil, origin.path.isEmpty else { print("Only http://127.0.0.1:PORT is allowed"); exit(2) }
let inputData = try Data(contentsOf:URL(fileURLWithPath:args[2]))
let input = try JSONSerialization.jsonObject(with:inputData) as? [String:Any] ?? [:]
var output: [String:Any]? = nil
var checkpoints: [Any] = []
var audit: [[String:Any]] = []
var tasks: [Int:URLSessionDataTask] = [:]
var timers: [Int:Date] = [:]
let mailboxLock = NSLock()
var mailbox: [[String:Any]] = []
let configuration = URLSessionConfiguration.ephemeral
configuration.httpShouldSetCookies = false
configuration.httpCookieStorage = nil
configuration.urlCredentialStorage = nil
configuration.urlCache = nil
configuration.connectionProxyDictionary = [:]
let session = URLSession(configuration:configuration,delegate:NoRedirect(),delegateQueue:nil)
setenv("JSC_usePollingTraps", "true", 1)
guard let limitSymbol=dlsym(UnsafeMutableRawPointer(bitPattern:-2),"JSContextGroupSetExecutionTimeLimit") else { print("JavaScriptCore execution limit unavailable"); exit(2) }
let setExecutionLimit=unsafeBitCast(limitSymbol,to:SetExecutionTimeLimit.self)
let context = JSContext()!
setExecutionLimit(JSContextGetGroup(context.jsGlobalContextRef),5,{ _,_ in true },nil)
context.exceptionHandler = { _, exception in output = ["ok":false,"error":redact(exception?.toString() ?? "JavaScript exception")] }
let bridge: @convention(block) (String) -> String = { raw in
    do {
        guard let data=raw.data(using:.utf8), let request=try JSONSerialization.jsonObject(with:data) as? [String:Any], let op=request["op"] as? String else { return json(["error":"Invalid bridge request"]) }
        let id=request["id"] as? Int ?? 0
        switch op {
        case "finish": output=request; output?.removeValue(forKey:"op")
        case "checkpoint":
            let updated=checkpoints + [request["receipt"] ?? NSNull()]
            let journal=URL(fileURLWithPath:args[3]+".checkpoints.json")
            try Data(json(updated).utf8).write(to:journal,options:.atomic)
            checkpoints=updated
            if input["crashAfterCheckpoint"] as? Bool == true { exit(86) }
        case "timer": timers[id]=Date().addingTimeInterval(max(0, min(request["ms"] as? Double ?? 0,60000))/1000)
        case "clearTimer": timers.removeValue(forKey:id)
        case "cancel": tasks.removeValue(forKey:id)?.cancel()
        case "url":
            guard let text=request["value"] as? String, let url=URL(string:text,relativeTo:(request["base"] as? String).flatMap(URL.init(string:)))?.absoluteURL, let c=URLComponents(url:url,resolvingAgainstBaseURL:true), let scheme=c.scheme, let host=c.host else { return json(["error":"Invalid URL"]) }
            return json(["origin":"\(scheme)://\(host)\(c.port.map { ":\($0)" } ?? "")","pathname":c.percentEncodedPath,"search":c.percentEncodedQuery.map { "?\($0)" } ?? "","hash":c.percentEncodedFragment.map { "#\($0)" } ?? "","protocol":"\(scheme):","hostname":host,"port":c.port.map(String.init) ?? ""])
        case "fetch":
            let rawURL=request["url"] as? String ?? ""
            let method=request["method"] as? String ?? "GET"
            func denied(_ reason:String)->String { audit.append(["method":method,"url":redact(rawURL),"error":reason,"authenticated":false]); return json(["error":reason]) }
            if input["revoked"] as? Bool == true { return denied("Account permission revoked") }
            guard ["GET","POST","PATCH","DELETE"].contains(method) else { return denied("HTTP method outside the granted account methods") }
            guard let c=URLComponents(string:rawURL),c.scheme==origin.scheme,c.host==origin.host,c.port==origin.port,c.user==nil,c.password==nil,let url=c.url else { return denied("URL outside the granted account origin") }
            let headers=request["headers"] as? [String:String] ?? [:]
            let forbidden:Set<String>=["authorization","host","cookie","cookie2","proxy-authorization","proxy-connection","connection","content-length","transfer-encoding","upgrade"]
            guard !headers.keys.contains(where:{forbidden.contains($0.lowercased()) || $0.lowercased().hasPrefix("proxy-")}) else { return denied("Connector supplied a forbidden transport header") }
            var http=URLRequest(url:url,timeoutInterval:10)
            http.httpMethod=method
            for (name,value) in headers { http.setValue(value,forHTTPHeaderField:name) }
            if let body=request["body"] as? [String:Any] {
                if let text=body["text"] as? String { http.httpBody=Data(text.utf8) }
                if let values=body["bytes"] as? [UInt8] { http.httpBody=Data(values); http.setValue(body["type"] as? String,forHTTPHeaderField:"Content-Type") }
                if let parts=body["multipart"] as? [[String:Any]] {
                    let boundary="EscribaPOC-\(UUID().uuidString)"
                    var data=Data()
                    func append(_ text:String) { data.append(Data(text.utf8)) }
                    func quoted(_ text:String)->String { text.replacingOccurrences(of:"\r",with:"").replacingOccurrences(of:"\n",with:"").replacingOccurrences(of:"\"",with:"%22") }
                    for part in parts {
                        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(part["name"] as? String ?? ""))\"")
                        if let values=part["bytes"] as? [UInt8] {
                            append("; filename=\"\(quoted(part["filename"] as? String ?? "blob"))\"\r\nContent-Type: \(quoted(part["type"] as? String ?? "application/octet-stream"))\r\n\r\n")
                            data.append(Data(values))
                        } else { append("\r\n\r\n\(part["value"] as? String ?? "")") }
                        append("\r\n")
                    }
                    append("--\(boundary)--\r\n")
                    http.httpBody=data
                    http.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
                }
            }
            http.setValue("Bearer \(fakeCredential)",forHTTPHeaderField:"Authorization")
            audit.append(["method":method,"url":redact(rawURL),"bodyBytes":http.httpBody?.count ?? 0,"authenticated":true])
            let task=session.dataTask(with:http) { data,response,error in
                var message:[String:Any]=["id":id]
                if let error { message["error"]=redact(error.localizedDescription) }
                else if let response=response as? HTTPURLResponse, (300..<400).contains(response.statusCode) { message["error"]="HTTP redirect rejected by account transport" }
                else if (data?.count ?? 0) > 8*1024*1024 { message["error"]="HTTP response exceeds the 8 MiB POC limit" }
                else if let response=response as? HTTPURLResponse {
                    var safeHeaders:[String:String]=[:]
                    for (key,value) in response.allHeaderFields {
                        let name=String(describing:key).lowercased()
                        if !forbidden.contains(name) && !["set-cookie","www-authenticate","authentication-info"].contains(name) && !name.hasPrefix("proxy-") { safeHeaders[name]=redact(String(describing:value)) }
                    }
                    message["status"]=response.statusCode
                    message["statusText"]=HTTPURLResponse.localizedString(forStatusCode:response.statusCode)
                    message["headers"]=safeHeaders
                    message["text"]=redact(String(data:data ?? Data(),encoding:.utf8) ?? "")
                } else { message["error"]="Missing HTTP response" }
                mailboxLock.lock(); mailbox.append(message); mailboxLock.unlock()
            }
            tasks[id]=task; task.resume()
        default: return json(["error":"Unknown bridge operation"])
        }
        return "{}"
    } catch { return json(["error":redact(error.localizedDescription)]) }
}
context.setObject(bridge,forKeyedSubscript:"__host" as NSString)
let prelude=URL(fileURLWithPath:args[0]).deletingLastPathComponent().appendingPathComponent("prelude.js")
context.evaluateScript(try String(contentsOf:prelude,encoding:.utf8))
context.evaluateScript(try String(contentsOfFile:args[1],encoding:.utf8))
context.setObject(String(data:inputData,encoding:.utf8)!,forKeyedSubscript:"__inputJSON" as NSString)
if output == nil { context.evaluateScript("Promise.resolve().then(() => __destino.run(JSON.parse(__inputJSON), __contexto)).then(result => __finish({ok:true,result}), error => __finish({ok:false,error:String(error && (error.stack || error.message) || error)}));") }
let deadline=Date().addingTimeInterval(30)
while output == nil && Date() < deadline {
    mailboxLock.lock(); let messages=mailbox; mailbox.removeAll(); mailboxLock.unlock()
    for message in messages {
        if let id=message["id"] as? Int { tasks.removeValue(forKey:id) }
        context.objectForKeyedSubscript("__deliver").call(withArguments:[json(message)])
    }
    let ready=timers.filter { $0.value <= Date() }.map(\.key)
    for id in ready { timers.removeValue(forKey:id); context.objectForKeyedSubscript("__deliver").call(withArguments:[json(["id":id,"timer":true])]) }
    RunLoop.current.run(until:Date().addingTimeInterval(0.005))
}
if output == nil { output=["ok":false,"error":"JavaScript execution deadline exceeded"] }
for task in tasks.values { task.cancel() }
session.invalidateAndCancel()
output?["checkpoints"]=checkpoints
output?["audit"]=audit
let rendered=json(output!)
try Data(rendered.utf8).write(to:URL(fileURLWithPath:args[3]),options:.atomic)
print(rendered)
exit(output?["ok"] as? Bool == true ? 0 : 1)
