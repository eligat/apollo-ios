public protocol OperationRetrier {
  func shouldRetry<Operation: GraphQLOperation>(operation: Operation,
                                                request: URLRequest,
                                                with error: Error,
                                                completion: @escaping (_ shouldRetry: Bool) -> Void)
}
