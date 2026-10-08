import AsyncHTTPClient
import Foundation
import NIOCore
import OpenAPIRuntime
import Testing

@testable import ScribeCore

@Test func responsesDiagnosticsUseStaticHTTPCodesAndUnwrapClientErrors() {
  let wrapped = ClientError(
    operationID: "secret-operation", operationInput: "secret-input",
    causeDescription: "secret-description", underlyingError: HTTPClientError.readTimeout)
  let metadata = responsesErrorMetadata(wrapped)
  #expect(metadata["error_code"] == "Read timeout")
  #expect(metadata["retryable"] == "true")
  #expect(metadata["error_type"]?.description.contains("ClientError") == true)
  #expect(metadata["underlying_error_type"]?.description.contains("HTTPClientError") == true)
  #expect(!String(describing: metadata).contains("secret"))

  let unsafeDescription = HTTPClientError.invalidHeaderFieldValues(["secret-token"])
  let safeMetadata = responsesErrorMetadata(unsafeDescription)
  #expect(safeMetadata["error_code"] == "Invalid header field values")
  #expect(!String(describing: safeMetadata).contains("secret"))
}

@Test func responsesDiagnosticsOmitAssociatedErrorDetails() {
  let decodingError = DecodingError.dataCorrupted(
    .init(codingPath: [], debugDescription: "secret-content"))
  #expect(responsesErrorMetadata(decodingError)["error_code"] == "data_corrupted")
  #expect(!String(describing: responsesErrorMetadata(decodingError)).contains("secret"))

  let unknown = NSError(domain: "secret-domain", code: 17, userInfo: [NSLocalizedDescriptionKey: "secret-token"])
  #expect(!String(describing: responsesErrorMetadata(unknown)).contains("secret"))
  #expect(responsesErrorMetadata(CancellationError())["error_code"] == "cancelled")
  #expect(responsesErrorMetadata(ChannelError.eof)["error_code"] == "eof")
  #expect(responsesErrorMetadata(IOError(errnoCode: 104, reason: "secret-path"))["error_code"] == "104")
}
