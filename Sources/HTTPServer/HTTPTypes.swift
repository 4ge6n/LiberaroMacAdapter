import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String] // lowercased keys
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data

    static func json(_ status: Int, _ object: Any, extraHeaders: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        var headers = extraHeaders
        headers["Content-Type"] = "application/json; charset=utf-8"
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    static func binary(_ status: Int, _ data: Data, contentType: String, extraHeaders: [String: String] = [:]) -> HTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = contentType
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    static func text(_ status: Int, _ string: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(string.utf8))
    }
}

enum HTTPStatusText {
    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}
