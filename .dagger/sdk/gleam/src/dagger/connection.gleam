import dagger/errors.{type Error, ConnectionError, TransportError}
import gleam/result

/// Injectable transport: accepts a JSON request and returns HTTP status and body.
pub type Transport =
  fn(String) -> Result(#(Int, String), Error)

pub opaque type Connection {
  Connection(transport: Transport, close: fn() -> Nil)
}

pub type Session

pub fn with_transport(transport: Transport) -> Connection {
  Connection(transport, fn() { Nil })
}

/// Connect to DAGGER_SESSION_PORT/TOKEN, or start `dagger session` from PATH.
/// `_EXPERIMENTAL_DAGGER_CLI_BIN` overrides the executable.
pub fn connect() -> Result(Connection, Error) {
  connect_with_timeout(300_000)
}

pub fn connect_with_timeout(timeout_ms: Int) -> Result(Connection, Error) {
  use session <- result.try(
    open_session(timeout_ms) |> result.map_error(ConnectionError),
  )
  Ok(
    Connection(
      fn(body) {
        request(session, body, timeout_ms) |> result.map_error(TransportError)
      },
      fn() { close_session(session) },
    ),
  )
}

pub fn send(
  connection: Connection,
  body: String,
) -> Result(#(Int, String), Error) {
  connection.transport(body)
}

/// Idempotent. An inherited session is never terminated by this SDK.
pub fn close(connection: Connection) -> Nil {
  connection.close()
}

@external(erlang, "dagger_ffi", "connect")
fn open_session(timeout: Int) -> Result(Session, String)

@external(erlang, "dagger_ffi", "request")
fn request(
  session: Session,
  body: String,
  timeout: Int,
) -> Result(#(Int, String), String)

@external(erlang, "dagger_ffi", "close")
fn close_session(session: Session) -> Nil
