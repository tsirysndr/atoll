//// Dagger SDK for Gleam (Erlang target).

import dagger/connection
import dagger/errors
import dagger/internal/query
import dagger/types.{type Query}
import gleam/dynamic/decode
import gleam/result

/// The root Dagger client.
pub type Client =
  types.Query

/// Errors returned by connection, transport, GraphQL execution, or decoding.
pub type Error =
  errors.Error

pub fn connect() -> Result(Query, Error) {
  connection.connect() |> result.map(fn(conn) { types.Query(query.root(conn)) })
}

pub fn close(client: Query) -> Nil {
  connection.close(query.connection(client.selection))
}

/// Opens a connection and always closes it, including when the callback panics.
pub fn with_connection(run: fn(Query) -> Result(a, Error)) -> Result(a, Error) {
  use client <- result.try(connect())
  with_cleanup(fn() { run(client) }, fn() { close(client) })
}

@external(erlang, "dagger_ffi", "with_cleanup")
fn with_cleanup(run: fn() -> a, cleanup: fn() -> Nil) -> a

/// Wrap an injectable transport for tests or a custom connection.
pub fn from_connection(connection: connection.Connection) -> Query {
  types.Query(query.root(connection))
}

/// Execute a custom GraphQL document and decode its `data` object.
pub fn execute(
  client: Query,
  document: String,
  decoder: decode.Decoder(a),
) -> Result(a, Error) {
  use data <- result.try(query.request(
    query.connection(client.selection),
    document,
  ))
  decode.run(data, decoder) |> result.map_error(errors.DecodeError)
}
