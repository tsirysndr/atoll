import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json

pub type GraphQLError {
  GraphQLError(message: String, path: List(Dynamic), extensions: Dynamic)
}

pub type Error {
  ConnectionError(String)
  TransportError(String)
  HttpError(status: Int, body: String)
  GraphQLErrors(List(GraphQLError))
  InvalidJson(json.DecodeError)
  DecodeError(List(decode.DecodeError))
}
