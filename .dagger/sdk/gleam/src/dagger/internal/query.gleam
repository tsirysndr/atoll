//// Lazy GraphQL selections and argument encoding shared by generated bindings.

import dagger/connection.{type Connection}
import dagger/errors.{
  type Error, DecodeError, GraphQLError, GraphQLErrors, HttpError, InvalidJson,
}
import gleam/dynamic
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Value {
  String(String)
  Int(Int)
  Float(Float)
  Boolean(Bool)
  Enum(String)
  List(List(Value))
  Object(List(#(String, Value)))
  Null
  /// Resolved only when the enclosing query executes.
  Reference(Selection)
}

pub type Field {
  Field(name: String, arguments: List(#(String, Value)))
}

pub opaque type Selection {
  Selection(connection: Connection, fields: List(Field))
}

pub fn root(connection: Connection) -> Selection {
  Selection(connection, [])
}

pub fn connection(selection: Selection) -> Connection {
  selection.connection
}

pub fn select(
  selection: Selection,
  name: String,
  arguments: List(#(String, Value)),
) -> Selection {
  let arguments =
    list.fold(arguments, [], fn(acc, arg) {
      list.append(
        list.filter(acc, fn(existing: #(String, Value)) { existing.0 != arg.0 }),
        [arg],
      )
    })
  Selection(
    ..selection,
    fields: list.append(selection.fields, [Field(name, arguments)]),
  )
}

pub fn load(selection: Selection, type_name: String, id: String) -> Selection {
  root(selection.connection)
  |> select("node", [#("id", String(id))])
  |> select("... on " <> type_name, [])
}

pub fn optional(value: Option(a), encode: fn(a) -> Value) -> Value {
  case value {
    Some(value) -> encode(value)
    None -> Null
  }
}

pub fn encode(value: Value) -> Result(String, Error) {
  case value {
    String(value) -> Ok(json.string(value) |> json.to_string)
    Int(value) -> Ok(int.to_string(value))
    Float(value) -> Ok(float.to_string(value))
    Boolean(True) -> Ok("true")
    Boolean(False) -> Ok("false")
    Enum(value) -> Ok(value)
    Null -> Ok("null")
    List(values) -> {
      use values <- result.try(list.try_map(values, encode))
      Ok("[" <> string.join(values, ",") <> "]")
    }
    Object(fields) -> {
      use fields <- result.try(encode_arguments(fields))
      Ok("{" <> fields <> "}")
    }
    Reference(selection) -> {
      use id <- result.try(
        select(selection, "id", []) |> execute(decode.string),
      )
      encode(String(id))
    }
  }
}

fn encode_arguments(
  arguments: List(#(String, Value)),
) -> Result(String, Error) {
  use fields <- result.try(
    list.try_map(arguments, fn(argument) {
      use value <- result.try(encode(argument.1))
      Ok(argument.0 <> ":" <> value)
    }),
  )
  Ok(string.join(fields, ","))
}

/// Rendering can execute deferred object references to obtain their IDs.
pub fn render(selection: Selection) -> Result(String, Error) {
  use fields <- result.try(
    list.try_map(selection.fields, fn(field) {
      use arguments <- result.try(encode_arguments(field.arguments))
      Ok(case arguments {
        "" -> field.name
        _ -> field.name <> "(" <> arguments <> ")"
      })
    }),
  )
  Ok(
    "query{"
    <> string.join(fields, "{")
    <> string.repeat("}", list.length(fields)),
  )
}

pub fn execute(selection: Selection, decoder: Decoder(a)) -> Result(a, Error) {
  execute_with_children(selection, "", decoder)
}

/// A child selection is used for lists of objects, which are reloaded by ID.
pub fn execute_with_children(
  selection: Selection,
  children: String,
  decoder: Decoder(a),
) -> Result(a, Error) {
  use document <- result.try(render(selection))
  let document = case children {
    "" -> document
    _ -> {
      let count = list.length(selection.fields)
      string.drop_end(document, count)
      <> "{"
      <> children
      <> "}"
      <> string.repeat("}", count)
    }
  }
  use data <- result.try(request(selection.connection, document))
  decode.run(
    data,
    decode.at(
      list.filter_map(selection.fields, fn(f) {
        case string.starts_with(f.name, "... on ") {
          True -> Error(Nil)
          False -> Ok(f.name)
        }
      }),
      decoder,
    ),
  )
  |> result.map_error(DecodeError)
}

/// Execute a raw GraphQL document. GraphQL errors take precedence over partial data.
pub fn request(
  connection: Connection,
  document: String,
) -> Result(dynamic.Dynamic, Error) {
  let body = json.object([#("query", json.string(document))]) |> json.to_string
  use response <- result.try(connection.send(connection, body))
  case response.0 >= 200 && response.0 < 300 {
    False -> Error(HttpError(response.0, response.1))
    True -> {
      use value <- result.try(
        json.parse(response.1, decode.dynamic) |> result.map_error(InvalidJson),
      )
      let errors_decoder = {
        use errors <- decode.optional_field(
          "errors",
          [],
          decode.list({
            use message <- decode.field("message", decode.string)
            use path <- decode.optional_field(
              "path",
              [],
              decode.list(decode.dynamic),
            )
            use extensions <- decode.optional_field(
              "extensions",
              dynamic.nil(),
              decode.dynamic,
            )
            decode.success(GraphQLError(message, path, extensions))
          }),
        )
        decode.success(errors)
      }
      use errors <- result.try(
        decode.run(value, errors_decoder) |> result.map_error(DecodeError),
      )
      case errors {
        [] ->
          decode.run(value, decode.at(["data"], decode.dynamic))
          |> result.map_error(DecodeError)
        _ -> Error(GraphQLErrors(errors))
      }
    }
  }
}
