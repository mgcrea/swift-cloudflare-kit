import Foundation
import Testing

@testable import CloudflareKit

/// The transport, and specifically the reconciliation of the two copies that had drifted.
@Suite("Cloudflare GraphQL")
struct CloudflareGraphQLTests {

  struct Account: Decodable, Sendable {
    let name: String?
  }
  typealias Payload = CloudflareGraphQL.AccountsPayload<Account>

  /// The trap that defines this endpoint: a permission failure is **HTTP 200** with
  /// `data: null`. A caller checking only the status reports "no data" for what is really
  /// "wrong token".
  @Test func payload_readsAnErrorArrayOnAnHTTP200() {
    let body = Data(
      #"{"data":null,"errors":[{"message":"unauthorized to access requested data"}]}"#.utf8)

    #expect(throws: CloudflareGraphQLError.self) {
      _ = try CloudflareGraphQL.payload(Payload.self, from: body)
    }
  }

  @Test func payload_returnsTheDataWhenThereAreNoErrors() throws {
    let body = Data(#"{"data":{"viewer":{"accounts":[{"name":"Acme"}]}},"errors":[]}"#.utf8)
    let payload = try CloudflareGraphQL.payload(Payload.self, from: body)

    #expect(payload?.first?.name == "Acme")
  }

  /// D1Explorer reported `errors.first` and R2Explorer joined them all. Joining is right:
  /// a query with several aliases can fail for several reasons at once, and the first is
  /// not reliably the informative one.
  @Test func payload_joinsEveryErrorMessageRatherThanReportingTheFirst() throws {
    let body = Data(
      #"{"data":null,"errors":[{"message":"first problem"},{"message":"second problem"}]}"#
        .utf8)

    do {
      _ = try CloudflareGraphQL.payload(Payload.self, from: body)
      Issue.record("expected a server error")
    } catch let error as CloudflareGraphQLError {
      #expect(error == .server(status: 200, detail: "first problem; second problem"))
    }
  }

  /// The union of both apps' word lists.
  ///
  /// They had drifted apart — one matched `not entitled` and `access denied`, the other
  /// `unauthorised` and `not authorized` — so the same Cloudflare message could read as a
  /// fixable instruction in one app and a generic failure in the other.
  @Test func isPermissionMessage_recognisesEveryKnownWording() {
    for message in [
      "unauthorized to access requested data",
      "not authorised for this resource",
      "authentication error",
      "you do not have permission",
      "forbidden",
      "access denied",
      "not entitled to this dataset",
    ] {
      #expect(
        CloudflareGraphQL.isPermissionMessage(message),
        "\(message) should read as a permission problem")
    }
  }

  /// A schema error is not a permission error, and telling the user to edit their token
  /// would send them to fix something that is not broken.
  @Test func isPermissionMessage_ignoresASchemaError() {
    #expect(!CloudflareGraphQL.isPermissionMessage(#"unknown field "nope""#))
    #expect(!CloudflareGraphQL.isPermissionMessage("number of fields can't be more than 30"))
  }

  /// A permission failure must read as an instruction rather than as an error: it is the
  /// commonest first-run outcome and the fix is two clicks in the dashboard.
  @Test func unauthorized_rendersAsAnInstruction() throws {
    let error = CloudflareGraphQLError.unauthorized(detail: "nope")
    let suggestion = try #require(error.recoverySuggestion)

    #expect(suggestion.contains("Account Analytics"))
    #expect(suggestion.contains("Read"))
  }

  @Test func payload_reportsAnUnreadableBodyRatherThanCrashing() {
    #expect(throws: CloudflareGraphQLError.invalidResponse) {
      _ = try CloudflareGraphQL.payload(Payload.self, from: Data("not json".utf8))
    }
  }
}
