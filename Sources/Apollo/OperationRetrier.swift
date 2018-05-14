public protocol OperationRetrier {
  func shouldRetry<Operation: GraphQLOperation>(operation: Operation,
                                                with error: Error,
                                                completion: @escaping (_ shouldRetry: Bool) -> Void)
}
