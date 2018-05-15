import Foundation

extension URLSessionTask: Cancellable {}

/// A transport-level, HTTP-specific error.
public struct GraphQLHTTPResponseError: Error, LocalizedError {
  public enum ErrorKind {
    case errorResponse
    case invalidResponse
    
    var description: String {
      switch self {
      case .errorResponse:
        return "Received error response"
      case .invalidResponse:
        return "Received invalid response"
      }
    }
  }
  
  /// The body of the response.
  public let body: Data?
  /// Information about the response as provided by the server.
  public let response: HTTPURLResponse
  public let kind: ErrorKind

    public init(body: Data? = nil, response: HTTPURLResponse, kind: ErrorKind) {
        self.body = body
        self.response = response
        self.kind = kind
    }
  
  public var bodyDescription: String {
    if let body = body {
      if let description = String(data: body, encoding: response.textEncoding ?? .utf8) {
        return description
      } else {
        return "Unreadable response body"
      }
    } else {
      return "Empty response body"
    }
  }
  
  public var errorDescription: String? {
    return "\(kind.description) (\(response.statusCode) \(response.statusCodeDescription)): \(bodyDescription)"
  }
}

/// A network transport that uses HTTP POST requests to send GraphQL operations to a server, and that uses `URLSession` as the networking implementation.
open class HTTPNetworkTransport: NetworkTransport {
  let url: URL
  let session: URLSession
  let serializationFormat = JSONSerializationFormat.self
  let retrier: OperationRetrier?
  let sendOperationIdentifiers: Bool
  
  /// Creates a network transport with the specified server URL and session configuration.
  ///
  /// - Parameters:
  ///   - url: The URL of a GraphQL server to connect to.
  ///   - configuration: A session configuration used to configure the session. Defaults to `URLSessionConfiguration.default`.
  ///   - sendOperationIdentifiers: Whether to send operation identifiers rather than full operation text, for use with servers that support query persistence. Defaults to false.
  public init(url: URL, configuration: URLSessionConfiguration = URLSessionConfiguration.default, retrier: OperationRetrier? = nil, sendOperationIdentifiers: Bool = false) {
    self.url = url
    self.session = URLSession(configuration: configuration)
    self.sendOperationIdentifiers = sendOperationIdentifiers
    self.retrier = retrier
  }
  
  /// Send a GraphQL operation to a server and return a response.
  ///
  /// - Parameters:
  ///   - operation: The operation to send.
  ///   - completionHandler: A closure to call when a request completes.
  ///   - response: The response received from the server, or `nil` if an error occurred.
  ///   - error: An error that indicates why a request failed, or `nil` if the request was succesful.
  /// - Returns: An object that can be used to cancel an in progress request.
  open func send<Operation>(operation: Operation, completionHandler: @escaping (_ response: GraphQLResponse<Operation>?, _ error: Error?) -> Void) -> Cancellable {
    
    let request = self.request(for: operation)
    let task = dataTask(for: request, operation: operation, completionHandler: completionHandler)
    task.resume()
    
    return task
  }
  
  open func request<Operation: GraphQLOperation>(for operation: Operation) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let body = requestBody(for: operation)
    request.httpBody = try! serializationFormat.serialize(value: body)
    
    return request
  }
  
  open func requestBody<Operation: GraphQLOperation>(for operation: Operation) -> GraphQLMap {
    if sendOperationIdentifiers {
      guard let operationIdentifier = operation.operationIdentifier else {
        preconditionFailure("To send operation identifiers, Apollo types must be generated with operationIdentifiers")
      }
      return ["id": operationIdentifier, "variables": operation.variables]
    }
    return ["query": operation.queryDocument, "variables": operation.variables]
  }
  
  open func dataTask<Operation: GraphQLOperation>(
    for request: URLRequest,
    operation: Operation,
    completionHandler: @escaping (_ response: GraphQLResponse<Operation>?, _ error: Error?) -> Void) -> URLSessionDataTask {
    
    let task = session.dataTask(with: request) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
      guard let `self` = self
        else { return }
      
      if let error = error {
        self.operation(operation, failedWithError: error, completionHandler: completionHandler)
        return
      }
      
      guard let httpResponse = response as? HTTPURLResponse else {
        fatalError("Response should be an HTTPURLResponse")
      }
      
      if (!httpResponse.isSuccessful) {
        let error = GraphQLHTTPResponseError(body: data, response: httpResponse, kind: .errorResponse)
        self.operation(operation, failedWithError: error, completionHandler: completionHandler)
        return
      }
      
      guard let data = data else {
        let error = GraphQLHTTPResponseError(body: nil, response: httpResponse, kind: .invalidResponse)
        self.operation(operation, failedWithError: error, completionHandler: completionHandler)
        return
      }
      
      do {
        guard let body =  try self.serializationFormat.deserialize(data: data) as? JSONObject else {
          throw GraphQLHTTPResponseError(body: data, response: httpResponse, kind: .invalidResponse)
        }
        let response = GraphQLResponse(operation: operation, body: body)
        completionHandler(response, nil)
      } catch {
        self.operation(operation, failedWithError: error, completionHandler: completionHandler)
      }
    }
    
    return task
  }
  
  open func operation<Operation: GraphQLOperation>(
    _ operation: Operation,
    failedWithError error: Error,
    completionHandler: @escaping (_ response: GraphQLResponse<Operation>?, _ error: Error?) -> Void) {
   
    guard let retrier = retrier else {
      completionHandler(nil, error)
      return
    }
    
    retrier.shouldRetry(operation: operation, with: error) { [weak self] (shouldRetry) in
      if shouldRetry {
        _ = self?.send(operation: operation, completionHandler: completionHandler)
      } else {
        completionHandler(nil, error)
      }
    }
  }
}
