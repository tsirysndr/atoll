//// Composable, typed function arguments. Pair arguments for multiple parameters.

import dagger/mod/codec.{type Codec, type Error, MissingArgument}
import dagger/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Definition {
  Definition(
    name: String,
    schema: codec.Type,
    description: String,
    default: Option(json.Json),
  )
}

pub opaque type Arguments(a) {
  Arguments(
    definitions: List(Definition),
    read: fn(types.Query, Dict(String, Dynamic)) -> Result(a, Error),
  )
}

pub fn definitions(arguments: Arguments(a)) -> List(Definition) {
  arguments.definitions
}

pub fn decode(
  arguments: Arguments(a),
  client: types.Query,
  values: Dict(String, Dynamic),
) -> Result(a, Error) {
  arguments.read(client, values)
}

pub fn none() -> Arguments(Nil) {
  Arguments([], fn(_, _) { Ok(Nil) })
}

pub fn required(name: String, codec: Codec(a)) -> Arguments(a) {
  Arguments(
    [Definition(name, codec.schema(codec), "", None)],
    fn(client, values) {
      use value <- result.try(
        dict.get(values, name)
        |> result.map_error(fn(_) { MissingArgument(name) }),
      )
      codec.decode(codec, client, value)
    },
  )
}

pub fn optional(name: String, codec: Codec(a)) -> Arguments(Option(a)) {
  let optional_codec = codec.optional(codec)
  Arguments(
    [Definition(name, codec.schema(optional_codec), "", None)],
    fn(client, values) {
      case dict.get(values, name) {
        Error(_) -> Ok(None)
        Ok(value) -> codec.decode(optional_codec, client, value)
      }
    },
  )
}

/// A JSON default is sent to Dagger, which supplies it on invocation.
pub fn with_default(
  arguments: Arguments(a),
  default: json.Json,
) -> Arguments(a) {
  Arguments(
    ..arguments,
    definitions: list.map(arguments.definitions, fn(d) {
      Definition(..d, default: Some(default))
    }),
  )
}

pub fn with_description(
  arguments: Arguments(a),
  description: String,
) -> Arguments(a) {
  Arguments(
    ..arguments,
    definitions: list.map(arguments.definitions, fn(d) {
      Definition(..d, description: description)
    }),
  )
}

pub fn pair(first: Arguments(a), second: Arguments(b)) -> Arguments(#(a, b)) {
  Arguments(
    list.append(first.definitions, second.definitions),
    fn(client, values) {
      use a <- result.try(first.read(client, values))
      use b <- result.try(second.read(client, values))
      Ok(#(a, b))
    },
  )
}

pub fn map(arguments: Arguments(a), transform: fn(a) -> b) -> Arguments(b) {
  Arguments(arguments.definitions, fn(client, values) {
    arguments.read(client, values) |> result.map(transform)
  })
}
