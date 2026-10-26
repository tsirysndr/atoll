//// Typed values shared by module schema registration and function invocation.

import dagger/errors
import dagger/internal/query
import dagger/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Error {
  SdkError(errors.Error)
  InvalidValue(String)
  MissingArgument(String)
  UnknownFunction(object: String, function: String)
  InvalidDefinition(String)
  FunctionError(String)
}

pub type Type {
  StringType
  IntType
  FloatType
  BoolType
  VoidType
  ObjectType(String)
  ListType(Type)
  OptionalType(Type)
}

pub opaque type Codec(a) {
  Codec(
    schema: Type,
    read: fn(types.Query, Dynamic) -> Result(a, Error),
    write: fn(a) -> Result(json.Json, Error),
  )
}

pub fn schema(codec: Codec(a)) -> Type {
  codec.schema
}

pub fn decode(
  codec: Codec(a),
  client: types.Query,
  value: Dynamic,
) -> Result(a, Error) {
  codec.read(client, value)
}

pub fn encode(codec: Codec(a), value: a) -> Result(json.Json, Error) {
  codec.write(value)
}

/// A typed codec for a user-defined object. Register its fields with mod.with_field.
pub fn object(
  name: String,
  decoder: decode.Decoder(a),
  encoder: fn(a) -> json.Json,
) -> Codec(a) {
  value(ObjectType(name), decoder, encoder)
}

fn value(
  schema: Type,
  decoder: decode.Decoder(a),
  encoder: fn(a) -> json.Json,
) -> Codec(a) {
  Codec(
    schema,
    fn(_, value) {
      decode.run(value, decoder)
      |> result.map_error(fn(_) {
        InvalidValue("Value does not match its declared module type")
      })
    },
    fn(value) { Ok(encoder(value)) },
  )
}

pub fn string() -> Codec(String) {
  value(StringType, decode.string, json.string)
}

pub fn int() -> Codec(Int) {
  value(IntType, decode.int, json.int)
}

pub fn float() -> Codec(Float) {
  value(FloatType, decode.float, json.float)
}

pub fn bool() -> Codec(Bool) {
  value(BoolType, decode.bool, json.bool)
}

pub fn void() -> Codec(Nil) {
  value(
    VoidType,
    decode.then(decode.optional(decode.dynamic), fn(value) {
      case value {
        None -> decode.success(Nil)
        Some(_) -> decode.failure(Nil, "Null")
      }
    }),
    fn(_) { json.null() },
  )
}

pub fn list(item: Codec(a)) -> Codec(List(a)) {
  Codec(
    ListType(item.schema),
    fn(client, value) {
      use values <- result.try(
        decode.run(value, decode.list(decode.dynamic))
        |> result.map_error(fn(_) { InvalidValue("Expected a list") }),
      )
      list.try_map(values, fn(v) { item.read(client, v) })
    },
    fn(values) {
      use values <- result.try(list.try_map(values, item.write))
      Ok(json.array(values, fn(v) { v }))
    },
  )
}

pub fn optional(item: Codec(a)) -> Codec(Option(a)) {
  Codec(
    OptionalType(item.schema),
    fn(client, value) {
      case decode.run(value, decode.optional(decode.dynamic)) {
        Ok(None) -> Ok(None)
        _ -> item.read(client, value) |> result.map(Some)
      }
    },
    fn(value) {
      case value {
        None -> Ok(json.null())
        Some(value) -> item.write(value)
      }
    },
  )
}

/// Used by generated object codecs such as container.codec() and directory.codec().
pub fn engine_object(
  name: String,
  load: fn(types.Query, String) -> a,
  selection: fn(a) -> query.Selection,
) -> Codec(a) {
  Codec(
    ObjectType(name),
    fn(client, value) {
      use id <- result.try(
        decode.run(value, decode.string)
        |> result.map_error(fn(_) {
          InvalidValue("Expected a Dagger object ID")
        }),
      )
      Ok(load(client, id))
    },
    fn(value) {
      query.select(selection(value), "id", [])
      |> query.execute(decode.string)
      |> result.map(json.string)
      |> result.map_error(SdkError)
    },
  )
}
